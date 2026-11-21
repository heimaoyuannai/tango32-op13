#!/system/bin/sh
# Tango32 · KernelSU 版 post-fs-data（一加13 / OxygenOS 16.0.7.201）
# 与上游的差别：
#   1) magiskpolicy -> ksud sepolicy patch；resetprop -> ksud resetprop（KernelSU 无 Magisk 那两个工具）
#   2) 默认不自动启动 32 位 zygote（没有 autostart 文件时 persist.sys.tango_zygote32.start 保持 0），
#      先让系统把库/属性/标签铺好；验证通过后再开 autostart，避免开机反复重启 zygote_tango
#   3) 增加 odm/lib 支持（一加13 的显示/相机 32 位 HAL 在 /odm/lib）
MODDIR=${0%/*}
LOG=$MODDIR/tango32.log
KSUD=/data/adb/ksu/bin/ksud
exec >"$LOG" 2>&1
echo "== post-fs-data $(date)"
echo "ro.zygote=$(getprop ro.zygote) (expect zygote64)"
echo "root-manager: $( [ -x $KSUD ] && echo KernelSU || echo unknown )"

rp() { $KSUD resetprop "$@"; }
pol() { o=$($KSUD sepolicy patch "$1" 2>&1); r=$?; echo "sepol rc=$r :: $1${o:+ -> $o}"; [ $r = 0 ] || SEPOL_FAIL=$((SEPOL_FAIL+1)); }

block() {   # $1 = 原因 firmware|root，$2 = 描述
  rp -p -d persist.sys.tango_zygote32.start 2>/dev/null
  touch "$MODDIR/disable"; echo "$1" > "$MODDIR/blocked"
  [ -f "$MODDIR/module.prop.ok" ] || cp "$MODDIR/module.prop" "$MODDIR/module.prop.ok"
  sed "s|^description=.*|description=$2|" "$MODDIR/module.prop.ok" > "$MODDIR/module.prop"
  exit 0
}

# 00) 固件一致性
TP=$MODDIR/target.prop; TF=$(sed -n 's/^fingerprint=//p' "$TP" 2>/dev/null); FP=$(getprop ro.build.fingerprint)
if [ -z "$TF" ] || [ "$FP" != "$TF" ]; then
  echo "⛔ 固件不匹配: 模块构建于 ${TD:-unknown}，当前 $(getprop ro.build.display.id)"
  echo "   built: ${TF:-missing}"
  echo "   now  : $FP"
  block firmware "⛔ 已停用：手机固件与模块构建时的固件不一致，需要重新构建。"
fi
echo "固件校验 OK: $(getprop ro.build.display.id)"
if [ -f "$MODDIR/module.prop.ok" ]; then cat "$MODDIR/module.prop.ok" > "$MODDIR/module.prop"; rm -f "$MODDIR/module.prop.ok"; fi
rm -f "$MODDIR/blocked"

# 0) SELinux（只在运行时打好，重启即消失）
SEPOL_FAIL=0
pol "typeattribute tango32_device dev_type"
pol "allow { appdomain zygote app_zygote webview_zygote crash_dump } tango32_device chr_file { ioctl read write getattr lock append map open }"
pol "allow { appdomain zygote app_zygote webview_zygote } system_lib_file file { execute execute_no_trans read open getattr map }"
pol "allow zygote shell_exec file { read open getattr execute map }"
for t in toolbox_exec system_file zygote_exec; do
  pol "allow zygote $t file { read open getattr execute execute_no_trans map }"
done
for t in rootfs system_file system_lib_file apex_mnt_dir device tmpfs; do
  pol "allow zygote $t dir { mounton search getattr read open }"
done
pol "allow zygote zygote capability sys_admin"
pol "allow zygote device file { append write open getattr }"
pol "allow zygote device dir { write add_name remove_name create }"
pol "allow { zygote appdomain } crash_dump process2 nosuid_transition"
# binfmt_misc 的 register 写入（KernelSU 的脚本域是 ksu，不是 init）
pol "allow ksu binfmt_miscfs file { write open read getattr }"
pol "allow ksu binfmt_miscfs dir { search read open getattr }"
# ksu 域要能 open_exec 解释器（register 带 F 标志时内核会以当前域打开解释器）
pol "allow ksu system_file file { read open getattr execute execute_no_trans map }"
pol "allow ksu system_lib_file file { read open getattr execute execute_no_trans map }"
pol "allow ksu apex_mnt_dir dir { search read open getattr }"
pol "allow ksu tmpfs dir { mounton search read open getattr write add_name remove_name }"
pol "allow ksu device dir { mounton search read open getattr write add_name remove_name }"
pol "allow ksu system_file dir { mounton search read open getattr }"
pol "allow ksu system_lib_file dir { mounton search read open getattr }"
[ -e "$MODDIR/zygote_permissive" ] && pol "permissive zygote"
if [ $SEPOL_FAIL -gt 0 ]; then
  echo "⚠️ $SEPOL_FAIL 条 SELinux 规则没打上（继续，但 32 位 zygote 可能起不来）"
fi

# 1) 属性（ro.* 必须早于 system_server 读取）
rp ro.vendor.oplus.tango_allow32 true
rp ro.vendor.oplus.tango_binfmt_misc_support 1
rp ro.vendor.oplus.app32_boost_support 1
for p in ro.product.cpu.abilist ro.system.product.cpu.abilist ro.vendor.product.cpu.abilist; do
  rp $p arm64-v8a,armeabi-v7a,armeabi
done
for p in ro.product.cpu.abilist32 ro.system.product.cpu.abilist32 ro.vendor.product.cpu.abilist32; do
  rp $p armeabi-v7a,armeabi
done
rp dalvik.vm.isa.arm.variant cortex-a75
rp dalvik.vm.isa.arm.features default
rp tango.debug off
rp ro.build.version.min_supported_target_sdk 0
# 开机先置 0：由 service.sh 在 binfmt 就绪后再拉起 zygote_tango（避免时序竞争）
rp -p persist.sys.tango_zygote32.start 0

# 1b) SUSFS：不把本模块的挂载隐藏给非-su 进程（否则 32 位 app 看不到 /apex、/system 的库）
#     副作用：这些挂载对普通应用可见，root 隐藏强度略降。想保留隐藏：创建 keep_sus_hide 文件。
if [ ! -e "$MODDIR/keep_sus_hide" ]; then
  $KSUD susfs hide_sus_mnts_for_non_su_procs 0 2>/dev/null && echo "susfs: hide_sus_mnts=0"
else
  echo "susfs: 保留隐藏（keep_sus_hide）"
fi

# 2) 设备节点标签 + wrapper 日志
chcon u:object_r:tango32_device:s0 /dev/tango32 && echo "dev label ok" || echo "WARN: dev label failed"
for f in /dev/tango32_ns.log /dev/tango32_ns.nostart; do
  : > $f && chmod 0666 $f && chcon u:object_r:device:s0 $f
done

# 3) binfmt_misc 注册（等同国行 tango-binfmt.rc）
T=/system_ext/bin/tango_translator
[ -e "$T" ] || T=$MODDIR/system/system_ext/bin/tango_translator
[ -e /proc/sys/fs/binfmt_misc/register ] || mount -t binfmt_misc none /proc/sys/fs/binfmt_misc
if [ ! -e /proc/sys/fs/binfmt_misc/tango_translator ]; then
  REG=':tango_translator:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfe\xff\xff\xff:'"$T"':POCF'
  printf '%s' "$REG" > /proc/sys/fs/binfmt_misc/register \
    && echo "binfmt registered" || echo "ERR: binfmt register failed"
fi
echo 1 > /proc/sys/fs/binfmt_misc/tango_translator 2>/dev/null
head -3 /proc/sys/fs/binfmt_misc/tango_translator 2>/dev/null

echo "开始 /apex 32 位库分层 + 命名空间铺设"

# 4) 等 APEX 激活，然后给缺 lib 的 APEX 补 32 位 lib（stock 目录优先）
i=0
while [ $i -lt 40 ]; do
  s=$(getprop apexd.status); [ "$s" = activated ] || [ "$s" = ready ] && break
  sleep 0.5; i=$((i+1))
done
echo "apexd.status=$(getprop apexd.status)"

ctx() {
  local c
  c=$(/system/bin/stat -c %C "$1" 2>/dev/null)
  case "$c" in u:*) ;; *) c=$(/system/bin/ls -dZ "$1" 2>/dev/null | awk '{print $1}');; esac
  echo "$c"
}
place() {
  if [ -L "$1" ]; then
    ln -s "$(readlink "$1")" "$2" && /system/bin/chcon -h "$(ctx "$1")" "$2"
  elif [ -d "$1" ]; then
    mkdir "$2" && mount -o bind "$1" "$2"
  else
    touch "$2" && mount -o bind "$1" "$2"
  fi || { echo "  ERR place $1"; FAIL=1; }
}
merge() {
  local o=$1 m=$2 t=$3 e n
  mkdir -p "$t" && chmod 0755 "$t" && /system/bin/chcon "$(ctx "$o")" "$t" || { echo "  ERR dir $t"; FAIL=1; return; }
  for e in "$o"/*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    n=${e##*/}
    if [ -d "$e" ] && [ ! -L "$e" ] && [ -d "$m/$n" ] && [ ! -L "$m/$n" ]; then
      merge "$e" "$m/$n" "$t/$n"
    else
      place "$e" "$t/$n"
    fi
  done
  for e in "$m"/*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    n=${e##*/}
    if [ ! -e "$t/$n" ] && [ ! -L "$t/$n" ]; then
      place "$e" "$t/$n" && echo "  + ${t#/dev/tango32_apex}/$n"
    fi
  done
}

