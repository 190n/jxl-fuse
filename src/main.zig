const std = @import("std");

const jxl = @import("./jxl.zig");
const fuse = @import("./fuse.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = if (std.debug.runtime_safety)
        gpa.allocator()
    else
        std.heap.c_allocator;
    defer std.debug.assert(gpa.deinit() == .ok);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const argv = try allocator.alloc(?[*:0]u8, args.len);
    defer allocator.free(argv);
    for (args, 0..) |arg, i| {
        argv[i] = arg.ptr;
    }

    std.debug.print("fuse_main returned {}\n", .{fuse.libfuse.fuse_main_real(
        @intCast(argv.len),
        argv.ptr,
        @as(*const fuse.libfuse.struct_fuse_operations, @ptrCast(&fuse.ops)),
        @sizeOf(@TypeOf(fuse.ops)),
        null,
    )});
}
