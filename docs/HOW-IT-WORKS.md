# 工作原理

## 背景：一加13 为什么跑不了 32 位应用

一加13 使用骁龙 8 Elite（SM8750），CPU 是 ARMv9.2A 的 Cortex-X925 + A725，**硬件层面不再支持 AArch32 执行状态**，因此：

- `ro.product.cpu.abilist` 只有 `arm64-v8a`，`abilist32` 为空
- `/system/lib`、`/vendor/lib`、`/odm/lib`、APEX 的 `lib/` 全部被剥掉
- `linker32`、`app_process32`、`dalvikvm32` 都不存在

但国行 ColorOS **保留了软件翻译方案**（OPPO 内部称 Tango）：

| 组件 | 位置 | 氧OS 是否存在 |
|---|---|---|
| `tango32` 内核模块 | `/vendor/lib/modules`，已加载 | ✅ 在（`/proc/modules` 可见） |
| `/dev/tango32` 字符设备 | 标签 `u:object_r:tango32_device:s0` | ✅ 在 |
| `zygote_tango` 服务定义 | `/system_ext/etc/init/init.otranslator.zygote.rc` | ✅ 在（与国行**逐字节一致**） |
| `init.zygote32.rc` | `/system/etc/init/hw/` | ✅ 在 |
| 32 位用户态（libs/app_process32/tango_translator） | — | ❌ **全部缺失** |

也就是说：**内核翻译器在、init 启动框架在，只差用户态**。这正是本项目能成立的前提。

## 运行时结构

### 1. 32 位 zygote 由 init 启动

`init.otranslator.zygote.rc` 里已经写好：

```
service zygote_tango /system/bin/app_process32 -Xzygote /system/bin --zygote --socket-name=zygote_secondary
    ...
    disabled

on property:sys.boot_completed=1 && property:ro.vendor.oplus.tango_binfmt_misc_support=1 \
   && property:ro.vendor.oplus.app32_boost_support=1 && property:persist.sys.tango_zygote32.start=1
    start zygote_tango
```

所以模块**不需要改 init、不需要注入 rc**，只要：

1. 提供 `/system/bin/app_process32`（真实二进制放在 `app_process32_tango`，原位置放 shell wrapper）
2. 把三个 od 属性置 1，最后置 `persist.sys.tango_zygote32.start=1`

### 2. `/system/bin/app_process32`（wrapper）

`src/module/system/bin/app_process32` 是一个 shell 脚本，做四件事：

1. `unshare -m` 进入私有 mount namespace
2. 把 `post-fs-data` 铺在 `/dev/tango32_cn/` 下的国行 APEX 树 `rbind` 到 `/apex/<name>`
3. 把 `tango-shim.jar` 插到 `BOOTCLASSPATH` 里 `framework.jar` 之前（`DEX2OATBOOTCLASSPATH` 同步）
4. `exec /system/bin/app_process32_tango`

> 为什么要换 APEX：32 位 `libart.so` 会校验 `core-oj.jar` 的类布局。氧OS 的 `core-oj`（64 位 ART APEX）与国行 32 位 `libart.so` 不配套时会直接
> `InitWithoutImage: Class mismatch for Ljava/lang/String;` 并 abort。把整个国行 ART APEX 树搬进私有命名空间即可，**64 位系统完全不受影响**（改动只在这个 namespace 里）。

### 3. 内核如何把 32 位 ELF 交给翻译器

`post-fs-data` 按国行 `tango-binfmt.rc` 注册 binfmt_misc：

```
:tango_translator:M::\x7fELF\x01\x01\x01...\x02\x00\x28\x00:\xff...:/system_ext/bin/tango_translator:POCF
```

- magic 匹配 ELF32 + `e_type=EXEC` + `e_machine=0x28`(ARM)
- `POCF`：保留 argv[0]、传入已打开的二进制 fd、传递凭据、固定解释器路径

内核随后 exec `tango_translator`，由它完成 AArch32 → AArch64 的指令翻译。

### 4. 框架 shim（`tango-shim.jar`）

只打了 **2 处** ZygoteInit 补丁，外加一个新类：

| 改动 | 原因 |
|---|---|
| `ZygoteInit.preload()` 里 `HttpEngine.preload()` 的 catch 从 `NoSuchMethodError` 放宽到 `Throwable` | 32 位没有 `libhttpengine.so`，失败只该记日志 |
| `ZygoteInit.main()` 在 `runSelectLoop()` 前插入 `TangoFdFix.run()` | 修复 fork 时 fd 白名单 abort（`/trace_marker` 等），并做框架 JNI 库预加载 |
| 新增 `com.android.internal.os.TangoFdFix` | 见上 |

> 上游 Tango32 针对一加12 打了 10 个类的补丁，那是为了弥补「国行 16.0.3.500 的 32 位库 vs 美版 16.0.10.601 框架」的版本差。
> 本项目两边都是 **16.0.7.201**，我逐条比对了 `libandroid_runtime.so` / `libhwui.so` / `libSchedAssistJni.so` 的 `JNINativeMethod` 注册表
> 与氧OS `framework.jar` 的 Java native 声明，**签名完全一致**，所以不需要任何签名改写。

### 5. 属性

`post-fs-data` 用 `ksud resetprop` 设置（KernelSU 的 ro 属性写入能力）：

```
ro.vendor.oplus.tango_binfmt_misc_support = 1
ro.vendor.oplus.app32_boost_support       = 1
ro.product.cpu.abilist[+32/64]            = arm64-v8a,armeabi-v7a,armeabi / armeabi-v7a,armeabi
dalvik.vm.isa.arm.variant                 = cortex-a75
ro.build.version.min_supported_target_sdk = 0        # 老 targetSdk 应用可直接安装
```

`abilist32` 必须在开机时生效，`PackageManagerService` 才会接受 32 位 APK；这也是**装完必须重启一次**的原因。

## 与上游 Tango32 的差异

| 项目 | 上游（一加12 / Magisk） | 本项目（一加13 / KernelSU） |
|---|---|---|
| 目标固件 | OOS 16.0.10.601 | OOS 16.0.7.201 |
| 国行来源 | PJD110 16.0.3.500 | PJZ110 16.0.7.201 |
| root 管理器 | Magisk | KernelSU 4.2.0（`ksud sepolicy/resetprop`） |
| 挂载实现 | Magisk magic mount | NoMount metamodule（VFS 路径重定向） |
| 框架 shim | 10 个类 | 1 个类（同版本无需签名改写）+ 预加载 |
| 32 位库位置 | `system/lib` 等 | 额外补 `odm/lib`，并把 19 个 APEX 框架库平铺进 `/system/lib` |
| 图形桥 `libtango_gui.so` | 需要（跨版本 parcel 差异） | 不需要（同版本 parcel 一致） |
| 自启动 | 开机 | 开机（`service.sh` 在 binfmt 就绪后拉起） |
