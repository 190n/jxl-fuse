// Copyright (c) the JPEG XL Project Authors. All rights reserved.
//
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// This C++ example decodes a JPEG XL image in one shot (all input bytes
// available at once). The example outputs the pixels and color information to a
// floating point image and an ICC profile on disk.

#ifndef __STDC_FORMAT_MACROS
#define __STDC_FORMAT_MACROS
#endif

#include <inttypes.h>
#include <jxl/decode.h>
#include <jxl/decode_cxx.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <vector>

/** Decodes JPEG XL image to floating point pixels and ICC Profile. Pixel are
 * stored as floating point, as interleaved RGBA (4 floating point values per
 * pixel), line per line from top to bottom.  Pixel values have nominal range
 * 0..1 but may go beyond this range for HDR or wide gamut. The ICC profile
 * describes the color format of the pixel data.
 */
bool DecodeJpegXlOneShot(const uint8_t* jxl, size_t size,
                         std::vector<float>* pixels, size_t* xsize,
                         size_t* ysize, std::vector<uint8_t>* icc_profile) {

  auto dec = JxlDecoderMake(nullptr);
  if (JXL_DEC_SUCCESS !=
      JxlDecoderSubscribeEvents(dec.get(), JXL_DEC_BASIC_INFO |
                                               JXL_DEC_COLOR_ENCODING |
                                               JXL_DEC_FULL_IMAGE |
                                               JXL_DEC_JPEG_RECONSTRUCTION)) {
    fprintf(stderr, "JxlDecoderSubscribeEvents failed\n");
    return false;
  }

  JxlBasicInfo info;
  JxlPixelFormat format = {4, JXL_TYPE_FLOAT, JXL_NATIVE_ENDIAN, 0};

  JxlDecoderSetInput(dec.get(), jxl, size);
  JxlDecoderCloseInput(dec.get());

  std::vector<uint8_t> jpeg_buffer;
  size_t amount_in_jpeg_buffer = 0;
  jpeg_buffer.resize(4096);
  if (JXL_DEC_SUCCESS != JxlDecoderSetJPEGBuffer(dec.get(), jpeg_buffer.data(), 4096)) {
    fprintf(stderr, "JxlDecoderSetJPEGBuffer failed\n");
    return false;
  }
  size_t last_chunk_size = 4096;

  for (;;) {
    JxlDecoderStatus status = JxlDecoderProcessInput(dec.get());
    printf("status %d\n", status);

    if (status == JXL_DEC_ERROR) {
      fprintf(stderr, "Decoder error\n");
      return false;
    } else if (status == JXL_DEC_NEED_MORE_INPUT) {
      fprintf(stderr, "Error, already provided all input\n");
      return false;
    } else if (status == JXL_DEC_BASIC_INFO) {
      printf("got basic info\n");
    } else if (status == JXL_DEC_COLOR_ENCODING) {
      printf("got color profile\n");
    } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
      fprintf(stderr, "this is not a recompressed jpeg; abort\n");
      return false;
    } else if (status == JXL_DEC_FULL_IMAGE) {
      // Nothing to do. Do not yet return. If the image is an animation, more
      // full frames may be decoded. This example only keeps the last one.
      printf("got full image\n");
      printf("%zu\n", last_chunk_size - JxlDecoderReleaseJPEGBuffer(dec.get()));
    } else if (status == JXL_DEC_JPEG_RECONSTRUCTION) {
      printf("jpeg reconstruction\n");
    } else if (status == JXL_DEC_JPEG_NEED_MORE_OUTPUT) {
      auto unwritten_bytes = JxlDecoderReleaseJPEGBuffer(dec.get());
      amount_in_jpeg_buffer += last_chunk_size - unwritten_bytes;
      jpeg_buffer.resize(jpeg_buffer.size() * 2);
      printf("buffer now holds %zu bytes of jpeg data\n", amount_in_jpeg_buffer);
      last_chunk_size = jpeg_buffer.size() - amount_in_jpeg_buffer;
      if (JXL_DEC_SUCCESS != JxlDecoderSetJPEGBuffer(dec.get(), jpeg_buffer.data() + amount_in_jpeg_buffer, last_chunk_size)) {
        fprintf(stderr, "JxlDecoderSetJPEGBuffer failed\n");
        return false;
      }
    } else if (status == JXL_DEC_SUCCESS) {
      // All decoding successfully finished.
      // It's not required to call JxlDecoderReleaseInput(dec.get()) here since
      // the decoder will be destroyed.
      return true;
    } else {
      fprintf(stderr, "Unknown decoder status\n");
      return false;
    }
  }
}

bool LoadFile(const char* filename, std::vector<uint8_t>* out) {
  FILE* file = fopen(filename, "rb");
  if (!file) {
    return false;
  }

  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return false;
  }

  long size = ftell(file);
  // Avoid invalid file or directory.
  if (size >= LONG_MAX || size < 0) {
    fclose(file);
    return false;
  }

  if (fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return false;
  }

  out->resize(size);
  size_t readsize = fread(out->data(), 1, size, file);
  if (fclose(file) != 0) {
    return false;
  }

  return readsize == static_cast<size_t>(size);
}

int main(int argc, char* argv[]) {
  if (argc != 4) {
    fprintf(stderr,
            "Usage: %s <jxl> <pfm> <icc>\n"
            "Where:\n"
            "  jxl = input JPEG XL image filename\n"
            "  pfm = output Portable FloatMap image filename\n"
            "  icc = output ICC color profile filename\n"
            "Output files will be overwritten.\n",
            argv[0]);
    return 1;
  }

  const char* jxl_filename = argv[1];
  const char* pfm_filename = argv[2];
  const char* icc_filename = argv[3];

  std::vector<uint8_t> jxl;
  if (!LoadFile(jxl_filename, &jxl)) {
    fprintf(stderr, "couldn't load %s\n", jxl_filename);
    return 1;
  }

  std::vector<float> pixels;
  std::vector<uint8_t> icc_profile;
  size_t xsize = 0, ysize = 0;
  if (!DecodeJpegXlOneShot(jxl.data(), jxl.size(), &pixels, &xsize, &ysize,
                           &icc_profile)) {
    fprintf(stderr, "Error while decoding the jxl file\n");
    return 1;
  }
  printf("Successfully wrote %s and %s\n", pfm_filename, icc_filename);
  return 0;
}
