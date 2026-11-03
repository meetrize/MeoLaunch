# Zstandard decoder (vendored)

`zstddeclib.c` is the official single-file, decompression-only amalgamation of
[Zstandard](https://github.com/facebook/zstd), generated from zstd **v1.5.7**:

```sh
cd build/single_file_libs
python3 combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c
```

It lets MeoLaunch read Zed's zstd-compressed `threads.db` rows without depending
on Homebrew / a system `libzstd` (macOS does not ship one).

License: BSD-3-Clause — see `LICENSE` in this directory.