mkdir -p /dev/tango32_apex
for d in "$MODDIR"/apex/*; do
  n=${d##*/}; tgt=/apex/$n; S=/dev/tango32_apex/$n
  [ -d "$tgt" ] || { echo "skip $n (未激活)"; continue; }
  [ -d "$tgt/lib" ] && { echo "skip $n (lib 已存在)"; continue; }
  mkdir -p "$S" && mount -t tmpfs -o mode=0755 tango32 "$S" || { echo "ERR tmpfs $n"; continue; }
  FAIL=0
  echo "merge $n"
  merge "$tgt" "$d" "$S"
  if [ $FAIL = 0 ] && mount -o rbind "$S" "$tgt"; then
    if [ -s "$tgt/apex_manifest.pb" ]; then echo "bind $n ok"; else umount -l "$tgt"; echo "ERR bind $n empty after mount, reverted"; fi
  else
    echo "ERR bind $n (left stock)"
  fi
done
ls -l /apex/com.android.runtime/lib/bionic/libc.so /apex/com.android.art/lib/libart.so 2>&1

# 4b) 给 zygote_tango 私有命名空间铺整棵国行 APEX（只挂在 /dev 下，不碰全局 /apex）
mkdir -p /dev/tango32_cn
if [ -e "$MODDIR/ns_off" ]; then
  echo "ns_off present: 不铺 CN APEX"
