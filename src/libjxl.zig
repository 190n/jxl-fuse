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

fn libjxlAlloc(context: ?*anyopaque, size: usize) callconv(.C) ?*anyopaque {
    const allocator = @as(*std.mem.Allocator, @alignCast(@ptrCast(context.?))).*;
    const new_size = @sizeOf(usize) + size;
    const slice = allocator.alignedAlloc(u8, @alignOf(usize), new_size) catch return null;
    @as(*usize, @ptrCast(slice.ptr)).* = size;
    return @as(*anyopaque, @ptrCast(slice.ptr + @sizeOf(usize)));
}

fn libjxlFree(context: ?*anyopaque, maybe_address: ?*anyopaque) callconv(.C) void {
    if (maybe_address) |address| {
        const allocator = @as(*std.mem.Allocator, @alignCast(@ptrCast(context.?))).*;
        const many_ptr: [*]u8 = @ptrCast(address);
        const size_ptr: *usize = @alignCast(@ptrCast(many_ptr - @sizeOf(usize)));
        const size = size_ptr.*;
        allocator.free(@as([*]u8, @ptrCast(size_ptr))[0..(size + @sizeOf(usize))]);
    }
}

pub const Decoder = struct {
    decoder: *jxl.JxlDecoder,
    allocator: *std.mem.Allocator,

    fn isJxlError(status: c_uint) bool {
        return @as(Status, @enumFromInt(status)) != Status.success;
    }

    pub fn init(allocator: *std.mem.Allocator) !Decoder {
        const mgr: jxl.JxlMemoryManagerStruct = .{
            .@"opaque" = @as(*anyopaque, @ptrCast(allocator)),
            .alloc = libjxlAlloc,
            .free = libjxlFree,
        };
        return .{
            .decoder = jxl.JxlDecoderCreate(&mgr) orelse return error.OutOfMemory,
            .allocator = allocator,
        };
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

    pub fn closeInput(self: *Decoder) void {
        jxl.JxlDecoderCloseInput(self.decoder);
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
