# 在 GitHub Actions 上构建（以及如何让别人验证你的构建）

## 为什么仓库里没有模块 zip

模块 zip 里 95% 的内容是从固件提取的 OnePlus / OPPO / Qualcomm 二进制（`/system/lib` 等 900+ 个 `.so`、APEX 32 位库、`tango_translator`）。这些代码的版权不属于本项目，GPL-3.0 也覆盖不到它们，**公开分发会有 DMCA 下架甚至封号风险**（上游 Tango32 同样明确要求不要分发构建产物）。

所以仓库只放：

| 放什么 | 为什么安全 |
|---|---|
| 构建脚本、shim 源码、模块脚本、文档 | 原创，GPL-3.0 |
| `tools/manifest.sh` 生成的**清单（路径+大小+SHA-256）** | 只含哈希，不含内容；别人可以用来比对 |
| CI 工作流 | 只写流程，不存固件 |

---

## 一、GitHub Actions 构建

工作流模板：**[`docs/github-workflow-build.yml`](github-workflow-build.yml)**（手动触发 `workflow_dispatch`）。

> 它暂放在 `docs/` 下，因为推送 `.github/workflows/*` 需要 token 带 `workflow` 权限。
> 启用：在 GitHub 网页新建 `.github/workflows/build.yml` 粘贴内容，或用带 `repo+workflow` 权限的 token 移动它。

### 1. 准备两个固件直链

| 输入 | 内容 | 说明 |
|---|---|---|
| `CN_FW_URL` | 国行 ColorOS 全量包的 `*-image-logical.7z.001` 直链 | 工作流会自动再拉 `.002/.003/.004` 三个分卷 |
| `OOS_FW_URL` | 氧OS 全量 OTA zip 直链 | 用来取 `framework.jar`、`oplus-framework.jar` 和构建指纹 |

两者都必须与目标机型/版本对应（本项目为 **16.0.7.201**）。工作流**不会**内置任何下载地址。

配置方式（推荐用 Secrets，避免地址写进日志）：

```
仓库 → Settings → Secrets and variables → Actions
  New repository secret
    CN_FW_URL  = https://.../PJZ110_16.0.7.201-CN01_CN-image-logical.7z.001
    OOS_FW_URL = https://.../CPH2653_16.0.7.201-full-ota.zip
（可选）Variables → New repository variable
    RUNNER_LABEL = 你的自建 runner 标签
```

### 2. 触发

```
Actions → build-module → Run workflow
  cn_fw_url  （留空则用 Secrets.CN_FW_URL）
  oos_fw_url （留空则用 Secrets.OOS_FW_URL）
  ver        v1.0-op13
```

### 3. 资源要求（很重要）

| 项目 | 需求 |
|---|---|
| 磁盘 | **≥ 40 GB**（国行 4 券 ~8 GB + 解包 ~10 GB + 氧OS OTA ~8 GB + payload 解包 ~10 GB） |
| 时间 | 首次约 30–60 分钟（大头是下载） |
| 内存 | 4 GB 起（默认 runner 够） |

**GitHub 托管的 `ubuntu-latest` 免费额度磁盘通常只有 ~14 GB 空闲，很可能跑不完。** 磁盘不够时请：

- 用自建 runner（`RUNNER_LABEL` 指向它），或
- 本地跑（见下一节），或
- 把固件解包后的 4 个 `.img` 用自己的方式放进 `work/img/`，从第 4 步开始跑

### 4. 产物

workflow artifact（保留 3 天）：

- `tango32-*.zip` —— 模块本体
- `manifest.txt` —— 内容清单（路径/大小/SHA-256）
- `build.txt` —— 构建指纹

> ⚠️ artifact 只是方便**你自己**下载到自己的手机上。**不要**把它上传到 Releases、网盘或任何公开位置。

---

## 二、本地构建（推荐，可控）

```bash
# 1) 工具
bash scripts/prepare-tools.sh              # 下载 smali / R8 到 tools/
sudo apt install -y default-jdk-headless clang lld zip unzip p7zip-full erofs-utils

# 2) 国行镜像 → work/img/{system,system_ext,vendor,odm}.img
#    7z x PJZ110_...-image-logical.7z.001 -owork/img

# 3) 氧OS 侧：从 OTA 里取 system.img → 解包 → 拷 framework.jar / oplus-framework.jar
#    payload-dumper-go -o work/oos work/oos/payload.bin
#    fsck.erofs --extract=work/oos/fs --no-preserve work/oos/img/system.img
#    然后把两个 jar 放进 work/fw/，并按 build.prop 写 work/fw/build.txt

# 4) 构建
CNIMG=$PWD/work/img USFW=$PWD/work/fw WORK=$PWD/work \
  SM3=$PWD/tools/smali3 R8=$PWD/tools/r8.jar \
  bash scripts/build.sh
```

产物：`work/module/tango32-<ver>.zip`。

---

## 三、用清单交叉验证（推荐给想复现的人）

模块里每个文件的哈希都能公开比对，不需要交换任何二进制：

```bash
# 生成你自己构建的清单
bash tools/manifest.sh gen work/module/tango32  my-manifest.txt
bash tools/manifest.sh sum  my-manifest.txt

# 和上游公布的清单比对（严格逐文件 SHA-256）
bash tools/manifest.sh cmp  my-manifest.txt  reference-manifest.txt
# ✅ 一致：1287 个文件的 SHA-256 全部相同
```

清单格式固定、按路径排序，可以直接 `git diff`：

```
<sha256>  <size>  <mode>  <path>
```

### 本仓库自带的参考清单

`manifest/tango32-v1.0-op13-CPH2653_16.0.7.201.txt` 是我在自己手机上构建产物的清单（2000+ 个文件，只含哈希）。
你若用**同版本同地区**固件构建，`cmp` 应该逐文件一致：

```bash
bash tools/manifest.sh gen work/module/tango32 mine.txt
bash tools/manifest.sh cmp manifest/tango32-v1.0-op13-CPH2653_16.0.7.201.txt mine.txt
```

不一致时按这个顺序排查：

| 差异集中的位置 | 说明 |
|---|---|
| `system/lib/**`、`system/vendor/lib/**` | 国行固件版本/地区不同 |
| `system/framework/tango-shim.jar` | 氧OS 侧 `framework.jar` 不同（地区或版本） |
| `module.prop` / `build.txt` | 版本号、构建时间不同，属正常 |
| 只有个别 `apex_cn/**` | 解包工具版本差异，一般可忽略 |

### 一致性说明

同一固件 + 同一套输入，理论上应当逐字节一致；以下几类差异属正常：

| 差异 | 原因 |
|---|---|
| `module.prop` / `build.txt` 里的版本号、构建时间 | 构建参数不同 |
| 清单里 `mode` 列（zip 为 `-`） | zip 不保留权限，`gen` 用 `-` 占位 |
| `apex_cn/**` 顺序 | 不参与哈希，仅列表顺序 |

如果 `cmp` 报不一致，先看差异集中的分区：`system/lib` 不一致 = 国行固件版本不同；`system/framework/tango-shim.jar` 不一致 = 氧OS 侧框架版本不同。

---

## 四、注意

- 本工作流**不下载、不缓存**任何厂商固件到仓库；地址由使用者自己提供
- 产物仅限自用；再次分发厂商二进制违反著作权法与 GitHub 的 DMCA 政策
- 换固件后必须重新构建（模块与 `ro.build.fingerprint` 强绑定）
