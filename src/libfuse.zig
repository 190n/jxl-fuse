const std = @import("std");
pub const c = @cImport({
    @cDefine("_FILE_OFFSET_BITS", "64");
    @cInclude("fuse.h");
    @cInclude("limits.h");
    @cInclude("file_info_helper.h");
});
const fuse = @import("./fuse.zig");

fn assertLayoutsCompatible(comptime A: type, comptime B: type) void {
    if (std.meta.activeTag(@typeInfo(A)) != std.meta.activeTag(@typeInfo(B))) {
        @compileError("types are not compatible: A = " ++ @typeName(A) ++ ", B = " ++ @typeName(B));
    }

    const a_info = @typeInfo(A);
    const b_info = @typeInfo(B);

    switch (a_info) {
        .Struct => {
            if (a_info.Struct.layout != .Extern) {
                @compileError("struct is not extern: " ++ @typeName(A));
            } else if (b_info.Struct.layout != .Extern) {
                @compileError("struct is not extern: " ++ @typeName(B));
            }

            for (a_info.Struct.fields, b_info.Struct.fields) |a_field, b_field| {
                if (std.mem.startsWith(u8, a_field.name, "__") or std.mem.startsWith(u8, b_field.name, "__")) {
                    // __ fields are padding, so just make sure they have the same size
                    if (@sizeOf(a_field.type) != @sizeOf(b_field.type)) {
                        var buf: [4096]u8 = undefined;
                        @compileError(try std.fmt.bufPrint(
                            &buf,
                            "padding fields have different sizes: {s}.{s} ({}), {s}.{s} ({})",
                            .{ @typeName(A), a_field.name, @sizeOf(a_field.type), @typeName(B), b_field.name, @sizeOf(b_field.type) },
                        ));
                    } else {
                        continue;
                    }
                }

                assertLayoutsCompatible(a_field.type, b_field.type);
                if (!std.mem.containsAtLeast(u8, a_field.name, 1, b_field.name) and
                    !std.mem.containsAtLeast(u8, b_field.name, 1, a_field.name))
                {
                    var buf: [4096]u8 = undefined;
                    @compileError(try std.fmt.bufPrint(
                        &buf,
                        "fields have dissimilar names: {s}.{s}, {s}.{s}",
                        .{ @typeName(A), a_field.name, @typeName(B), b_field.name },
                    ));
                }
            }
        },
        .Int => {
            if (a_info.Int.bits != b_info.Int.bits) {
                @compileError("integers have different size: " ++ @typeName(A) ++ ", " ++ @typeName(B));
            } else if (a_info.Int.signedness != b_info.Int.signedness) {
                @compileError("integers have different signedness: " ++ @typeName(A) ++ ", " ++ @typeName(B));
            }
        },
        else => @compileError("unsupported type for assertLayoutsCompatible: " ++ @typeName(A)),
    }
}

fn errorToErrno(input: anytype) i32 {
    const errorSet = switch (@typeInfo(@TypeOf(input))) {
        .ErrorUnion => if (input) |_| return 0 else |e| e,
        .ErrorSet => input,
        else => @compileError("invalid type passed into errorToErrno (must be error union or error set): " ++
            @typeName(@TypeOf(input))),
    };
    const errnoEnum: std.os.E = switch (errorSet) {
        error.SystemResources => .NOMEM,
        error.AccessDenied => .ACCES,
        error.NameTooLong => .NAMETOOLONG,
        error.SymLinkLoop => .LOOP,
        error.FileNotFound => .NOENT,
        error.NotDir => .NOTDIR,
        error.FileTooBig => .FBIG,
        error.IsDir => .ISDIR,
        error.ProcessFdQuotaExceeded => .MFILE,
        error.SystemFdQuotaExceeded => .NFILE,
        error.NoDevice => .NODEV,
        error.NoSpaceLeft => .NOSPC,
        error.BadPathName => .INVAL,
        error.DeviceBusy => .BUSY,
        error.PathAlreadyExists => .EXIST,
        error.FileLocksNotSupported => .OPNOTSUPP,
        error.FileBusy => .BUSY,
        error.WouldBlock => .AGAIN,
        error.OutOfMemory => .NOMEM,
        error.Unexpected => blk: {
            std.log.err("unexpected errno\n", .{});
            break :blk @enumFromInt(255);
        },
        // these errors don't have corresponding errnos in zig std and may be windows-only
        error.SharingViolation, error.PipeBusy, error.InvalidHandle, error.InvalidUtf8 => |e| blk: {
            std.log.err("unexpected error: {s}\n", .{@errorName(e)});
            break :blk @enumFromInt(255);
        },
    };
    return -@as(i32, @intFromEnum(errnoEnum));
}

