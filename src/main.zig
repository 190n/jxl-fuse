const std = @import("std");

const jxl = @import("./jxl.zig");
const libfuse = @import("./libfuse.zig");
const fuse = @import("./fuse.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = if (std.debug.runtime_safety)
        gpa.allocator()
    else
        std.heap.c_allocator;
    defer std.debug.assert(gpa.deinit() == .ok);

    if (std.os.argv.len < 3) {
        std.debug.print("usage: {s} [FUSE options] root_directory mountpoint\n", .{std.os.argv[0]});
        std.os.exit(1);
    }

    // extract root directory from arguments list
    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const root_directory = try std.os.realpath(std.mem.span(std.os.argv[std.os.argv.len - 2]), &buf);
    // remove root directory so libfuse doesn't see it
    std.os.argv[std.os.argv.len - 2] = std.os.argv[std.os.argv.len - 1];

    std.log.info("mounting {s} at {s}", .{ root_directory, std.os.argv[std.os.argv.len - 2] });

    var private_data = fuse.FusePrivateData{
        .allocator = allocator,
        .root_directory = root_directory,
    };

    const operations = libfuse.generateFuseOps(
        fuse.FusePrivateData,
        std.fs.File,
        std.fs.IterableDir,
        std.os.FStatAtError || std.fs.File.OpenError || error{OutOfMemory},
        .{
            .getAttr = fuse.getAttr,
            .openDir = fuse.openDir,
            .releaseDir = fuse.releaseDir,
            .readDir = fuse.readDir,
        },
    );

    try libfuse.fuseMain(std.os.argv[0 .. std.os.argv.len - 1], &private_data, operations);
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
