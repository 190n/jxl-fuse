# jxl-fuse

**This is not complete! Do not run it on files you care about!**

This is a FUSE filesystem, which converts images from [JPEG XL](https://jpegxl.info/) to JPEG on the fly as they are being read by applications. This takes advantage of a special feature of JPEG XL where you can losslessly recompress a JPEG into JPEG XL, which shrinks it by roughly 20% while keeping the ability to restore a _bit-for-bit identical copy of the original JPEG file_. This means that if you have a large collection of JPEG files, you can reduce your storage needs even if not all the software you use supports JPEG XL yet.

Say you have a folder full of images from a camera: `original/DSC_XXXX.jpg`. You can run a script to convert them all to JPEG XL, and then delete the originals: `jxl/DSC_XXXX.jxl`. Then, if you create an empty directory and run `jxl-fuse jxl mountpoint`, `mountpoint` will appear to contain all your original JPEG files; in reality they are converted on the fly when you read them.

# limitations

- if an error is encountered reading a file to check whether it is valid JPEG XL, the file is ignored for purposes of directory listings
- a symlink's filename appears unchanged even if the file it points to is a recompressed JPEG

# bugs

- JPEG XLs that are not recompressed JPEG still appear with the extension changed to `.jpg`, but the file contents are read as JPEG XL
- symlinks are not handled at all