pub const Filler = struct {
    buf: ?*anyopaque,
    filler: c.fuse_fill_dir_t,

    pub fn fill(self: Filler, name: [:0]const u8) error{OutOfMemory}!void {
        if (self.filler.?(self.buf, name.ptr, null, 0) == 1) {
            return error.OutOfMemory;
        }
    }
};

pub fn FuseOps(
    comptime PrivateData: type,
    comptime FileHandle: type,
    comptime DirectoryHandle: type,
    comptime Error: type,
) type {
    comptime if (@sizeOf(FileHandle) > @sizeOf(u64)) {
        @compileError("file handle type " ++ @typeName(FileHandle) ++ " is too big. use a pointer?");
    };

    comptime if (@sizeOf(DirectoryHandle) > @sizeOf(u64)) {
        @compileError("directory handle type " ++ @typeName(DirectoryHandle) ++ " is too big. use a pointer?");
    };

    return struct {
        getAttr: ?*const fn (private_data: *PrivateData, path: [:0]const u8) Error!std.os.Stat = null,
        openDir: ?*const fn (private_data: *PrivateData, path: [:0]const u8) Error!DirectoryHandle = null,
        releaseDir: ?*const fn (private_data: *PrivateData, path: [:0]const u8, dir: *DirectoryHandle) Error!void = null,
        readDir: ?*const fn (private_data: *PrivateData, path: [:0]const u8, filler: Filler, dir: DirectoryHandle) Error!void = null,
    };
}

