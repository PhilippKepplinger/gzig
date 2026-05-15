#!/bin/zsh

zig build
hyperfine "zig-out/bin/gzig ./test-files/5mb.jpg" "gzip -k -f ./test-files/5mb.jpg"