const std = @import("std");
const c = @cImport({
    @cInclude("limits.h");
});
const libfuse = @import("./libfuse.zig");

pub const FuseUserData = struct {
    allocator: std.mem.Allocator,
    root_directory: []const u8 = "",
};

/// joins `path` with the root "real" directory of the filesystem, and changes .jpg extension to
/// .jxl if that extension is found
fn realPath(buf: *[c.PATH_MAX]u8, root_directory: []const u8, path: []const u8) [:0]u8 {
    @memcpy(buf[0..root_directory.len], root_directory);
    @memcpy(buf[root_directory.len .. root_directory.len + path.len], path);
    buf[root_directory.len + path.len] = 0;
    const slice = buf[0 .. root_directory.len + path.len :0];
    if (std.mem.endsWith(u8, slice, ".jpg")) {
        @memcpy(slice[slice.len - 3 ..], "jxl");
    }
    return slice;
}

test "realPath" {
    var buf: [c.PATH_MAX]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "foo/bar/baz.jxl", realPath(&buf, "foo/bar", "/baz.jpg"));
    try std.testing.expectEqualSlices(u8, "foo/bar/baz.txt", realPath(&buf, "foo/bar", "/baz.txt"));
}

pub fn getattr(user_data: *FuseUserData, path: [:0]const u8, statbuf: *libfuse.libfuse.struct_stat) c_int {
    @breakpoint();
    var buf: [c.PATH_MAX]u8 = undefined;
    const real_path = realPath(&buf, user_data.root_directory, path);

    return -@as(c_int, @intCast(std.os.linux.lstat(real_path.ptr, @ptrCast(statbuf))));
}
