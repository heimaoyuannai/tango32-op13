#!/system/bin/sh
# Tango32 · KernelSU 版卸载清理
KSUD=/data/adb/ksu/bin/ksud
$KSUD resetprop -p -d persist.sys.tango_zygote32.start 2>/dev/null
for p in ro.product.cpu.abilist ro.system.product.cpu.abilist ro.vendor.product.cpu.abilist \
         ro.product.cpu.abilist32 ro.system.product.cpu.abilist32 ro.vendor.product.cpu.abilist32; do
  $KSUD resetprop -d $p 2>/dev/null
done
rm -rf /data/tango /data/dalvik-cache/arm /data/adb/tango32
rm -f /storage/emulated/0/Download/Tango32-报告.txt
exit 0
