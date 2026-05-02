# gzig
`gzig` is a personal learning project that implements the [DEFLATE](https://en.wikipedia.org/wiki/Deflate) compression algorithm according to [RFC-1951](https://datatracker.ietf.org/doc/html/rfc1951) using [zig](https://ziglang.org/). \
The main goal is the get used to the language and its features and not to create the most sophisticated encoder.
The output will be a .gz file that is compliant with [RFC-1952](https://datatracker.ietf.org/doc/html/rfc1952).

## Stages
1. [x] Produce a gzip compatible, uncompressed .gz file of the input that can be decoded with `gzip -d`
2. [x] Get block type 01 (fixed prefix codes) working
3. [ ] Get block type 10 (dynamic prefix codes) working
4. [ ] Optimize the encoder