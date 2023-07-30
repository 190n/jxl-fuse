const std = @import("std");

const Cache = @This();

const jxl = @import("./jxl.zig");

allocator: std.mem.Allocator,
capacity: usize,
size: usize = 0,
contents: std.StringHashMapUnmanaged(Entry) = .{},
least_recently_used: std.PriorityQueue(QueueEntry, void, compare),
/// times that the bytes were found in the cache
hits: u64 = 0,
/// times that the bytes were not found in the cache
misses: u64 = 0,
/// times that an entry was removed from the cache to free capacity
evictions: u64 = 0,
/// times that an entry was replaced by newer data for the same file
replacements: u64 = 0,

pub const Entry = struct {
    decoded_bytes: []const u8,
    /// time since epoch in nanoseconds
    mtime: i128,
};

const QueueEntry = struct {
    /// same slice as stored in the hash table
    path: []const u8,
    /// time since epoch in nanoseconds
    last_use_time: i128,
};

fn compare(context: void, a: QueueEntry, b: QueueEntry) std.math.Order {
    _ = context;
    // if a's last_use_time is smaller than b's last_use_time, then a was used less recently,
    // so it should be popped first
    return switch (std.math.order(a.last_use_time, b.last_use_time)) {
        .lt => .lt,
        .gt => .gt,
        .eq => std.math.order(@intFromPtr(a.path.ptr), @intFromPtr(b.path.ptr)),
    };
}

pub fn init(allocator: std.mem.Allocator, capacity: usize) Cache {
    return .{
        .allocator = allocator,
        .capacity = capacity,
        .least_recently_used = std.PriorityQueue(QueueEntry, void, compare).init(allocator, {}),
    };
}

pub fn deinit(self: *Cache) void {
    var it = self.contents.iterator();
    while (it.next()) |kv| {
        self.allocator.free(kv.key_ptr.*);
        self.allocator.free(kv.value_ptr.decoded_bytes);
    }
    self.contents.deinit(self.allocator);
    // no need to free the paths in here since we already freed them in the above loop
    self.least_recently_used.deinit();
    self.* = undefined;
}

fn shrinkToFit(self: *Cache, incoming_capacity: usize) void {
    while (self.size + incoming_capacity > self.capacity and self.size != 0) {
        const item_to_remove = self.least_recently_used.removeOrNull().?;
        const table_entry = self.contents.get(item_to_remove.path).?;
        self.size -= table_entry.decoded_bytes.len;
        std.log.scoped(.cache).debug("evict {s} ({} bytes) -> {}/{} bytes used", .{
            item_to_remove.path,
            table_entry.decoded_bytes.len,
            self.size,
            self.capacity,
        });
        std.debug.assert(self.contents.remove(item_to_remove.path) == true);
        self.allocator.free(item_to_remove.path);
        self.allocator.free(table_entry.decoded_bytes);
        self.evictions += 1;
    }
}

fn markRecentlyUsed(self: *Cache, jxl_path: []const u8) !void {
    // this is ugly, since we first have to find the old last_use_time so the priority queue knows
    // which one to update. consider switching to a custom implementation that avoids two linear
    // searches.
    const old_element = blk: {
        for (0..self.least_recently_used.len) |i| {
            // pointer comparison is okay; everyone uses the allocated key
            if (self.least_recently_used.items[i].path.ptr == jxl_path.ptr) {
                break :blk self.least_recently_used.items[i];
            }
        }
        return error.ElementNotFound;
    };

    return self.least_recently_used.update(old_element, .{
        .path = jxl_path,
        .last_use_time = std.time.nanoTimestamp(),
    });
}

