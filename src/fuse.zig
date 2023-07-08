const std = @import("std");
const c = @cImport({
    @cInclude("limits.h");
});
const libfuse = @import("./libfuse.zig");

pub const FusePrivateData = struct {
    allocator: std.mem.Allocator,
    root_directory: []const u8 = "",
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

    return std.os.fstatatZ(
        std.fs.cwd().fd,
        real_path.ptr,
        std.os.linux.AT.SYMLINK_NOFOLLOW,
    );
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
        changeJxlToJpg(buf[0..e.name.len]);
        try filler.fill(buf[0..e.name.len :0]);
    }
}
