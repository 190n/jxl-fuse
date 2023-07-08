#include "file_info_helper.h"

void storeHandle(struct fuse_file_info *fi, uint64_t handle) {
	fi->fh = handle;
}

uint64_t readHandle(const struct fuse_file_info *fi) {
	return fi->fh;
}
