#!/bin/zsh

zsh ./build.sh

hyperfine --warmup 5 -r 25 "../zig-out/bin/gzig ../test-files/5mb.jpg" "gzip -k -f ../test-files/5mb.jpg"