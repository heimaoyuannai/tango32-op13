#!/system/bin/sh
# Tango32 · KernelSU 版 Action：binfmt 注册 + 现场诊断（可用 ksud module action tango32 反复执行）
MODDIR=${0%/*}
KSUD=/data/adb/ksu/bin/ksud
LOG=$MODDIR/tango32.log
OUT=/storage/emulated/0/Download/Tango32-报告.txt

{
  echo; echo "==== action $(date) ===="
  echo "-- binfmt"
  if [ -e /proc/sys/fs/binfmt_misc/tango_translator ]; then echo "registered"; else
    [ -e /proc/sys/fs/binfmt_misc/register ] || mount -t binfmt_misc none /proc/sys/fs/binfmt_misc
    T=/system_ext/bin/tango_translator; [ -x "$T" ] || T=$MODDIR/system_ext/bin/tango_translator
    [ -x "$T" ] || T=$MODDIR/system/system_ext/bin/tango_translator
    REG=':tango_translator:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfe\xff\xff\xff:'"$T"':POCF'
    printf '%s' "$REG" > /proc/sys/fs/binfmt_misc/register && echo "register OK" || echo "register FAILED"
    echo 1 > /proc/sys/fs/binfmt_misc/tango_translator 2>/dev/null
  fi
  head -2 /proc/sys/fs/binfmt_misc/tango_translator 2>&1

  echo "-- 状态: zygote_tango=$(getprop init.svc.zygote_tango) pid=$(getprop init.svc_debug_pid.zygote_tango)"
  ZP=$(getprop init.svc_debug_pid.zygote_tango)
  if [ -n "$ZP" ] && [ -d /proc/$ZP ]; then
    echo "-- zygote_tango 命名空间里的关键挂载"
    grep -E " /apex/(com\.android\.(art|i18n|conscrypt|adbd|tethering|runtime))(/| )" /proc/$ZP/mountinfo | head -8
    echo "-- ns 里 libc / libart:"
    ls -l /proc/$ZP/root/apex/com.android.art/javalib 2>&1 | head -5
    ls -l /proc/$ZP/root/apex/com.android.art/lib/libart.so /proc/$ZP/root/system/lib/libc.so 2>&1
  fi

  echo "-- tethering 32 位库:"
  ls -lZ /apex/com.android.tethering/lib/libframework-connectivity-tiramisu-jni.so 2>&1
  ls -lZ /apex/com.android.tethering/lib 2>&1 | head -8

  echo "-- 最近的 UnsatisfiedLink / dlopen:"
  logcat -d -b all -t 4000 2>/dev/null | grep -iE "UnsatisfiedLink|dlopen failed|not found: needed|CANNOT LINK" | tail -12

  echo "-- avc denials:"
  logcat -d -b all -t 4000 2>/dev/null | grep "avc:" | grep -viE "app_data_file|untrusted_app" | tail -15
  dmesg 2>/dev/null | grep "avc:" | tail -15

  echo "-- 32 位 linker 自检:"
  /system/bin/linker --list /system/bin/app_process32_tango 2>&1 | tail -3
} >>"$LOG" 2>&1
cp "$LOG" "$OUT" 2>/dev/null
chmod 0644 "$OUT" 2>/dev/null
exit 0
