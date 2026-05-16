#!/bin/zsh

zsh build.sh
hyperfine "../zig-out/bin/gzig ../test-files/5mb.jpg" "gzip -k -f ../test-files/5mb.jpg"