const std = @import("std");
const libjxl = @import("./libjxl.zig");

/// helper struct to manage shuffling data to/from libjxl
const Buffers = struct {
    full_buffer: []u8,
    used_buffer: []const u8,
    last_chunk: []u8,
    allocator: std.mem.Allocator,

    pub fn init(ally: std.mem.Allocator) Buffers {
        const buf = @as([*]u8, undefined)[0..0];
        return .{
            .full_buffer = buf,
            .used_buffer = buf[0..0],
            .last_chunk = buf,
            .allocator = ally,
        };
    }

    pub fn deinit(self: *Buffers) void {
        self.allocator.free(self.full_buffer);
        self.* = undefined;
    }

    pub fn toOwned(self: *Buffers) ![]u8 {
        const slice = try self.allocator.realloc(self.full_buffer, self.used_buffer.len);
        // freeing slice of length 0 is no-op
        self.full_buffer = @as([*]u8, undefined)[0..0];
        return slice;
    }

    pub fn release(self: *Buffers, dec: *libjxl.Decoder) void {
        const unwritten_bytes = dec.releaseJpegBuffer();
        const bytes_in_last_chunk = self.last_chunk.len - unwritten_bytes;
        const before_last_chunk = self.full_buffer.len - self.last_chunk.len;
        self.used_buffer = self.full_buffer[0..(before_last_chunk + bytes_in_last_chunk)];
    }

    /// returns the chunk that can be provided to libjxl
    pub fn provideMoreRoom(self: *Buffers, dec: *libjxl.Decoder, size_hint: ?usize) ![]u8 {
        self.release(dec);
        std.log.info("realloc from {}", .{self.full_buffer.len});
        self.full_buffer = try self.allocator.realloc(
            self.full_buffer,
            @max(size_hint orelse 4096, 2 * self.full_buffer.len),
        );
        std.log.info("to {}", .{self.full_buffer.len});
        self.used_buffer.ptr = self.full_buffer.ptr;
        self.last_chunk = self.full_buffer[self.used_buffer.len..];
        return self.last_chunk;
    }
};

fn jxlToJpeg(jxl_buffer: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const signature_result = libjxl.signatureCheck(jxl_buffer);
    if (signature_result != .Codestream and signature_result != .Container) {
        return error.NotJxlFile;
    }

    var decoder = try libjxl.Decoder.init();
    defer decoder.deinit();

    try decoder.setInput(jxl_buffer);
    decoder.closeInput();
    try decoder.subscribeEvents(@intFromEnum(libjxl.Status.jpeg_reconstruction) |
        @intFromEnum(libjxl.Status.full_image));

    var bufs = Buffers.init(allocator);
    defer bufs.deinit();

    try decoder.setJpegBuffer(try bufs.provideMoreRoom(&decoder, jxl_buffer.len * 11 / 8));

    while (true) {
        const status = try decoder.processInput();
        switch (status) {
            .success => return try bufs.toOwned(),
            .need_image_out_buffer => return error.NotRecompressedJpeg,
            .jpeg_reconstruction => {},
            .jpeg_need_more_output => {
                const buf = try bufs.provideMoreRoom(&decoder, null);
                try decoder.setJpegBuffer(buf);
            },
            .full_image => {
                bufs.release(&decoder);
            },
            else => {
                std.log.err("unexpected decoder status: {s}", .{@tagName(status)});
                return error.UnexpectedStatus;
            },
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = if (std.debug.runtime_safety)
        gpa.allocator()
    else
        std.heap.c_allocator;
    defer std.debug.assert(gpa.deinit() == .ok);

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len != 2) {
        return error.WrongNumOfArguments;
    }

    var file = try std.fs.cwd().openFile(argv[1], .{});
    const data = try file.readToEndAlloc(allocator, 50 * 1024 * 1024);
    defer allocator.free(data);

    const jpeg = jxlToJpeg(data, allocator) catch |e| {
        switch (e) {
            error.NotJxlFile => {
                std.log.err("input is not a JPEG XL file", .{});
                std.process.exit(1);
            },
            error.NotRecompressedJpeg => {
                std.log.err("input is not a recompressed JPEG file", .{});
                std.process.exit(1);
            },
            else => return e,
        }
    };
    defer allocator.free(jpeg);

    std.log.info("converted {} byte JXL to {} byte JPEG", .{ data.len, jpeg.len });

    var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(jpeg, &hash, .{});
    std.log.info("hash: {}", .{std.fmt.fmtSliceHexLower(&hash)});
}
