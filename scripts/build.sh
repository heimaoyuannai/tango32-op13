#!/bin/bash
# build13.sh — 为 一加13 (CPH2653 / PJZ110, OxygenOS 16.0.7.201) 构建 32 位运行时模块
# 来源：国行 ColorOS PJD110/PJZ110 16.0.7.201(CN01) 的 system/system_ext/vendor/odm + APEX
# 框架：本机 OxygenOS 16.0.7.201 的 framework.jar / oplus-framework.jar
# 输出：/tmp/build13/work/module/tango32-<ver>.zip
set -euo pipefail
VER=${VER:-v1.0-op13}
HERE=/tmp/build13
SRC=$HERE/src
W=$HERE/work
FS=$W/cnfw/fs
AP=$W/cnfw/apex
MODROOT=$W/module
MOD=$MODROOT/tango32
CNIMG=/tmp/cnfw/img
USFW=$W/fw
SH=$W/shim
SM3=/tmp/re/tools/smali3
R8=/tmp/re/tools/r8.jar
IMGS="system system_ext vendor odm"
TESTED="16.0.7.201"
MODELS="PJZ110 CPH2653"
NS_ALL="com.android.art com.android.i18n com.android.conscrypt com.android.adbd com.android.os.statsd com.android.media com.android.tethering com.android.mediaprovider com.android.neuralnetworks com.android.runtime"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "[0] 检查本机 framework (fw)"
[ -f $USFW/framework.jar ] && [ -f $USFW/oplus-framework.jar ] || { echo "FATAL: fw 缺 jar"; exit 1; }
[ -f $USFW/build.txt ] || { echo "FATAL: fw 缺 build.txt"; exit 1; }
bget() { sed -n "s/^$1=//p" $USFW/build.txt | head -1; }
case " $MODELS " in *" $(bget model) "*) echo "model OK: $(bget model)";; *) echo "FATAL: model $(bget model)"; exit 1;; esac
case "$(bget display)" in *"$TESTED"*) echo "firmware OK: $(bget display)";; *) echo "FATAL: $(bget display) != $TESTED"; exit 1;; esac

say "[1] 国行镜像 -> 文件树"
mkdir -p $FS
for i in $IMGS; do
  if [ ! -d "$FS/$i" ]; then
    [ -f "$CNIMG/$i.img" ] || { echo "FATAL: 缺 $CNIMG/$i.img"; exit 1; }
    mkdir -p "$FS/$i"
    fsck.erofs --extract="$FS/$i" --no-preserve "$CNIMG/$i.img" >/dev/null
    echo "  extract $i: $(du -sh $FS/$i | cut -f1)"
  else echo "  $i 已解包"; fi
done

