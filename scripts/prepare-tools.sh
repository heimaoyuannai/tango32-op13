#!/usr/bin/env bash
# prepare-tools.sh — 下载构建所需的 Java 工具（smali/baksmali/R8），放到 <repo>/tools/
# 这些是 Google 开源的构建工具，可以安全地公开下载，不含任何厂商代码。
# 用法：bash scripts/prepare-tools.sh [目标目录]
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$HERE/tools}
SM3=$OUT/smali3
R8=$OUT/r8.jar
mkdir -p "$SM3"

G=https://dl.google.com/dl/android/maven2/com/android/tools
M=https://repo1.maven.org/maven2

fetch() {  # fetch <out> <url>
  local out=$1 url=$2 t
  [ -s "$out" ] && { echo "  skip $(basename "$out")"; return 0; }
  for t in 1 2 3 4 5 6; do
    if curl -sSfL --retry 3 -o "$out" "$url"; then echo "  ok   $(basename "$out")"; return 0; fi
    rm -f "$out"; sleep $((t * 5))
  done
  echo "  FAIL $(basename "$out")" >&2; return 1
}

echo "== smali 工具 -> $SM3"
for a in smali smali-baksmali smali-dexlib2 smali-util; do
  fetch "$SM3/$a.jar" "$G/smali/$a/3.0.9/$a-3.0.9.jar"
done
for p in com/beust/jcommander/1.64/jcommander-1.64 \
         com/google/code/findbugs/jsr305/3.0.2/jsr305-3.0.2 \
         com/google/guava/guava/31.1-android/guava-31.1-android \
         com/google/guava/failureaccess/1.0.1/failureaccess-1.0.1 \
         org/antlr/antlr/3.5.2/antlr-3.5.2 \
         org/antlr/antlr-runtime/3.5.2/antlr-runtime-3.5.2 \
         org/antlr/stringtemplate/3.2.1/stringtemplate-3.2.1 \
         antlr/antlr/2.7.7/antlr-2.7.7; do
  fetch "$SM3/$(basename "$p").jar" "$M/$p.jar"
done

echo "== R8 (d8) -> $R8"
fetch "$R8" "$G/r8/8.5.35/r8-8.5.35.jar"

echo
echo "完成。构建时用：SM3=$SM3 R8=$R8 bash scripts/build.sh"
