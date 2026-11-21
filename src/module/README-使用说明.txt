Tango32 · 一加13 / OxygenOS 16.0.7.201（KernelSU 版）
=====================================================

作用：启用 OnePlus 的 Tango 32→64 位翻译器，让氧OS 能安装并运行 32 位应用。
原理：把国行 ColorOS 16.0.7.201 里的 32 位用户态（/system/lib、/system_ext/lib、
      /vendor/lib、/odm/lib、app_process32、tango_translator、ART/runtime/i18n/
      conscrypt APEX 的 32 位库）搬到氧OS，并用 init 里已有的 zygote_tango 服务
      拉起第二个 32 位 zygote；32 位 zygote 在私有 mount namespace 里用国行 APEX
      树替换 /apex（解决 core-oj/libart 版本匹配），框架端只打两处 ZygoteInit 补丁。

安装：KernelSU 管理器 → 模块 → 从存储安装本 zip → 重启。
      首次开机后 32 位应用即可正常安装；zygote_tango 会自动拉起（见 service.sh）。

关闭 / 排查：
  - 关闭自启动：在 /data/adb/modules/tango32/ 下创建 noautostart，重启
  - 立即停止：ksud resetprop -p persist.sys.tango_zygote32.start 0
  - 手动诊断：ksud module action tango32
  - 启动报告：/storage/emulated/0/Download/Tango32-报告.txt
  - 卡开机：KernelSU 安全模式（bakasu 开机禁用模块）关掉 tango32 模块即可

注意：模块与固件版本绑定（构建时记录 fingerprint），换固件后需重新构建。