say "[2] 提取 APEX"
mkdir -p $AP
for a in $FS/system/system/apex/*.apex $FS/system_ext/apex/*.apex; do
  [ -f "$a" ] || continue
  n=$(basename "$a" .apex); d=$AP/$n
  [ -d "$d/root" ] && continue
  mkdir -p $d/root
  unzip -oq -d $d "$a" apex_payload.img 2>/dev/null || { rm -rf $d; continue; }
  fsck.erofs --extract=$d/root --no-preserve $d/apex_payload.img >/dev/null 2>&1 || true
  rm -f $d/apex_payload.img
done
echo "  APEX: $(ls $AP | wc -l) 个"
for n in $NS_ALL; do [ -d $AP/$n/root ] || echo "  WARN: 缺 $n"; done

say "[3] 框架 shim（仅 ZygoteInit + TangoFdFix）"
rm -rf $SH; mkdir -p $SH/dex $SH/sm $SH/jar
unzip -oq $USFW/framework.jar 'classes*.dex' -d $SH/dex
SCP=$(ls $SM3/*.jar | tr '\n' ':')
SHIM_CLASSES='Lcom/android/internal/os/ZygoteInit;'
for d in $SH/dex/classes*.dex; do
  java -cp "$SCP" com.android.tools.smali.baksmali.Main d -a 35 --classes "$SHIM_CLASSES" -o $SH/sm "$d" 2>&1 | grep -v JAVA_TOOL || true
done
[ -f $SH/sm/com/android/internal/os/ZygoteInit.smali ] || { echo "FATAL: ZygoteInit 未取到"; exit 1; }
python3 -I "$SRC/shim/shim_edit.py" $SH/sm
J=$SH/java; rm -rf $J; mkdir -p $J/stub $J/src/com/android/internal/os $J/cls $J/dex
cp -r "$SRC/shim/stubs/." $J/stub/
cp "$SRC/shim/TangoFdFix.java" $J/src/com/android/internal/os/TangoFdFix.java
javac --release 11 -XDstringConcat=inline -cp $J/stub -d $J/cls $J/src/com/android/internal/os/TangoFdFix.java
java -cp $R8 com.android.tools.r8.D8 --release --min-api 29 --output $J/dex $J/cls/com/android/internal/os/TangoFdFix.class
java -cp "$SCP" com.android.tools.smali.baksmali.Main d -a 29 -o $SH/sm $J/dex/classes.dex 2>&1 | grep -v JAVA_TOOL || true
[ -f $SH/sm/com/android/internal/os/TangoFdFix.smali ] || { echo "FATAL: TangoFdFix 未生成"; exit 1; }
java -cp "$SCP" com.android.tools.smali.smali.Main a -a 29 -o $SH/jar/classes.dex $SH/sm 2>&1 | grep -v JAVA_TOOL || true
python3 -I "$SRC/tools/align_jar.py" $SH/jar/classes.dex $SH/tango-shim.jar
echo "  shim: $(sha256sum $SH/tango-shim.jar | cut -c1-16)"

say "[4] 组装模块"
rm -rf $MOD; mkdir -p $MOD
cp_dir() { mkdir -p "$2"; (cd "$1" && tar cf - --exclude=./modules --exclude=./rfsa .) | (cd "$2" && tar xf - ${3:-}); }
cp_dir $FS/system/system/lib      $MOD/system/lib
cp_dir $FS/system_ext/lib         $MOD/system/lib --skip-old-files     # 不能新建 /system_ext/lib，并进 /system/lib
cp_dir $FS/vendor/lib             $MOD/system/vendor/lib
cp_dir $FS/odm/lib                $MOD/system/odm/lib
[ -d $FS/product/lib ] && cp_dir $FS/product/lib $MOD/system/product/lib || true
mkdir -p $MOD/system/bin/bootstrap
cp -a $FS/system/system/bin/app_process32 $MOD/system/bin/app_process32_tango
cp -a $AP/com.android.runtime/root/bin/linker $MOD/system/bin/linker   # 正式 linker（bootstrap 版不读 ld.config.txt）
cp -a $FS/system/system/bin/bootstrap/linker $FS/system/system/bin/bootstrap/linker_asan $MOD/system/bin/bootstrap/ 2>/dev/null || \
  cp -a $FS/system/system/bin/bootstrap/linker $MOD/system/bin/bootstrap/
mkdir -p $MOD/system/system_ext/bin && cp -a $FS/system_ext/bin/tango_translator $MOD/system/system_ext/bin/
# 全局 32 位库分层（缺 lib 的 APEX 补 lib/）
for d in $AP/*; do n=$(basename $d); [ -d $d/root/lib ] || continue;
  mkdir -p $MOD/apex/$n; cp -a $d/root/lib $MOD/apex/$n/; done
mkdir -p $MOD/apex/com.android.runtime/bin $MOD/apex/com.android.art/bin
cp -a $AP/com.android.runtime/root/bin/linker $AP/com.android.runtime/root/bin/linker_asan $AP/com.android.runtime/root/bin/crash_dump32 $MOD/apex/com.android.runtime/bin/
cp -a $AP/com.android.art/root/bin/dalvikvm32 $AP/com.android.art/root/bin/dex2oat32 $MOD/apex/com.android.art/bin/
# 私有命名空间用的整棵国行 APEX
for n in $NS_ALL; do
  [ -d $AP/$n/root ] || continue
  mkdir -p $MOD/apex_cn/$n
  (cd $AP/$n/root && tar cf - --exclude=./lib64 --exclude=./app --exclude=./priv-app --exclude=./lost+found .) | (cd $MOD/apex_cn/$n && tar xf -)
done
mkdir -p $MOD/system/framework && cp $SH/tango-shim.jar $MOD/system/framework/tango-shim.jar
printf '%s\n' "# zygote_tango 私有命名空间里替换成国行 APEX 的名单" "# 每行一个；'#' 注释" \
  "com.android.art" "com.android.i18n" "com.android.conscrypt" "com.android.adbd" \
  "#com.android.os.statsd" "#com.android.media" "#com.android.tethering" "#com.android.mediaprovider" "#com.android.neuralnetworks" > $MOD/ns_apex.list
du -sh $MOD

# [4b2] 把 APEX 的 32 位库再平铺一份到 /system/lib
#   linkerconfig 在开机早期生成 ld.config.txt，那时 /apex/*/lib 还不存在（氧OS 剥掉了），
#   所以 32 位进程的命名空间里没有这些 APEX 库路径；放到 /system/lib 后就能按默认路径找到。
n=0
for d in $AP/*/root/lib; do
  [ -d "$d" ] || continue
  n_apex=$(basename $(dirname $(dirname "$d")))
  # ART / runtime / adbd 的核心库不能平铺：会和 APEX 版本冲突，导致 32 位 zygote 段错误
  case "$n_apex" in com.android.art|com.android.runtime|com.android.adbd) continue;; esac
  for f in "$d"/*.so; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    [ -e "$MOD/system/lib/$b" ] && continue
    cp -a "$f" "$MOD/system/lib/$b" && n=$((n+1))
  done
done
echo "  平铺 $n 个 APEX 32 位库到 system/lib"

say "[4c] 实体化符号链接（KSU 的 unzip 不建链接）"
python3 -I "$HERE/materialize_links.py" $MOD

say "[5] SELinux contexts"
python3 -I "$SRC/tools/contexts.py" "$FS" "$MOD"

say "[6] 模块脚本"
cp "$SRC/module/module.prop" "$MOD/module.prop"
cp "$SRC/module/customize.sh" "$MOD/customize.sh"
cp "$SRC/module/system/bin/app_process32" "$MOD/system/bin/app_process32"
cp "$SRC/module/post-fs-data.sh" "$MOD/post-fs-data.sh"
cp "$SRC/module/service.sh" "$MOD/service.sh"
cp "$SRC/module/uninstall.sh" "$MOD/uninstall.sh" 2>/dev/null || true
cp "$SRC/module/tango32_dir.sh" "$MOD/tango32_dir.sh" 2>/dev/null || true
cp "$HERE/action.sh" "$MOD/action.sh" 2>/dev/null || true
cp "$HERE/README-使用说明.txt" "$MOD/README-使用说明.txt" 2>/dev/null || true
mkdir -p "$MOD/META-INF/com/google/android"
cp "$SRC/module/META-INF/com/google/android/update-binary" "$MOD/META-INF/com/google/android/update-binary"
echo '#MAGISK' > "$MOD/META-INF/com/google/android/updater-script"
VC=100
sed -i "s/@VER@/$VER/g; s/@VC@/100/g" "$MOD/module.prop" "$MOD/customize.sh"
grep -E "^(model|display|fingerprint|ota|pulled)=" $USFW/build.txt > "$MOD/target.prop"
chmod 0755 "$MOD"/*.sh "$MOD/system/bin/app_process32"
for f in system/bin/app_process32_tango system/bin/bootstrap/linker system_ext/bin/tango_translator \
         apex/com.android.runtime/bin/linker apex/com.android.runtime/bin/crash_dump32 \
         apex/com.android.art/bin/dex2oat32 apex/com.android.art/bin/dalvikvm32; do
  [ -e "$MOD/$f" ] && chmod 0755 "$MOD/$f"
done
echo "system/bin/app_process32 u:object_r:zygote_exec:s0" >> "$MOD/contexts.txt"; sort -o "$MOD/contexts.txt" "$MOD/contexts.txt"
for s in "$MOD"/*.sh "$MOD/system/bin/app_process32"; do sh -n "$s" || { echo "FATAL: syntax $s"; exit 1; }; done

say "[7] 打包"
cd $MOD && rm -f $MODROOT/tango32-$VER.zip && zip -qry9 $MODROOT/tango32-$VER.zip .
sha256sum $MODROOT/tango32-$VER.zip | tee $MODROOT/tango32-$VER.zip.sha256
du -sh $MODROOT/tango32-$VER.zip
