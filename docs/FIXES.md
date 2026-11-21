# 踩过的 9 个坑（按发现顺序）

每一个都表现为「某个环节静默失败」，记录根因对后续移植/排查会很有用。

## 1. `tango_translator` / `linker` 缺少执行位

**表现**：`binfmt` 注册失败，但 shell 只打一句 `ERR: binfmt register failed`，内核没有任何报错。
**根因**：module 里这两个文件是 `0644`。binfmt_misc 注册带 `F` 标志时，内核会用**当前域**对解释器做 `open_exec()`，文件不可执行 → 返回 `EACCES`，而 `printf > register` 的失败被脚本吞掉。
**修复**：`customize.sh` 里对 `tango_translator`、`linker` 显式 `chmod 0755`，并加 `find -name` 兜底。

## 2. 误把 bootstrap 版 linker 放到 `/system/bin/linker`

**表现**：`CANNOT LINK EXECUTABLE "/system/bin/app_process32_tango": library "libc.so" not found`。
**根因**：Android 里 `bootstrap/linker` 是第一阶段用的简化 loader，**不读 `/linkerconfig/ld.config.txt`**，因此不会去 `/apex/com.android.runtime/lib/bionic` 找 `libc.so`。`PT_INTERP` 指向的 `/system/bin/linker` 必须是 APEX 里的**正式** linker。
**修复**：`build.sh` 改为从 `apex/com.android.runtime/bin/linker` 拷贝。

## 3. bionic 符号链接丢失

**表现**：同上，`libc.so not found`，但 linker 已经正确。
**根因**：国行 `/system/lib` 里 `libc.so`、`libdl.so`、`libdl_android.so`、`libm.so` 是**符号链接**（指向 `/apex/.../bionic/*`），解包/安装过程中被丢弃。
**修复**：`scripts/materialize_links.py` 在构建时把所有可解析符号链接**实体化**为真实文件。

## 4. KernelSU 的 busybox `unzip` 不创建符号链接

**表现**：`/apex/com.android.i18n/lib/libc++.so not found`（`libicu.so` 的依赖）。
**根因**：模块 zip 里 30 个符号链接全部没有创建出来（busybox unzip 的已知行为）。zygote 能加载的库一旦需要这些链接就断链。
**修复**：同 3，构建期实体化（30 个链接全部转成真实文件，模块体积 +~10MB）。

## 5. `ro.*` 属性写不进去

**表现**：`abilist32` 仍为空 → 32 位 APK 报 `INSTALL_FAILED_NO_MATCHING_ABIS`。
**根因**：`setprop` 对 `ro.*` 无效；Magisk 的 `resetprop` 在 KernelSU 上不存在。
**修复**：KernelSU 4.2 自带 **`ksud resetprop`**（支持 ro 属性直写 mmap），模块全部改用它。

## 6. SELinux：magiskpolicy → `ksud sepolicy`

**表现**：`/proc/sys/fs/binfmt_misc/register` 写入 `Permission denied`。
**根因**：`register` 的标签是 `binfmt_miscfs`，而模块脚本跑在 `u:r:ksu:s0` 域；另外 `tango32_device` 类型虽已存在，但缺少 `zygote`/`appdomain` 的访问授权。
**修复**：把上游的 `magiskpolicy --live` 全部换成 `ksud sepolicy patch`，并补充 `allow ksu binfmt_miscfs file { write open read getattr }`、`allow ksu system_lib_file file { ... execute ... }` 等规则。

## 7. 把 ART 核心库平铺进 `/system/lib` 导致 zygote 段错误

**表现**：`Fatal signal 11 (SIGSEGV), fault addr 0x168`，每 5 秒一次无限重启，没有 tombstone（`crash_dump` 也起不来）。
**根因**：为解决 `/apex/*/lib` 可见性问题，我把所有 APEX 32 位库都复制进 `/system/lib`，其中包含 `libart.so`、`libnativeloader.so`、`libsigchain.so`、`libnativehelper.so` 等 ART 核心库，与 APEX 内的版本形成重复/冲突。
**修复**：平铺时**排除 `com.android.art` / `com.android.runtime` / `com.android.adbd`**，只保留框架层需要的 19 个（connectivity/cronet、icu、crypto、media、statsd…）。

## 8. `Class mismatch for Ljava/lang/String;`

**表现**：
```
InitWithoutImage: Class mismatch for Ljava/lang/String;. This is most likely the result of
a broken build. Make sure that libcore and art projects match.
```
**根因**：32 位 `libart.so`（国行）与氧OS 的 64 位 ART APEX 里的 `core-oj.jar` 不配套。即使固件版本相同，ColorOS 也改过 core 库。
**修复**：让 `zygote_tango` 在**私有 mount namespace** 里把 `/apex/com.android.art`、`i18n`、`conscrypt`、`adbd` 换成国行 APEX 树（`post-fs-data` 铺到 `/dev/tango32_cn/`，wrapper 里 `rbind`）。这是上游的核心思路，移植时原样保留。

## 9. app 子进程加载框架 JNI 库失败（本项目最隐蔽的一个）

**表现**：zygote 正常 `running`，但一启动应用就：
```
java.lang.UnsatisfiedLinkError: dlopen failed: library "libframework-connectivity-tiramisu-jni.so" not found
    at android.net.TrafficStats.<clinit>(TrafficStats.java:71)
    at com.android.internal.os.RuntimeInit.commonInit(...)
```
换成 `libstats_jni.so` 之后继续失败，像打地鼠。

**根因**（三层叠加）：
1. `linkerconfig` 在**开机早期**生成 `/linkerconfig/ld.config.txt`，那时氧OS 的 `/apex/*/lib`（32 位）还不存在——所以 32 位进程的 APEX 命名空间里没有这些路径；
2. 这些加载发生在 **app 子进程**里，走的是 APEX 专属命名空间（`namespace.com_android_tethering` 等），只搜 `/apex/<pkg>/${LIB}`，不会去 `/system/lib` 找；
3. 于是即使把库复制进 `/system/lib` 也没用（验证过：`linkerconfig` 重新生成的结果与现有一致，路径本身没问题，缺的是「子进程能用它」）。

**验证方式**：在 shim 里给 32 位 zygote 加探针，发现 **zygote 自己 `System.loadLibrary()` 是成功的**，只有子进程失败。

**修复**：利用 ART 的「已加载库」缓存——**在 32 位 zygote 里预加载**这些框架 JNI 库（`TangoFdFix.probe()` 的 `PRELOAD` 列表）。子进程 `fork` 后 `System.loadLibrary` 命中缓存，不再走 `dlopen`，命名空间限制被绕过。
注意：`android`/`hwui`/`jnigraphics`/`media_jni` 这类核心库**不能**加进预加载列表（会直接 abort zygote），它们本来就由 `ZygoteInit.preload` 按 ART 内部顺序加载。

## 附：NoMount / SUSFS 带来的一个约束

模块的库走 NoMount 的 VFS 重定向，而 SUSFS 的 `hide_sus_mnts_for_non_su_procs=1` 会把这类挂载对**非-su 进程**隐藏——普通应用进程正是非-su，于是看不到 `/apex`、`/system` 的 32 位库。
`post-fs-data` 因此在开机时把它设为 `0`。想保留隐藏就在模块目录建 `keep_sus_hide`（代价：32 位支持可能失效）。
