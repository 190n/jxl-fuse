#ifndef FILE_INFO_HELPER_H
#define FILE_INFO_HELPER_H

#define _FILE_OFFSET_BITS 64
#include <fuse.h>
#include <stdint.h>

void storeHandle(struct fuse_file_info *fi, uint64_t handle);
uint64_t readHandle(const struct fuse_file_info *fi);

#endif
