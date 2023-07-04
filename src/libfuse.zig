const std = @import("std");
pub const libfuse = @cImport({
    @cDefine("_FILE_OFFSET_BITS", "64");
    @cInclude("fuse.h");
    @cInclude("limits.h");
});
const fuse = @import("./fuse.zig");

fn fuseGetattr(path: ?[*:0]const u8, statbuf: ?*libfuse.struct_stat) callconv(.C) c_int {
    std.log.info("getattr: {?s}", .{path});
    std.debug.print("{any}\n", .{libfuse.fuse_get_context().*});
    return fuse.getattr(
        @ptrCast(@alignCast(libfuse.fuse_get_context().*.private_data.?)),
        std.mem.span(path.?),
        statbuf.?,
    );
}

fn fuseReadlink(path: ?[*:0]const u8, link: ?[*]u8, size: usize) callconv(.C) c_int {
    std.log.info("readlink: {?s}", .{path});
    _ = size;
    _ = link;
    return 1;
}

fn fuseOpen(path: ?[*:0]const u8, fi: ?*libfuse.fuse_file_info) callconv(.C) c_int {
    std.log.info("open: {?s}", .{path});
    _ = fi;
    return -1;
}

fn fuseRead(
    path: ?[*:0]const u8,
    buf: ?[*:0]u8,
    size: usize,
    offset: libfuse.off_t,
    fi: ?*libfuse.fuse_file_info,
) callconv(.C) c_int {
    std.log.info("read: {?s}, {} bytes, offset {}", .{ path, size, offset });
    _ = fi;
    _ = buf;
    return -1;
}

fn fuseRelease(path: ?[*:0]const u8, fi: ?*libfuse.fuse_file_info) callconv(.C) c_int {
    std.log.info("release: {?s}", .{path});
    _ = fi;
    return 1;
}

fn fuseGetXattr(
    path: ?[*:0]const u8,
    name: ?[*:0]const u8,
    value: ?[*]u8,
    size: usize,
) callconv(.C) c_int {
    std.log.info("getxattr: {?s}, name: {?s}", .{ path, name });
    _ = size;
    _ = value;
    return 1;
}

fn fuseListXattr(path: ?[*:0]const u8, list: ?[*]u8, size: usize) callconv(.C) c_int {
    std.log.info("listxattr: {?s}", .{path});
    _ = size;
    _ = list;
    return 1;
}

fn fuseOpenDir(path: ?[*:0]const u8, fi: ?*libfuse.fuse_file_info) callconv(.C) c_int {
    std.log.info("opendir: {?s}", .{path});
    _ = fi;
    return 1;
}

fn fuseReleaseDir(path: ?[*:0]const u8, fi: ?*libfuse.fuse_file_info) callconv(.C) c_int {
    std.log.info("releasedir: {?s}", .{path});
    _ = fi;
    return 1;
}

fn fuseReadDir(
    path: ?[*:0]const u8,
    buf: ?*anyopaque,
    filler: libfuse.fuse_fill_dir_t,
    offset: libfuse.off_t,
    fi: ?*libfuse.fuse_file_info,
) callconv(.C) c_int {
    std.log.info("readdir: {?s}, offset {}", .{ path, offset });
    _ = fi;
    _ = filler;
    _ = buf;
    return 1;
}

fn fuseInit() callconv(.C) ?*anyopaque {
    std.log.info("init", .{});
    return libfuse.fuse_get_context().*.private_data;
}

fn fuseDestroy(userdata: ?*anyopaque) callconv(.C) void {
    std.log.info("destroy", .{});
    _ = userdata;
}

fn fuseAccess(path: ?[*:0]const u8, mask: c_int) callconv(.C) c_int {
    std.log.info("access: {?s}, mask {o}", .{ path, mask });
    return -1;
}

fn fuseStatfs(path: ?[*:0]const u8, statv: ?*libfuse.struct_statvfs) callconv(.C) c_int {
    std.log.info("statfs: {?s}", .{path});
    _ = statv;
    return 1;
}

pub const ops = libfuse.fuse_operations_compat25{
    .getdir = null, // deprecated
    .mknod = null,
    .mkdir = null,
    .unlink = null,
    .rmdir = null,
    .symlink = null,
    .rename = null,
    .link = null,
    .chmod = null,
    .chown = null,
    .truncate = null,
    .utime = null,
    .write = null,
    .flush = null,
    .setxattr = null,
    .removexattr = null,
    .fsync = null,
    .fsyncdir = null,
    .ftruncate = null,
    .fgetattr = null, // apparently only called after create()?
    .create = null,

    .getattr = fuseGetattr,
    .readlink = fuseReadlink,
    .open = fuseOpen,
    .read = fuseRead,
    .release = fuseRelease,
    .getxattr = fuseGetXattr,
    .listxattr = fuseListXattr,
    .opendir = fuseOpenDir,
    .readdir = fuseReadDir,
    .releasedir = fuseReleaseDir,
    .init = fuseInit,
    .destroy = fuseDestroy,
    .access = fuseAccess,
    .statfs = fuseStatfs,
};

pub fn fuseMain(
    argv: [][*:0]u8,
    operations: *const libfuse.fuse_operations_compat25,
    user_data: ?*anyopaque,
) !void {
    @breakpoint();
    return switch (libfuse.fuse_main_real(
        @intCast(argv.len),
        @ptrCast(argv.ptr),
        @ptrCast(operations),
        @sizeOf(libfuse.fuse_operations_compat25),
        user_data,
    )) {
        0 => {},
        1 => error.InvalidOptions,
        2 => error.NoMountPoint,
        3 => error.FuseSetupFailed,
        4 => error.MountFailed,
        5 => error.DetachFailed,
        6 => error.SignalHandlersFailed,
        7 => error.FilesystemError,
        else => error.FuseMainError,
    };
}
