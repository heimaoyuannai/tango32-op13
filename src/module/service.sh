#!/system/bin/sh
# Tango32 · KernelSU 版 service.sh
# 开机后：① 兜底注册 binfmt ②（默认）拉起 32 位 zygote ③ 写诊断报告
# 关闭自启动：在模块目录创建 noautostart 文件（或 ksud resetprop -p persist.sys.tango_zygote32.start 0）
MODDIR=${0%/*}
LOG=$MODDIR/tango32.log
KSUD=/data/adb/ksu/bin/ksud
OUT=/storage/emulated/0/Download/Tango32-报告.txt
AUTO=autostart

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
sleep 3

# ---- ① binfmt 兜底 ----
{
  echo; echo "== service.sh $(date)"
  if [ -e /proc/sys/fs/binfmt_misc/tango_translator ]; then
    echo "binfmt: 已存在"
  else
    [ -e /proc/sys/fs/binfmt_misc/register ] || mount -t binfmt_misc none /proc/sys/fs/binfmt_misc
    T=/system_ext/bin/tango_translator
    [ -x "$T" ] || T=$MODDIR/system_ext/bin/tango_translator
    [ -x "$T" ] || T=$MODDIR/system/system_ext/bin/tango_translator
    REG=':tango_translator:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfe\xff\xff\xff:'"$T"':POCF'
    echo "binfmt: 注册 $T"
    printf '%s' "$REG" > /proc/sys/fs/binfmt_misc/register && echo "  register OK" || echo "  register FAILED"
    echo 1 > /proc/sys/fs/binfmt_misc/tango_translator 2>/dev/null
  fi
  head -2 /proc/sys/fs/binfmt_misc/tango_translator 2>&1
} >>"$LOG" 2>&1

# ---- ② 拉起 32 位 zygote（默认开启；noautostart 可关） ----
if [ -e /proc/sys/fs/binfmt_misc/tango_translator ] && [ ! -e "$MODDIR/noautostart" ]; then
  echo "== 拉起 zygote_tango" >>"$LOG"
  $KSUD resetprop -p persist.sys.tango_zygote32.start 1 2>/dev/null
  sleep 6
else
  echo "== 不自动启动（noautostart 或 binfmt 未就绪）" >>"$LOG"
fi

# ---- ③ 报告 ----
{
  echo "---- 状态 ----"
  echo "zygote_tango=$(getprop init.svc.zygote_tango) pid=$(getprop init.svc_debug_pid.zygote_tango)"
  echo "abilist=$(getprop ro.product.cpu.abilist) abilist32=$(getprop ro.product.cpu.abilist32)"
  echo "min_supported_target_sdk=$(getprop ro.build.version.min_supported_target_sdk)"
  echo "system/lib=$(ls /system/lib 2>/dev/null | wc -l) vendor/lib=$(ls /system/vendor/lib 2>/dev/null | wc -l) odm/lib=$(ls /odm/lib 2>/dev/null | wc -l)"
  ls -l /system/bin/app_process32 /system/bin/app_process32_tango /system/bin/linker /system_ext/bin/tango_translator 2>&1
  ls -l /system/lib/libframework-connectivity-tiramisu-jni.so /system/lib/libc.so 2>&1
  echo "---- wrapper 日志 ----"
  echo "启动计数=$(cat /dev/tango32_starts 2>&1)"
  tail -20 /dev/tango32_ns.log 2>&1
  echo "---- 近期错误 ----"
  logcat -d -b crash -t 300 2>/dev/null | grep -iE "app_process32|tango|zygote_tango|UnsatisfiedLink|CANNOT LINK" | tail -10
} >>"$LOG" 2>&1

cp "$LOG" "$OUT" 2>/dev/null
chmod 0644 "$OUT" 2>/dev/null
