#!/bin/zsh

zsh ./build.sh

clear

hyperfine --warmup 5 -r 25 "../zig-out/bin/gzig ../test-files/5mb.jpg" "gzip -k -f ../test-files/5mb.jpg"
hyperfine --warmup 5 -r 150 "../zig-out/bin/gzig ../test-files/article.txt" "gzip -k -f ../test-files/article.txt"
