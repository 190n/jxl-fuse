const std = @import("std");
const c = @cImport({
    @cInclude("limits.h");
});
const libfuse = @import("./libfuse.zig");
const libjxl = @import("./libjxl.zig");
const Cache = @import("./Cache.zig");

pub const FusePrivateData = struct {
    allocator: std.mem.Allocator,
    root_directory: []const u8,
    cache: Cache,

    pub fn init(allocator: std.mem.Allocator, root_directory: []const u8, cache_capacity: usize) FusePrivateData {
        return .{
            .allocator = allocator,
            .root_directory = root_directory,
            .cache = Cache.init(allocator, cache_capacity),
        };
    }
};

fn changeJpgToJxl(buf: []u8) void {
    if (std.mem.endsWith(u8, buf, ".jpg")) {
        @memcpy(buf[buf.len - 3 ..], "jxl");
    }
}

fn changeJxlToJpg(buf: []u8) void {
    if (std.mem.endsWith(u8, buf, ".jxl")) {
        @memcpy(buf[buf.len - 3 ..], "jpg");
    }
}

/// joins `path` with the root "real" directory of the filesystem, and changes .jpg extension to
/// .jxl if that extension is found
fn realPath(buf: *[c.PATH_MAX]u8, root_directory: []const u8, path: []const u8) [:0]u8 {
    @memcpy(buf[0..root_directory.len], root_directory);
    @memcpy(buf[root_directory.len .. root_directory.len + path.len], path);
    buf[root_directory.len + path.len] = 0;
    const slice = buf[0 .. root_directory.len + path.len :0];
    // if application tries to access a JPEG, we really want the corresponding JXL
    changeJpgToJxl(slice);
    return slice;
}

test "realPath" {
    var buf: [c.PATH_MAX]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "foo/bar/baz.jxl", realPath(&buf, "foo/bar", "/baz.jpg"));
    try std.testing.expectEqualSlices(u8, "foo/bar/baz.txt", realPath(&buf, "foo/bar", "/baz.txt"));
}

pub fn getAttr(private_data: *FusePrivateData, path: [:0]const u8) !std.os.Stat {
    var buf: [c.PATH_MAX]u8 = undefined;
    const real_path = realPath(&buf, private_data.root_directory, path);

    var stat = try std.os.fstatatZ(
        std.fs.cwd().fd,
        real_path.ptr,
        std.os.linux.AT.SYMLINK_NOFOLLOW,
    );

    if (private_data.cache.getJpegBytesFromJxl(real_path, stat.mtim) catch null) |bytes| {
        stat.size = @intCast(bytes.len);
    }
    return stat;
}

pub fn openDir(private_data: *FusePrivateData, path: [:0]const u8) !std.fs.IterableDir {
    var buf: [c.PATH_MAX]u8 = undefined;
    const real_path = realPath(&buf, private_data.root_directory, path);

    return std.fs.openIterableDirAbsoluteZ(real_path, .{ .no_follow = true });
}

pub fn releaseDir(private_data: *FusePrivateData, path: [:0]const u8, dir: *std.fs.IterableDir) !void {
    _ = path;
    _ = private_data;
    dir.close();
}

fn checkValidJxl(dir: std.fs.Dir, sub_path: []const u8) !bool {
    var file = try dir.openFile(sub_path, .{});
    defer file.close();
    // according to https://github.com/libjxl/libjxl/blob/c3a4f9ca89ae59c6265a2f1bf2a6d2a87a71fc16/lib/jxl/decode.cc#L114
    // signature check never requires more than 12 bytes
    var buf: [12]u8 = undefined;
    const num_read = try file.readAll(&buf);
    return switch (libjxl.signatureCheck(buf[0..num_read])) {
        .Codestream, .Container => true,
        else => false,
    };
}

pub fn readDir(private_data: *FusePrivateData, path: [:0]const u8, filler: libfuse.Filler, dir: std.fs.IterableDir) !void {
    _ = path;
    _ = private_data;
    var it = dir.iterate();
    var entry = try it.next();
    while (entry) |e| : (entry = try it.next()) {
        // we need more buffer to change JXL in the extension to JPG
        // if we find a JXL file in our directory, we want to act like it is really named JPG
        var buf: @TypeOf(it.buf) = undefined;
        @memcpy(buf[0..e.name.len], e.name);
        buf[e.name.len] = 0;
        if (std.mem.endsWith(u8, e.name, ".jxl")) {
            const is_jxl = checkValidJxl(dir.dir, e.name) catch continue;
            if (!is_jxl) continue;
        }
        changeJxlToJpg(buf[0..e.name.len]);
        try filler.fill(buf[0..e.name.len :0]);
    }
}
