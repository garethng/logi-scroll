#!/bin/bash
# 构建 logi_scroll 独立二进制（hidapi C 源码静态编入，无第三方依赖）
set -e
cd "$(dirname "$0")"
mkdir -p build
clang -O2 -c vendor/hid.c -I vendor -o build/hid.o
clang -O2 -c hid_bridge.c -I vendor -o build/bridge.o
swiftc -O -o logi_scroll logi_scroll.swift build/hid.o build/bridge.o \
    -framework IOKit -framework CoreFoundation
echo "built: $(pwd)/logi_scroll"
