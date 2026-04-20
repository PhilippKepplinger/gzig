# gzig
[RFC-1951](https://datatracker.ietf.org/doc/html/rfc1951#section-2) compatible DEFLATE implementation using [zig](https://ziglang.org/). \
The output of will be a [RFC-1952](https://datatracker.ietf.org/doc/html/rfc1952#section-2.1) compatible .gz file.

## Stages
- [ ] Produce a gzip compatible, uncompressed .gz file of the input that can be decoded with `gzip -d`
- [ ] Implement block type 01
- [ ] Implement block type 10