/// bytes must have been allocated with the cache's allocator and is now owned by the cache.
/// path will be duped.
fn insert(self: *Cache, jxl_path: [:0]const u8, bytes: []const u8, mtime: i128) !void {
    self.shrinkToFit(bytes.len);
    self.size += bytes.len;
    errdefer self.size -= bytes.len;

    const result = try self.contents.getOrPut(self.allocator, jxl_path);

    if (result.found_existing) {
        std.log.scoped(.cache).debug("replacing entry for {s}", .{jxl_path});
        // replace stale entry
        result.value_ptr.mtime = mtime;
        // this and the earlier addition will correctly adjust the size if the length changed
        self.size -= result.value_ptr.decoded_bytes.len;
        // free the old data
        self.allocator.free(result.value_ptr.decoded_bytes);
        result.value_ptr.decoded_bytes = bytes;
        self.markRecentlyUsed(result.key_ptr.*) catch unreachable;
        self.replacements += 1;
    } else {
        errdefer std.debug.assert(self.contents.remove(jxl_path) == true);
        result.key_ptr.* = try self.allocator.dupe(u8, jxl_path);
        errdefer {
            self.allocator.free(result.key_ptr.*);
            // replace with the stack buffer so that no one tries to use now freed buffer when we
            // go to remove the entry
            result.key_ptr.* = jxl_path;
        }
        result.value_ptr.* = .{
            .decoded_bytes = bytes,
            .mtime = mtime,
        };
        try self.least_recently_used.add(.{
            .path = result.key_ptr.*,
            .last_use_time = std.time.nanoTimestamp(),
        });
    }
}

/// return the bytes of the decoded jpeg only if we have one from the correct mtime. if returned
/// then the time of use for that jpeg is updated too
fn getValidJpegBytes(self: *Cache, jxl_path: [:0]const u8, mtime: i128) ?[]const u8 {
    // we need getEntry so that we can get the key from the hash table and thus update() can use
    // pointer equality on our strings
    const table_entry = self.contents.getEntry(jxl_path) orelse return null;
    if (table_entry.value_ptr.mtime < mtime) {
        std.log.scoped(.cache).debug("cache entry is too old: {s}", .{jxl_path});
        return null;
    }

    // change the timestamp
    self.markRecentlyUsed(table_entry.key_ptr.*) catch unreachable;
    return table_entry.value_ptr.decoded_bytes;
}

fn convertJxlToJpeg(allocator: std.mem.Allocator, jxl_path: [:0]const u8, max_jxl_size: usize) ![]const u8 {
    const jxl_bytes = blk: {
        var jxl_file = try std.fs.cwd().openFileZ(jxl_path, .{});
        defer jxl_file.close();
        break :blk try jxl_file.readToEndAlloc(allocator, max_jxl_size);
    };
    defer allocator.free(jxl_bytes);

    return jxl.jxlToJpeg(jxl_bytes, allocator);
}

/// returns null if jxl_path does not refer to a JPEG XL file that is a recompressed JPEG. all other
/// errors (including inability to determine whether the file is JPEG XL) are passed up.
pub fn getJpegBytesFromJxl(self: *Cache, jxl_path: [:0]const u8, mtime: std.os.timespec) !?[]const u8 {
    const mtime_ns = @as(i128, mtime.tv_sec) * std.time.ns_per_s + mtime.tv_nsec;

    if (self.getValidJpegBytes(jxl_path, mtime_ns)) |bytes| {
        std.log.scoped(.cache).debug("cache hit: {s}", .{jxl_path});
        self.hits += 1;
        // getValidJpegBytes should update last use timestamp
        return bytes;
    }

    // now, either there is no existing entry for jxl_path, or it is stale
    const jpeg_bytes = convertJxlToJpeg(self.allocator, jxl_path, self.capacity) catch |e| switch (e) {
        error.NotJxlFile, error.NotRecompressedJpeg => {
            std.log.scoped(.cache).debug("file not a JXL: {s}", .{jxl_path});
            return null;
        },
        else => {
            std.log.scoped(.cache).debug("error reading JXL {s}: {s}", .{ jxl_path, @errorName(e) });
            return e;
        },
    };
    errdefer self.allocator.free(jpeg_bytes);

    try self.insert(jxl_path, jpeg_bytes, mtime_ns);
    std.log.scoped(.cache).debug("cache miss: {s}", .{jxl_path});
    self.misses += 1;
    return jpeg_bytes;
}

fn expectHashEqual(expected: u64, actual: []const u8) !void {
    try std.testing.expectEqual(expected, std.hash.XxHash64.hash(0, actual));
}

fn expectStatsEqual(
    expected_hits: u64,
    expected_misses: u64,
    expected_evictions: u64,
    expected_replacements: u64,
    expected_size: usize,
    actual: *const Cache,
) !void {
    try std.testing.expectEqual(expected_hits, actual.hits);
    try std.testing.expectEqual(expected_misses, actual.misses);
    try std.testing.expectEqual(expected_evictions, actual.evictions);
    try std.testing.expectEqual(expected_replacements, actual.replacements);
    try std.testing.expectEqual(expected_size, actual.size);
}

