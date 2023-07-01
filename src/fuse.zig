const std = @import("std");
pub const libfuse = @cImport({
    @cDefine("_FILE_OFFSET_BITS", "64");
    @cInclude("fuse.h");
});

fn fuseGetattr(path: ?[*:0]const u8, statbuf: ?*libfuse.struct_stat) callconv(.C) c_int {
    std.log.info("getattr", .{});
    _ = statbuf;
    _ = path;
    return 1;
}

fn fuseReadlink(path: ?[*:0]const u8, link: ?[*]u8, size: usize) callconv(.C) c_int {
    std.log.info("readlink", .{});
    _ = size;
    _ = link;
    _ = path;
    return 1;
}

fn fuseOpen(path: ?[*:0]const u8, fi: ?*libfuse.fuse_file_info) callconv(.C) c_int {
    std.log.info("open", .{});
    _ = fi;
    _ = path;
    return -1;
}

fn fuseRead(
    path: ?[*:0]const u8,
    buf: ?[*:0]u8,
    size: usize,
    offset: libfuse.off_t,
    fi: ?*libfuse.fuse_file_info,
) callconv(.C) c_int {
    std.log.info("read", .{});
    _ = fi;
    _ = offset;
    _ = size;
    _ = buf;
    _ = path;
    return -1;
}

fn fuseRelease(path: ?[*:0]const u8, fi: ?*libfuse.fuse_file_info) callconv(.C) c_int {
    std.log.info("release", .{});
    _ = fi;
    _ = path;
    return 1;
}

fn fuseGetXattr(
    path: ?[*:0]const u8,
    name: ?[*:0]const u8,
    value: ?[*]u8,
    size: usize,
) callconv(.C) c_int {
    std.log.info("getxattr", .{});
    _ = size;
    _ = value;
    _ = name;
    _ = path;
    return 1;
}

fn fuseListXattr(path: ?[*:0]const u8, list: ?[*]u8, size: usize) callconv(.C) c_int {
    std.log.info("listxattr", .{});
    _ = size;
    _ = list;
    _ = path;
    return 1;
}

fn fuseOpenDir(path: ?[*:0]const u8, fi: ?*libfuse.fuse_file_info) callconv(.C) c_int {
    std.log.info("opendir", .{});
    _ = fi;
    _ = path;
    return 1;
}

fn fuseReleaseDir(path: ?[*:0]const u8, fi: ?*libfuse.fuse_file_info) callconv(.C) c_int {
    std.log.info("releasedir", .{});
    _ = fi;
    _ = path;
    return 1;
}

fn fuseReadDir(
    path: ?[*:0]const u8,
    buf: ?*anyopaque,
    filler: libfuse.fuse_fill_dir_t,
    offset: libfuse.off_t,
    fi: ?*libfuse.fuse_file_info,
) callconv(.C) c_int {
    std.log.info("readdir", .{});
    _ = fi;
    _ = offset;
    _ = filler;
    _ = buf;
    _ = path;
    return 1;
}

fn fuseInit() callconv(.C) *anyopaque {
    std.log.info("init", .{});
    return undefined;
}

fn fuseDestroy(userdata: ?*anyopaque) callconv(.C) void {
    std.log.info("destroy", .{});
    _ = userdata;
}

fn fuseAccess(path: ?[*:0]const u8, mask: c_int) callconv(.C) c_int {
    std.log.info("access", .{});
    _ = mask;
    _ = path;
    return -1;
}

fn fuseStatfs(path: ?[*:0]const u8, statv: ?*libfuse.struct_statvfs) callconv(.C) c_int {
    std.log.info("statfs", .{});
    _ = statv;
    _ = path;
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