else
  while read -r n; do
    case "$n" in ''|\#*) continue;; esac
    src=$MODDIR/apex_cn/$n; S=/dev/tango32_cn/$n
    [ -d "$src" ] && [ -d "/apex/$n" ] || { echo "ns skip $n"; continue; }
    mkdir -p "$S" && mount -t tmpfs -o mode=0755 tango32cn "$S" && chmod 0755 "$S" \
      && /system/bin/chcon "$(ctx /apex/$n)" "$S" || { echo "ERR ns tmpfs $n"; continue; }
    FAIL=0
    for e in "$src"/*; do place "$e" "$S/${e##*/}"; done
    [ -e "$S/lib" ] || { [ -d "$MODDIR/apex/$n/lib" ] && place "$MODDIR/apex/$n/lib" "$S/lib"; }
    if [ $FAIL = 0 ] && [ -s "$S/apex_manifest.pb" ] && [ -d "$S/lib" ]; then
      echo "ns stage $n ok"
    else
      umount -l "$S"; rmdir "$S"; echo "ERR ns stage $n (dropped)"
    fi
  done < "$MODDIR/ns_apex.list"
fi
ls -lZ /system/framework/tango-shim.jar 2>&1

# 5) ART 需要的目录
rm -rf /data/dalvik-cache/arm
mkdir -p /data/dalvik-cache/arm && chown root:system /data/dalvik-cache/arm && chmod 0771 /data/dalvik-cache/arm
chcon u:object_r:dalvikcache_data_file:s0 /data/dalvik-cache/arm
mkdir -p /data/tango/log /data/tango/pretrans_log && chmod 0755 /data/tango && chmod 0777 /data/tango/log /data/tango/pretrans_log
echo "post-fs-data done $(date)"
