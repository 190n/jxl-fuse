# limitations

- if an error is encountered reading a file to check whether it is valid JPEG XL, the file is ignored for purposes of directory listings
- a symlink's filename appears unchanged even if the file it points to is a recompressed JPEG

# bugs

- JPEG XLs that are not recompressed JPEG still appear with the extension changed to `.jpg`, but the file contents are read as JPEG XL
- symlinks are not handled at all
