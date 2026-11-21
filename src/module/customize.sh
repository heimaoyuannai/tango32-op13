# Tango32 · 一加13 / OxygenOS 16.0.7.201（KernelSU）
# 安装前硬校验：机型 + 完整 fingerprint 必须与构建时一致，否则不写任何东西。
SKIPUNZIP=1

ui_print "- 安装 Tango32 @VER@ (一加13 / OOS 16.0.7.201)"
stop() { ui_print "$1"; ui_print "! 未安装，手机没有被改动。"; rm -rf "$MODPATH"; abort "! 中止。"; }
unzip -oq "$ZIPFILE" target.prop -d "$MODPATH" >/dev/null 2>&1
T="$MODPATH/target.prop"
[ -f "$T" ] || stop "! 缺少 target.prop：这个 zip 不是本机构建出来的。"
TM=$(sed -n 's/^model=//p' "$T"); TF=$(sed -n 's/^fingerprint=//p' "$T"); TD=$(sed -n 's/^display=//p' "$T")
MODEL=$(getprop ro.product.model); FP=$(getprop ro.build.fingerprint); DISP=$(getprop ro.build.display.id)
case "$MODEL" in PJZ110|CPH2653) ;; *) stop "! 机型不对：这是 $MODEL，本模块为一加13 (PJZ110/CPH2653) 构建。";; esac
[ "$MODEL" = "$TM" ] || stop "! 机型不对：当前 $MODEL，模块构建于 $TM。"
[ "$FP" = "$TF" ] || {
  ui_print "! 固件不对。模块构建于："; ui_print "!   $TD"; ui_print "! 当前系统："; ui_print "!   $DISP"
  stop "! 需要用当前固件重新构建。"; }
ui_print "- 固件校验 OK: $DISP"
[ -e /dev/tango32 ] || stop "! 没有 /dev/tango32：内核没带 Tango 驱动。"
grep -q binfmt_misc /proc/filesystems || stop "! 内核缺少 binfmt_misc。"

ui_print "- 解压模块文件"
unzip -oq "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >/dev/null 2>&1 || stop "! 解压失败。"

ui_print "- 设置权限"
find "$MODPATH" -type d -exec chmod 0755 {} +
find "$MODPATH" -type f -exec chmod 0644 {} +
chown -hR 0:0 "$MODPATH"
chcon -hR u:object_r:system_file:s0 "$MODPATH" 2>/dev/null
for f in system/bin/app_process32 system/bin/app_process32_tango system/bin/bootstrap/linker \
         system/system_ext/bin/tango_translator system_ext/bin/tango_translator \
         apex/com.android.runtime/bin/linker apex/com.android.runtime/bin/crash_dump32 \
         apex/com.android.art/bin/dex2oat32 apex/com.android.art/bin/dalvikvm32 \
         post-fs-data.sh service.sh uninstall.sh; do
  [ -e "$MODPATH/$f" ] && chmod 0755 "$MODPATH/$f"
done
for f in "$MODPATH"/apex_cn/*/bin/*; do [ -f "$f" ] && chmod 0755 "$f"; done
find "$MODPATH" -name tango_translator -exec chmod 0755 {} + 2>/dev/null
find "$MODPATH" -name linker -type f -exec chmod 0755 {} + 2>/dev/null

ui_print "- 应用 SELinux 标签"
n=0
while read -r p c; do
  [ -n "$p" ] || continue
  chcon -h "$c" "$MODPATH/$p" 2>/dev/null && n=$((n+1))
done < "$MODPATH/contexts.txt"
ui_print "- 已标记 $n 个路径"

# 首次安装不开自动启动：先用手动方式验证 32 位 zygote 能起来，再开 autostart
[ -f "$MODPATH/autostart" ] || ui_print "- 默认不自动启动（验证通过后创建 autostart 才会随机启动）"
ui_print "- 安装完成"
ui_print "- 重启后 32 位应用才可安装（属性需要开机时生效）"