fn performCacheTest(allocator: std.mem.Allocator) !void {
    var cache = Cache.init(allocator, 1_100_000);
    defer cache.deinit();

    const botw_mtime = (try std.os.fstatatZ(std.fs.cwd().fd, "test-files/botw.jxl", 0)).mtim;
    const mountain_mtime = (try std.os.fstatatZ(std.fs.cwd().fd, "test-files/mountain.jxl", 0)).mtim;
    const dusk_mtime = (try std.os.fstatatZ(std.fs.cwd().fd, "test-files/dusk.jxl", 0)).mtim;
    const trails_mtime = (try std.os.fstatatZ(std.fs.cwd().fd, "test-files/trails.jxl", 0)).mtim;

    const botw_hash = 0x09ba035d2163142c;
    const mountain_hash = 0x72084d799cc8eb36;
    const dusk_hash = 0x57e6051a44d0638d;
    const botw_len = 169200;
    const mountain_len = 532190;
    const dusk_len = 504361;

    // first access
    var botw_bytes = (try cache.getJpegBytesFromJxl("test-files/botw.jxl", botw_mtime)).?;
    try expectHashEqual(botw_hash, botw_bytes);
    try expectStatsEqual(0, 1, 0, 0, botw_len, &cache);

    // access same file again
    try expectHashEqual(botw_hash, (try cache.getJpegBytesFromJxl("test-files/botw.jxl", botw_mtime)).?);
    try expectStatsEqual(1, 1, 0, 0, botw_len, &cache);

    var mountain_bytes = (try cache.getJpegBytesFromJxl("test-files/mountain.jxl", mountain_mtime)).?;
    try expectHashEqual(mountain_hash, mountain_bytes);
    try expectStatsEqual(1, 2, 0, 0, botw_len + mountain_len, &cache);

    // pretend that the file was modified
    botw_bytes = (try cache.getJpegBytesFromJxl("test-files/botw.jxl", .{
        .tv_sec = botw_mtime.tv_sec,
        .tv_nsec = botw_mtime.tv_nsec + 1,
    })).?;
    try expectHashEqual(botw_hash, botw_bytes);
    try expectStatsEqual(1, 3, 0, 1, botw_len + mountain_len, &cache);

    // this should cause mountain to be removed (testing that botw's timestamp updated when it got
    // replaced)
    var dusk_bytes = (try cache.getJpegBytesFromJxl("test-files/dusk.jxl", dusk_mtime)).?;
    try expectHashEqual(dusk_hash, dusk_bytes);
    try expectStatsEqual(1, 4, 1, 1, dusk_len + botw_len, &cache);

    // this should evict botw (testing that mountain's timestamp was initialized when it was first
    // added)
    mountain_bytes = (try cache.getJpegBytesFromJxl("test-files/mountain.jxl", mountain_mtime)).?;
    try expectHashEqual(mountain_hash, mountain_bytes);
    try expectStatsEqual(1, 5, 2, 1, mountain_len + dusk_len, &cache);

    // now the cache contains mountain and dusk, and mountain was used more recently
    // access dusk again without a replacement or anything...
    dusk_bytes = (try cache.getJpegBytesFromJxl("test-files/dusk.jxl", dusk_mtime)).?;
    try expectHashEqual(dusk_hash, dusk_bytes);
    try expectStatsEqual(2, 5, 2, 1, mountain_len + dusk_len, &cache);

    // ...and then add botw, to make sure that mountain gets evicted and not dusk
    botw_bytes = (try cache.getJpegBytesFromJxl("test-files/botw.jxl", botw_mtime)).?;
    try expectHashEqual(botw_hash, botw_bytes);
    try expectStatsEqual(2, 6, 3, 1, botw_len + dusk_len, &cache);

    // this file is too big for the cache we created
    try std.testing.expectError(error.FileTooBig, cache.getJpegBytesFromJxl(
        "test-files/trails.jxl",
        trails_mtime,
    ) catch |e| switch (e) {
        // we have to bubble up this error (which happens when checkAllAllocationFailures makes
        // allocating the buffer to hold the jxl contents fail even before we reach the capacity
        // limit) as checkAllAllocationFailures requires error.OutOfMemory to be passed up
        error.OutOfMemory => return e,
        else => e,
    });
    // and the state should not have changed by doing that
    try expectStatsEqual(2, 6, 3, 1, botw_len + dusk_len, &cache);
}

test "cache" {
    try performCacheTest(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, performCacheTest, .{});
}
