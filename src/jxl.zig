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
        std.log.info("libjxl gave us {} bytes", .{bytes_in_last_chunk});
        if (self.full_buffer.len >= 16) {
            std.log.info("first few bytes: {x:0>32}", .{std.mem.nativeToBig(u128, @as(u128, @bitCast(self.full_buffer[0..16].*)))});
        }
        const before_last_chunk = self.full_buffer.len - self.last_chunk.len;
        self.used_buffer = self.full_buffer[0..(before_last_chunk + bytes_in_last_chunk)];

        std.log.info("{} byte hash = {x:0>16}", .{ self.full_buffer.len, std.hash.XxHash64.hash(0, self.full_buffer) });
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

pub fn jxlToJpeg(jxl_buffer: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const signature_result = libjxl.signatureCheck(jxl_buffer);
    if (signature_result != .Codestream and signature_result != .Container) {
        return error.NotJxlFile;
    }

    var decoder = try libjxl.Decoder.init(&allocator);
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
