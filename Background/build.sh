#!/usr/bin/env bash
# 独立 SpringBoard 模块的完整构建入口；不编译或链接主应用、daemon。
set -euo pipefail
: "${1:?必须指定输出 dylib}"
: "${2:?必须指定 roothide 或 rootless}"
output="$1"
flavor="$2"
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
case "$flavor" in
    roothide) arch=arm64e ;;
    rootless) arch=arm64 ;;
    *) echo '不支持的 bootstrap' >&2; exit 64 ;;
esac
if command -v xcrun >/dev/null 2>&1; then
    compiler="$(xcrun --sdk iphoneos --find clang)"
    sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
else
    compiler="${CC:-clang}"
    sdk="${SDKROOT:?设备编译必须指定 SDKROOT}"
    # 设备上的 compiler 使用内核路径，避免把 bootstrap shell 的逻辑路径写入编译输入。
    : "${APELIN_PROJECT_ROOT:?设备编译必须指定 APELIN_PROJECT_ROOT}"
    source_dir="$APELIN_PROJECT_ROOT/Background"
fi
mkdir -p -- "$(dirname -- "${output:?}")"
"$compiler" -arch "$arch" -isysroot "$sdk" -miphoneos-version-min=16.0 \
    -fobjc-arc -fblocks -g -O2 -Wall -Wextra -Werror -fvisibility=hidden \
    -ffile-prefix-map="$source_dir"=Background \
    -dynamiclib "$source_dir/ApelinForeground.m" \
    -framework Foundation -framework UIKit \
    -install_name @rpath/ApelinForeground.dylib -o "$output"
if command -v xcrun >/dev/null 2>&1; then
    xcrun dsymutil "$output" -o "$output.dSYM"
fi
