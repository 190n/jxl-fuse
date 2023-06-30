const std = @import("std");

pub const jxl = @cImport({
    @cInclude("jxl/decode.h");
});

pub const Signature = enum(c_int) {
    NotEnoughBytes,
    Invalid,
    Codestream,
    Container,
};

pub const Status = enum(c_int) {
    success = jxl.JXL_DEC_SUCCESS,
    @"error" = jxl.JXL_DEC_ERROR,
    need_more_input = jxl.JXL_DEC_NEED_MORE_INPUT,
    need_preview_out_buffer = jxl.JXL_DEC_NEED_PREVIEW_OUT_BUFFER,
    need_image_out_buffer = jxl.JXL_DEC_NEED_IMAGE_OUT_BUFFER,
    jpeg_need_more_output = jxl.JXL_DEC_JPEG_NEED_MORE_OUTPUT,
    box_need_more_output = jxl.JXL_DEC_BOX_NEED_MORE_OUTPUT,
    basic_info = jxl.JXL_DEC_BASIC_INFO,
    color_encoding = jxl.JXL_DEC_COLOR_ENCODING,
    preview_image = jxl.JXL_DEC_PREVIEW_IMAGE,
    frame = jxl.JXL_DEC_FRAME,
    full_image = jxl.JXL_DEC_FULL_IMAGE,
    jpeg_reconstruction = jxl.JXL_DEC_JPEG_RECONSTRUCTION,
    box = jxl.JXL_DEC_BOX,
    frame_progression = jxl.JXL_DEC_FRAME_PROGRESSION,
};

pub fn signatureCheck(buf: []const u8) Signature {
    return @enumFromInt(jxl.JxlSignatureCheck(buf.ptr, buf.len));
}

pub const Decoder = struct {
    decoder: *jxl.JxlDecoder,

    fn isJxlError(status: c_uint) bool {
        return @as(Status, @enumFromInt(status)) != Status.success;
    }

    pub fn init() error{OutOfMemory}!Decoder {
        return .{ .decoder = jxl.JxlDecoderCreate(null) orelse return error.OutOfMemory };
    }

    pub fn reset(self: *Decoder) void {
        jxl.JxlDecoderReset(self.decoder);
    }

    pub fn deinit(self: *Decoder) void {
        jxl.JxlDecoderDestroy(self.decoder);
        self.* = undefined;
    }

    pub fn subscribeEvents(self: *Decoder, events_wanted: c_int) !void {
        if (isJxlError(jxl.JxlDecoderSubscribeEvents(self.decoder, events_wanted))) {
            return error.JxlSubscribeEventsError;
        }
    }

    pub fn processInput(self: *Decoder) !Status {
        return switch (@as(Status, @enumFromInt(jxl.JxlDecoderProcessInput(self.decoder)))) {
            .@"error" => error.JxlProcessInputError,
            else => |status| status,
        };
    }

    pub fn setInput(self: *Decoder, input: []const u8) !void {
        if (isJxlError(jxl.JxlDecoderSetInput(self.decoder, input.ptr, input.len))) {
            return error.JxlSetInputError;
        }
    }

    pub fn setJpegBuffer(self: *Decoder, buf: []u8) !void {
        if (isJxlError(jxl.JxlDecoderSetJPEGBuffer(self.decoder, buf.ptr, buf.len))) {
            return error.JxlSetJpegBufferError;
        }
    }

    pub fn releaseJpegBuffer(self: *Decoder) usize {
        return jxl.JxlDecoderReleaseJPEGBuffer(self.decoder);
    }
};

test {
    std.debug.print("{any}\n", .{signatureCheck(&.{ 0x00, 0x00, 0x00, 0x0c })});
}
