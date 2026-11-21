# Tango32 for OnePlus 13 · OxygenOS 16.0.7.201

**在氧OS（OxygenOS）上为没有 32 位执行能力的一加13 补回 32 位应用支持。**

一加13（骁龙 8 Elite / SM8750，ARMv9）在硬件层面移除了 AArch32 执行能力，国行 ColorOS 通过内置的 **Tango 翻译器**（`/dev/tango32` 内核驱动 + `tango_translator` binfmt 解释器）让 32 位应用继续可用，而 OxygenOS 把这套 32 位用户态整个剥掉了——内核驱动、`/dev/tango32` 设备节点、`init.otranslator.zygote.rc` 里的 `zygote_tango` 服务全都还在，缺的只是用户态本体。

本项目把这部分补齐：从**同版本**国行固件里提取 32 位用户态（`/system/lib`、`/system_ext/lib`、`/vendor/lib`、`/odm/lib`、`app_process32`、`tango_translator`、ART/runtime/i18n/conscrypt APEX 的 32 位库），配一个极小的框架 shim，用 init 里**已经存在**的 `zygote_tango` 服务拉起第二个 32 位 zygote。

- 已验证机型/固件：**OnePlus 13（CPH2653 / PJZ110，EEA）· OxygenOS 16.0.7.201(EX01)**
- 已验证 root 方案：**KernelSU 4.2.0（含 SUSFS）+ NoMount metamodule**
- 已实测 32 位应用：`com.jhws` 2.9.8.76（targetSdk 25，仅 armeabi-v7a）——安装、启动、渲染均正常

> 本仓库**只包含源码与构建脚本**，不含任何从固件提取的二进制。模块 zip 必须由你自己用本机固件构建（见 [`docs/BUILD.md`](docs/BUILD.md)），因为里面是一加/OPPO 的专有代码，不能分发。

---

## 它怎么工作

```
init  ──(persist.sys.tango_zygote32.start=1 + tango props)──►  service zygote_tango
                                                                 │
                                              /system/bin/app_process32  ← 本模块提供的 wrapper(sh)
                                                                 │
                                              unshare -m，把国行 APEX 树 rbind 到 /apex
                                                                 │
                                              exec /system/bin/app_process32_tango
                                                                 │
                                    kernel: ELF32 → binfmt_misc → /system_ext/bin/tango_translator
                                                                 │
                                              32 位 ART（国行 core-oj/libart）加载 OOS framework.jar
                                                         + tango-shim.jar（2 处 ZygoteInit 补丁）
                                                                 │
                                                          32 位 app 进程
```

详细原理与逐项排查过程见 [`docs/HOW-IT-WORKS.md`](docs/HOW-IT-WORKS.md)，
踩过的 9 个坑见 [`docs/FIXES.md`](docs/FIXES.md)。

## 快速开始

1. 按 [`docs/BUILD.md`](docs/BUILD.md) 用**你自己的**固件构建出 `tango32-<ver>.zip`
2. KernelSU 管理器 → 模块 → 从存储安装该 zip → 重启
3. 重启后 `getprop init.svc.zygote_tango` 应为 `running`，32 位 APK 可直接安装

### 诊断与开关

| 目的 | 操作 |
|---|---|
| 查看开机报告 | `/storage/emulated/0/Download/Tango32-报告.txt` |
| 手动跑一次诊断 | `ksud module action tango32` |
| 关闭开机自启动 | 在 `/data/adb/modules/tango32/` 建 `noautostart` |
| 立即停止 32 位 zygote | `ksud resetprop -p persist.sys.tango_zygote32.start 0` |
| 保留 SUSFS 挂载隐藏 | 在模块目录建 `keep_sus_hide`（32 位支持可能失效） |
| 卡开机 | 用 KernelSU 安全模式禁用 `tango32` 模块（不涉及 boot 分区改动） |

## 复现、验证与构建产物（重要）

**本仓库不提供模块 zip。** 模块里 95% 的内容是从固件提取的 OnePlus / OPPO / Qualcomm 二进制
（`/system/lib` 等 900+ 个 `.so`、APEX 32 位库、`tango_translator`），版权不属于本项目，GPL-3.0 也覆盖不到它们——
公开分发会触发 DMCA 下架甚至封号（上游 Tango32 同样明确要求"don't redistribute built module zips"）。
`.gitignore` 已排除 `*.zip *.so *.apex *.apk *.img`。

想让别人能验证/复现，用下面两条合规路径：

**① 内容清单（只含哈希，不含二进制）**

```bash
bash tools/manifest.sh gen work/module/tango32  manifest.txt   # 生成
bash tools/manifest.sh sum  manifest.txt                       # 按分区统计
bash tools/manifest.sh cmp  mine.txt reference.txt             # 逐文件 SHA-256 比对
```

任何人都能用自己的固件构建一次，再跟公开的 `manifest.txt` 对比，确认产物一致——全程不交换任何厂商代码。

**② GitHub Actions 构建（工作流不含固件）**

`.github/workflows/build.yml` 手动触发，固件地址由使用者自己以 Secrets / 输入提供，产物只作为
workflow artifact（保留 3 天）给本人下载。详见 [`docs/CI.md`](docs/CI.md)（含磁盘/时间要求和自建 runner 的说明）。

| 需要你提供 | 说明 |
|---|---|
| `CN_FW_URL` | 国行全量包 `*-image-logical.7z.001` 的直链（自动续拉 002–004） |
| `OOS_FW_URL` | 氧OS 全量 OTA zip 直链（取 framework.jar + 构建指纹） |

> 构建出来的 zip 只用于**你自己的手机**；请勿上传到 Releases、网盘或任何公开位置。

## 兼容性说明

- 模块与构建时的 `ro.build.fingerprint` **强绑定**，开机校验不通过会自锁停用（不会半启动）
- 换固件后必须用新固件的 `framework.jar`/`oplus-framework.jar` + 新国行固件重新构建
- 只有**同版本**的国行固件才能用：32 位 ART 的 `core-oj` 必须和 `libart.so` 配套，跨版本会 `Class mismatch`
- 目前只在一加13 + KernelSU + NoMount 上验证；Magisk 路线理论上更接近上游实现，但未测试

## 致谢与许可

- 上游项目 **[ionTrix/Tango32](https://github.com/ionTrix/Tango32)**（GPL-3.0）：本项目的思路、shim 框架、模块结构与部分脚本源自它。原项目针对一加12（CPH2583/CPH2581），本项目是**针对一加13 / 氧OS 16.0.7.201 的移植与 KernelSU 适配**。
- Tango 翻译器本体属于 OnePlus / OPPO；本仓库不分发其任何二进制。
- 本项目同样以 **GPL-3.0** 发布，见 [`LICENSE`](LICENSE)。

不隶属于一加、OPPO 或 Google。OnePlus、OxygenOS、ColorOS 是其各自所有者的商标。
