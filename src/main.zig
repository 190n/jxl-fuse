const std = @import("std");
const libjxl = @import("./libjxl.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len != 2) {
        std.log.err("wrong number of arguments", .{});
    }

    var file = try std.fs.cwd().openFile(argv[1], .{});
    const data = try file.readToEndAlloc(allocator, 50 * 1024 * 1024);
    defer allocator.free(data);

    var decoder = try libjxl.Decoder.init();
    defer decoder.deinit();
    var jpeg_buf: [1000]u8 = undefined;
    _ = libjxl.jxl.JxlDecoderSetJPEGBuffer(decoder.decoder, &jpeg_buf, jpeg_buf.len);
    try decoder.subscribeEvents(@intFromEnum(libjxl.Status.jpeg_reconstruction));
    try decoder.setInput(data[0..4000]);

    for (0..10) |i| {
        _ = i;
        std.log.info("{any}", .{decoder.processInput()});
        std.log.info("{}", .{libjxl.jxl.JxlDecoderReleaseInput(decoder.decoder)});
    }

    std.log.info("{s}", .{@tagName(libjxl.signatureCheck(data))});
}
