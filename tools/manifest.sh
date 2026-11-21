#!/usr/bin/env bash
# manifest.sh — 生成 / 比对模块内容清单（只记录路径、大小、权限、SHA-256）
#
# 为什么需要它：模块里包含厂商二进制，不能公开分发；但「清单 + 哈希」是安全的。
# 任何人都可以用自己的固件构建一次，再跟公开的清单逐文件比对，确认产物一致。
#
# 用法：
#   bash tools/manifest.sh gen  <模块目录 | 模块zip> [输出文件]
#   bash tools/manifest.sh cmp  <清单A> <清单B>
#   bash tools/manifest.sh sum  <清单>
#
# 清单格式（按路径排序，内容确定，可直接 git diff）：
#   <sha256>  <size>  <mode>  <path>
#   mode 列：目录为八进制权限（如 644）；zip 不保留权限，记为 "-"
set -euo pipefail

cmd=${1:-}

usage() { sed -n '2,16p' "$0"; }

gen() {  # $1 = dir 或 zip
  python3 - "$1" <<'PY'
import sys, os, hashlib, zipfile

src = sys.argv[1]
rows = []

def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

if os.path.isdir(src):
    for root, dirs, files in os.walk(src):
        for n in files:
            p = os.path.join(root, n)
            if os.path.islink(p):
                continue
            rel = os.path.relpath(p, src).replace(os.sep, '/')
            st = os.stat(p)
            rows.append((rel, st.st_size, oct(st.st_mode & 0o777)[2:], sha(p)))
elif zipfile.is_zipfile(src):
    z = zipfile.ZipFile(src)
    for i in z.infolist():
        if i.is_dir():
            continue
        name = i.filename
        # 没打 UTF-8 标志位时，zip 规范默认 cp437；我们的包实际是 UTF-8，手工还原
        if not (i.flag_bits & 0x800):
            try:
                name = name.encode('cp437').decode('utf-8')
            except (UnicodeEncodeError, UnicodeDecodeError):
                pass
        h = hashlib.sha256()
        with z.open(i) as f:
            for chunk in iter(lambda: f.read(1 << 20), b''):
                h.update(chunk)
        rows.append((name, i.file_size, '-', h.hexdigest()))
else:
    sys.exit('找不到（或不是目录/zip）：' + src)

rows.sort(key=lambda r: r[0])
out = sys.stdout
for rel, size, mode, h in rows:
    out.write('%s  %d  %s  %s\n' % (h, size, mode, rel))
PY
}

case "$cmd" in
  gen)
    src=${2:?用法: manifest.sh gen <目录|zip> [输出文件]}
    out=${3:-}
    if [ -n "$out" ]; then
      gen "$src" > "$out"
      echo "manifest: $out（$(wc -l < "$out") 个文件，$(du -h "$out" | cut -f1)）"
    else
      gen "$src"
    fi
    ;;
  cmp)
    a=${2:?缺清单A}; b=${3:?缺清单B}
    norm() { awk '{print $1"  "$2"  "$4}' "$1" | LC_ALL=C sort -k3; }
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    norm "$a" > "$tmp/a"; norm "$b" > "$tmp/b"
    if diff -q "$tmp/a" "$tmp/b" >/dev/null; then
      echo "✅ 一致：$(wc -l < "$tmp/a") 个文件的 SHA-256 全部相同"
    else
      echo "❌ 不一致（< 为 A，> 为 B），前 60 行差异："
      diff "$tmp/a" "$tmp/b" | head -60
      echo "……差异行数：$(diff "$tmp/a" "$tmp/b" | grep -c '^[<>]')"
      exit 1
    fi
    ;;
  sum)
    f=${2:?缺清单文件}
    echo "== 文件数 $(wc -l < "$f")，总大小 $(awk '{s+=$2} END{printf "%.1f MB", s/1048576}' "$f")"
    awk '{p=$4
          if      (p ~ /^system\/lib\//)        k="system/lib（32位通用库）"
          else if (p ~ /^system\/vendor\/lib\//)k="vendor/lib（32位厂商库）"
          else if (p ~ /^system\/odm\/lib\//)   k="odm/lib（32位 HAL）"
          else if (p ~ /^system\/system_ext\/bin\//) k="system_ext/bin（tango_translator 等）"
          else if (p ~ /^system\/bin\//)        k="system/bin（app_process32 等）"
          else if (p ~ /^system\/framework\//)  k="system/framework（shim）"
          else if (p ~ /^apex_cn\//)            k="apex_cn（私有命名空间用整棵 APEX）"
          else if (p ~ /^apex\//)               k="apex（32位库分层）"
          else                                  k="其它（脚本/清单）"
          print k}' "$f" | LC_ALL=C sort | uniq -c | sort -rn | sed 's/^ */  /'
    ;;
  *) usage; exit 1;;
esac
