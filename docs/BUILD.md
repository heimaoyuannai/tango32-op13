# 构建指南

## 你需要什么

| 项目 | 说明 |
|---|---|
| 手机 | 一加13（CPH2653 / PJZ110），已解锁 BL + root（本项目在 KernelSU 4.2 + SUSMOUNT 环境验证） |
| 本机固件（欧版/氧OS） | 用来取 `framework.jar`、`oplus-framework.jar`、构建指纹 |
| 同版本国行固件（ColorOS） | 用来取 32 位用户态；**版本必须与氧OS 一致**（本项目为 16.0.7.201） |
| 构建机 | Linux（x86_64 或 aarch64 都行），需要 `bash python3 javac clang lld zip unzip 7z fsck.erofs` |
| 磁盘 | 约 60 GB（两个固件解包 + 模块组装） |

> 本项目实际是在手机上的容器里构建的（aarch64 Linux），所以脚本里有些路径是 `/tmp/...` 的绝对路径，**按你的环境改一下 `scripts/build.sh` 顶部的变量**。

## 1. 准备两个固件

你的固件包通常是「卡刷包 / 全量 OTA」，里面是 `payload.bin`。解包方式：

```bash
# 1) 从 OTA zip 里取出 payload.bin（payload.bin 一般是 store 压缩，可以直接按偏移拷贝）
python3 - <<'EOF'
import zipfile, struct
z = zipfile.ZipFile("国行16.0.7.201.zip")
i = z.getinfo("payload.bin")
f = open(z.filename, 'rb'); f.seek(i.header_offset)
sig, ver, flag, comp, t, d, crc, csz, usz, nlen, elen = struct.unpack('<4sHHHHHIIIHH', f.read(30))
f.read(nlen); f.read(elen)
print(i.header_offset + 30 + nlen + elen, i.file_size)   # 偏移 与 大小
EOF

# 2) 按上面的偏移/大小 dd 出 payload.bin，用 payload-dumper-go 解分区
payload-dumper-go -o img payload.bin

# 3) 分区是 EROFS，展开成目录树
fsck.erofs --extract=fs/system --no-preserve img/system.img
```

需要解出：**system、system_ext、vendor、odm** 四个分区（本项目的 `IMGS`）。

## 2. 取本机框架（氧OS）

```bash
# framework.jar / oplus-framework.jar 直接从手机拿
adb pull /system/framework/framework.jar
adb pull /system/framework/oplus-framework.jar
```

再写一个 `fw/build.txt`（模块开机校验用，必须与手机完全一致）：

```
model=PJZ110
display=CPH2653_16.0.7.201(EX01)
fingerprint=OnePlus/CPH2653EEA/OP5D55L1:16/BP2A.250605.015/V.R4T3.1acb2c0_8f96c8_8d5fa9:user/release-keys
ota=CPH2653_11.F.89_2890_202605091219
```

> `build.sh` 里的 `MODELS` / `TESTED` 也要改成你的机型与版本，否则构建守卫会拒。

## 3. 改路径并构建

```bash
# scripts/build.sh 顶部：
#   HERE=你的仓库路径
#   FS=<国行解包后的 system/system_ext/vendor/odm 所在目录>
#   AP=<国行 APEX 解包目录>
#   CNIMG=<国行 .img 所在目录>
#   USFW=<上一步的 fw 目录>
#   SM3=smali 工具目录, R8=r8.jar

bash scripts/build.sh
# 产物：work/module/tango32-<ver>.zip
```

构建脚本会依次做：

1. 校验 `fw/build.txt` 的机型与版本
2. 解包国行分区、提取 APEX
3. 生成 `tango-shim.jar`（`ZygoteInit` 两处补丁 + `TangoFdFix`，含框架 JNI 库预加载列表）
4. 组装模块：32 位库、`app_process32`、`tango_translator`、APEX 32 位库、`apex_cn` 整树
5. **[4b2]** 把 19 个 APEX 框架库平铺进 `/system/lib`（排除 ART/runtime/adbd）
6. **[4c]** 实体化所有符号链接（`materialize_links.py`）
7. 生成 SELinux `contexts.txt`、模块脚本、`target.prop`
8. 打包 zip

## 4. 安装与验证

```bash
# 安装（KernelSU）
ksud module install /storage/emulated/0/Download/tango32-<ver>.zip
# 重启
```

重启后：

```bash
getprop init.svc.zygote_tango          # 期望 running
ls /proc/sys/fs/binfmt_misc            # 期望有 tango_translator
getprop ro.product.cpu.abilist32       # 期望 armeabi-v7a,armeabi
```

然后直接安装任意 32 位 APK 测试。出问题先看
`/storage/emulated/0/Download/Tango32-报告.txt`，或运行 `ksud module action tango32`。

## 5. 换固件后重新构建

1. 用新固件的 `framework.jar` / `oplus-framework.jar` 覆盖 `fw/`
2. 更新 `fw/build.txt` 的 `display` / `fingerprint` / `ota`
3. 用**同版本**国行固件重做步骤 1
4. 重新 `build.sh` → 卸载旧模块 → 装新模块 → 重启

> 反过来，如果只换国行版本而氧OS 没变，也会因为 `core-oj` 与 `libart.so` 不配套而 `Class mismatch`，所以两边版本要一致。
