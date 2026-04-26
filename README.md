# gzig
gzig is a personal learning project that implements the DEFLATE compression algorithm according to [RFC-1951](https://datatracker.ietf.org/doc/html/rfc1951) using [zig](https://ziglang.org/). \
The output of will be a [RFC-1952](https://datatracker.ietf.org/doc/html/rfc1952) compatible .gz file.

## Stages
1. [x] Produce a gzip compatible, uncompressed .gz file of the input that can be decoded with `gzip -d`
2. [ ] Implement block type 01
3. [ ] Implement block type 10