pub fn generateFuseOps(
    comptime PrivateData: type,
    comptime FileHandle: type,
    comptime DirectoryHandle: type,
    comptime Error: type,
    comptime implementations: FuseOps(PrivateData, FileHandle, DirectoryHandle, Error),
) *const c.fuse_operations_compat25 {
    const Helper = struct {
        fn getPrivateData() *PrivateData {
            return @ptrCast(@alignCast(c.fuse_get_context().*.private_data.?));
        }

        fn storeHandle(comptime T: type, fi: *c.fuse_file_info, handle: T) void {
            c.storeHandle(
                fi,
                // bit-cast to same sized integer, and then expand to u64 if needed
                @as(u64, @as(*const std.meta.Int(.unsigned, @sizeOf(T) * 8), @ptrCast(&handle)).*),
            );
        }

        fn readHandle(comptime T: type, fi: *const c.fuse_file_info) T {
            const as_int: std.meta.Int(.unsigned, @sizeOf(T) * 8) = @truncate(c.readHandle(fi));
            return @as(*const T, @ptrCast(&as_int)).*;
        }

        fn fuseGetAttr(path: ?[*:0]const u8, statbuf: ?*c.struct_stat) callconv(.C) c_int {
            std.log.info("getattr: {?s}", .{path});
            const stat = implementations.getAttr.?(
                getPrivateData(),
                std.mem.span(path.?),
            ) catch |e| return errorToErrno(e);
            comptime assertLayoutsCompatible(c.struct_stat, std.os.Stat);
            statbuf.?.* = @bitCast(stat);
            return 0;
        }

        fn fuseReadlink(path: ?[*:0]const u8, link: ?[*]u8, size: usize) callconv(.C) c_int {
            std.log.info("readlink: {?s}", .{path});
            _ = size;
            _ = link;
            return 1;
        }

        fn fuseOpen(path: ?[*:0]const u8, fi: ?*c.fuse_file_info) callconv(.C) c_int {
            std.log.info("open: {?s}", .{path});
            _ = fi;
            return -1;
        }

        fn fuseRead(
            path: ?[*:0]const u8,
            buf: ?[*:0]u8,
            size: usize,
            offset: c.off_t,
            fi: ?*c.fuse_file_info,
        ) callconv(.C) c_int {
            std.log.info("read: {?s}, {} bytes, offset {}", .{ path, size, offset });
            _ = fi;
            _ = buf;
            return -1;
        }

        fn fuseRelease(path: ?[*:0]const u8, fi: ?*c.fuse_file_info) callconv(.C) c_int {
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

        fn fuseOpenDir(path: ?[*:0]const u8, fi: ?*c.fuse_file_info) callconv(.C) c_int {
            std.log.info("opendir: {?s}", .{path});
            const dir = implementations.openDir.?(
                getPrivateData(),
                std.mem.span(path.?),
            ) catch |e| return errorToErrno(e);
            storeHandle(DirectoryHandle, fi.?, dir);
            return 0;
        }

        fn fuseReleaseDir(path: ?[*:0]const u8, fi: ?*c.fuse_file_info) callconv(.C) c_int {
            std.log.info("releasedir: {?s}", .{path});
            var handle = readHandle(DirectoryHandle, fi.?);
            implementations.releaseDir.?(
                getPrivateData(),
                std.mem.span(path.?),
                &handle,
            ) catch |e| return errorToErrno(e);
            storeHandle(DirectoryHandle, fi.?, handle);
            return 0;
        }

        fn fuseReadDir(
            path: ?[*:0]const u8,
            buf: ?*anyopaque,
            filler: c.fuse_fill_dir_t,
            offset: c.off_t,
            fi: ?*c.fuse_file_info,
        ) callconv(.C) c_int {
            _ = offset;
            std.log.info("readdir: {?s}", .{path});

            const handle = readHandle(DirectoryHandle, fi.?);
            implementations.readDir.?(
                getPrivateData(),
                std.mem.span(path.?),
                Filler{ .buf = buf, .filler = filler.? },
                handle,
            ) catch |e| return errorToErrno(e);
            return 0;
        }

        fn fuseDestroy(userdata: ?*anyopaque) callconv(.C) void {
            std.log.info("destroy", .{});
            _ = userdata;
        }

        fn fuseAccess(path: ?[*:0]const u8, mask: c_int) callconv(.C) c_int {
            std.log.info("access: {?s}, mask {o}", .{ path, mask });
            return -1;
        }

        fn fuseStatfs(path: ?[*:0]const u8, statv: ?*c.struct_statvfs) callconv(.C) c_int {
            std.log.info("statfs: {?s}", .{path});
            _ = statv;
            return 1;
        }

        const ops = c.fuse_operations_compat25{
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
            .init = null,

            .getattr = if (implementations.getAttr) |_| fuseGetAttr else null,
            .readlink = fuseReadlink,
            .open = fuseOpen,
            .read = fuseRead,
            .release = fuseRelease,
            .getxattr = fuseGetXattr,
            .listxattr = fuseListXattr,
            .opendir = if (implementations.openDir) |_| fuseOpenDir else null,
            .readdir = if (implementations.readDir) |_| fuseReadDir else null,
            .releasedir = if (implementations.releaseDir) |_| fuseReleaseDir else null,
            .destroy = fuseDestroy,
            .access = fuseAccess,
            .statfs = fuseStatfs,
        };
    };
    return &Helper.ops;
}

pub fn fuseMain(
    argv: [][*:0]u8,
    user_data: *anyopaque,
    operations: *const c.fuse_operations_compat25,
) !void {
    return switch (c.fuse_main_real(
        @intCast(argv.len),
        @ptrCast(argv.ptr),
        @ptrCast(operations),
        @sizeOf(c.fuse_operations_compat25),
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
