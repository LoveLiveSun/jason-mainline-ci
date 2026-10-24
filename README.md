# jason 主线内核适配工程

Xiaomi Mi Note 3（`xiaomi,jason` / SDM660）跑 Linux 7.x 主线内核的云端构建与刷机工程。

内核源：[`sdm660-mainline/linux`](https://github.com/sdm660-mainline/linux) · 分支 `qcom-sdm660-7.2.y`

---

## 0. 先看结论：路径 A 的真实工作量

上一轮我给路径 A 标的估算是「约 1 天 / 风险低」。**核查完之后要更正这个估算。**

你是对的：jason 的主线适配已经做完了，设备树、内核配置、GPU/显示/触摸驱动全都就绪。
但有两件事我上一轮没查到，它们直接决定了工作量：

### 更正一：本机没有可编译内核的环境

| 方案 | 状态 |
|---|---|
| WSL | ❌ 被系统安全策略加入程序黑名单，无法启动 |
| Docker / Podman | ❌ 未安装 |
| VirtualBox / VMware | ❌ 未安装 |
| Hyper-V | ⚠️ 组件在，但无管理工具，启用需管理员权限 + 重启 |

`pmbootstrap` 和内核编译都强依赖 Linux（chroot、losetup、parted 等），**Windows 原生跑不了**。

→ 所以整个构建必须放到云端完成。本机只负责 `fastboot` 刷机（`adb`/`fastboot` 已就位）。

### 更正二：pmaports 里没有 jason 的设备包

postmarketOS Wiki 对 jason 的原话：

> This device has been tested with postmarketOS, but its device package
> **has not yet been added** to the postmarketOS repositories.
> This means that it **cannot be selected in pmbootstrap**.
>
> Pending device package in pmaports, waiting after kernel upgrade

而最初做这件事的 Kernel114514 那份 fork（`github.com/kernel114514/linux`）**已经消失**，
工作合进了 `sdm660-mainline/linux` 主仓库。但设备包始终没人提交。

→ 所以 `pmbootstrap init` 里选不到 jason。**设备包得自己写**（本工程已经写好了）。

### 修正后的估算

| 阶段 | 内容 | 难度 |
|---|---|---|
| **Track 1** | 云端编内核 → 组装 boot.img → 刷入 → 点亮屏幕 | 半天，工程都已备好 |
| **Track 2** | 补上设备包 → 云端构建完整 postmarketOS → 拿到可用系统 | 数天，设备包已写好但要调 |
| **Track 3** | Track 1 点不亮时的备用链路（lk2nd + U-Boot） | 看情况 |

---

## 1. 快速开始（Track 1）

目标是**最短路径拿到一个可验证的结果**：内核起来、屏幕有输出、USB 网络能通。
这一步不碰 pmaports，绕开所有未知数。

### 步骤

**① 把本工程推到你的 GitHub 仓库**

```bash
cd jason-mainline-ci
git init
git add .
git commit -m "jason mainline bootstrap"
gh repo create jason-mainline-ci --public --source=. --push
# 或者自己建仓库后 git remote add origin ... && git push
```

**② 触发云端构建**

仓库页面 → Actions → **「1 - 构建 jason 主线内核与 boot.img」** → Run workflow

保持默认参数即可：

| 参数 | 默认值 |
|---|---|
| `kernel_branch` | `qcom-sdm660-7.2.y` |
| `kernel_repo` | `https://github.com/sdm660-mainline/linux` |
| `enable_fbcon` | `1`（强制打开显示控制台） |

构建约 30–60 分钟（GitHub 托管 runner 上内核是交叉编译，4 核）。

**③ 下载产物**

构建完成后在 run 的 Artifacts 里下载 `jason-bootimg-qcom-sdm660-7.2.y`，
取出 **`boot.img`**。

**④ 刷入**

```bash
cd jason-mainline-ci

# 检查设备（手机：关机 → 按住音量下 + 电源）
bash scripts/flash-jason.sh check

# 刷入
bash scripts/flash-jason.sh flash /path/to/boot.img
```

**⑤ 观察结果**

| 现象 | 含义 | 下一步 |
|---|---|---|
| 屏幕出现内核日志 + banner | 内核与 DTS 都对上了 | 进 Track 2 |
| 屏幕全黑，但 `telnet 172.16.42.1` 能进去 | 内核起来了，显示驱动有问题 | 查 dmesg 里的 DRM 部分 |
| 完全无反应 | bootloader 不接受这个 boot.img | 进 Track 3（lk2nd） |

关于回滚：**jason 的 `boot` 分区就是 `/dev/block/mmcblk0p62`**，
刷坏了用官方 ROM 里的 `boot.img` 覆盖回去即可：
```bash
bash scripts/flash-jason.sh restore /path/to/stock-boot.img
```

---

## 2. 目录结构

```
jason-mainline-ci/
├── .github/workflows/
│   └── 1-build-bootimg.yml      # Track 1：编内核 + 组装 boot.img（全自动）
├── scripts/
│   ├── build-kernel.sh          # 拉内核 → sdm660_defconfig → Image + dtbs + modules
│   ├── assemble-bootimg.sh      # DTB 拼进内核 → mkbootimg 打包
│   └── flash-jason.sh           # Windows/Git Bash 刷机脚本
├── initramfs/
│   ├── make-initramfs.sh        # 取 Alpine 静态 busybox，打最小 initramfs
│   ├── mkcpio.py                # newc 格式 cpio 后备实现（系统无 cpio 时用）
│   └── init                     # 点亮自检 + USB 网络 + 诊断 shell
├── pmaports/                    # Track 2 用
│   ├── device-xiaomi-jason/     # ← pmaports 里缺的那个设备包
│   │   ├── APKBUILD
│   │   ├── deviceinfo
│   │   └── modules-initfs
│   └── firmware-xiaomi-jason/   # GPU 固件包
│       └── APKBUILD
└── firmware/
    └── README.md                # 固件获取指引（modem/adsp 怎么取）
```

---

## 3. 几个关键设计决定，以及为什么

### 3.1 DTB 必须拼在 kernel 后面

实机分区表（`device-report/partitions.txt`，70 个分区）里 **没有 `dtbo` 分区**。
bootloader 无处可读设备树，所以只能把 dtb 拼在 `Image` 之后：

```bash
cat Image sdm660-xiaomi-jason.dtb > Image-dtb
```

这与 `deviceinfo_append_dtb="true"` 是同一件事。

### 3.2 不需要处理 vbmeta

同一个分区表里 **没有 `vbmeta` 分区**。
对比同 SoC 的 lavender（`deviceinfo_flash_fastboot_partition_vbmeta="vbmeta"`），
jason 不需要这一步 —— bootloader 解锁后校验本来就已经关掉了（`flash.locked=0`）。

### 3.3 强制打开显示控制台

jason 的调试 UART 在主板背面两个测试点（TP707 = TX，TP708 = RX），
没有引出排针。**屏幕是唯一的反馈通道**，所以构建时强制加上：

```
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_FRAMEBUFFER_CONSOLE=y
```

注意 fbcon 需要 **DRM fbdev 模拟**，而很多现代 DRM 驱动默认不启用它 —— 这是
「内核明明起来了但屏幕黑的」最常见原因，所以这里显式打开。

### 3.4 内核按 Android boot image 打包

jason 的 stock `aboot` 只认 Android boot image 格式。
把主线内核按这个格式打包（偏移参数取自同 SoC 的 lavender），`aboot` 就能直接加载，
**不需要先刷 lk2nd**。这是首选链路；lk2nd 是 Track 3 的备用方案。

### 3.5 先不装 WiFi 固件

jason 上 ath10k 会把 modem 连带搞崩，而 modem 目前本来就因缺 IPA 不可用。
首轮点亮把变量降到最少 —— 详见 `firmware/README.md`。

### 3.6 initramfs 自带一个 cpio 后备实现

Linux 的 initramfs 只接受 **newc 格式 cpio**。GNU tar 不支持这个格式
（实测 `tar --format=newc` 直接报 Invalid archive format），而 `cpio` 在某些
环境（比如 Windows/MSYS）根本没装。所以 `initramfs/mkcpio.py` 是一个约 150 行的
纯 Python newc 打包器，没有 `cpio` 时自动顶上。

它有两处是踩过坑才写对的，值得留意：

- **路径名填充要按「110 字节头 + 路径名」整体 4 字节对齐**，只按路径名长度
  对齐会让第二条记录起 magic 错位，整个归档报废。
- **权限位不信任磁盘**。Windows 下 `install -m755` 不会真正设置可执行位，
  实测记录成 `0666`；而 `/init` 不可执行内核会直接 panic。所以
  `_mode_for()` 按用途硬编码：`/init` 与 `bin/` `sbin/` 下的一律 0755。

脚本末尾有硬性自检：产物小于 100 KB 就报错退出 —— 避免静默产出一个刷不亮的空包。

---

## 4. Track 2：构建完整 postmarketOS 系统

搞定了 Track 1 之后，要一个真正能用的系统，就需要设备包。

### 4.1 准备 pmaports

```bash
git clone https://gitlab.postmarketos.org/postmarketOS/pmaports.git
cd pmaports

# 把本工程的设备包放进去
cp -r /path/to/jason-mainline-ci/pmaports/device-xiaomi-jason    device/testing/
cp -r /path/to/jason-mainline-ci/pmaports/firmware-xiaomi-jason  device/testing/

# 生成校验和（firmware 包的 sha512sums 是空的，必须先生成）
cd device/testing/device-xiaomi-jason   && abuild checksum
cd ../firmware-xiaomi-jason             && abuild checksum
```

### 4.2 内核包要指向支持 jason 的源

pmaports 的 `linux-postmarketos-qcom-sdm660` 需要指向带 jason 设备树的源。
如果它默认版本还没有 jason 的 dtb，改用社区分支：

```
# 在 linux-postmarketos-qcom-sdm660/APKBUILD 里改
_source_repo="https://github.com/sdm660-mainline/linux"
_commit="..."     # qcom-sdm660-7.2.y 上的具体提交
```

**验证方法**：改完后跑 `abuild -r`，检查生成的包里有没有
`/boot/dtbs/qcom/sdm660-xiaomi-jason.dtb`。没有就说明源不对。

### 4.3 构建

pmbootstrap 同样跑不了 Windows，所以还是走云端 —— 套用 Track 1 的
GitHub Actions 模式，把 `pmbootstrap init` / `install` 换成脚本化调用：

```bash
pmbootstrap -y zap
pmbootstrap config device xiaomi-jason
pmbootstrap config ui phosh        # 或 plasma-mobile / sxmo
pmbootstrap config kernel mainline # 用主线内核
pmbootstrap -y init
pmbootstrap install --split        # 产出 rootfs 镜像
pmbootstrap flasher export         # 导出 boot.img
```

产物 `boot.img` + `rootfs.img` 下载到本地后：

```bash
fastboot flash boot    boot.img
fastboot flash userdata rootfs.img    # 注意：会清空用户数据
```

---

## 5. Track 3：如果 Track 1 点不亮

`aboot` 直载主线内核失败时，改用社区的标准两级链路：

```
stock aboot  →  lk2nd（作为 boot.img 刷入）  →  U-Boot  →  Linux
```

jason 的 U-Boot 状态（per wiki）：「Secondary Bootloader Works」——
也就是说这条链路是经过验证的。

```bash
# 1. 从 lk2nd 仓库构建（sdm660-mainline/lk2nd）
git clone https://github.com/sdm660-mainline/lk2nd
cd lk2nd && make TOOLCHAIN_PREFIX=aarch64-linux-gnu- lk2nd-msm8953   # 按 README 确认目标

# 2. 刷入
fastboot flash boot lk2nd.img

# 3. lk2nd 会提供自己的 fastboot 界面，再从那里刷真正的 boot.img
fastboot flash boot boot.img
```

---

## 6. 故障排查

| 症状 | 可能原因 | 处理 |
|---|---|---|
| 构建在第 4 步失败，报找不到 dtb | 分支上没有 jason 设备树 | 换 `qcom-sdm660-7.2.y`；`ls arch/arm64/boot/dts/qcom/sdm660-*.dtb` 看有哪些 |
| 构建报磁盘不足 | runner 只有 ~14GB | workflow 已有释放磁盘步骤；仍不够就把 `JOBS` 调小或改用自托管 runner |
| 内核起来但屏幕黑 | DRM fbdev 模拟没开 | 检查产物里 `out/config-checks.txt` 的 `CONFIG_DRM_FBDEV_EMULATION` |
| 屏幕亮了但卡在 initramfs | busybox 解包失败 | 看构建日志中 `make-initramfs.sh` 第 2 步，确认找到了 busybox |
| telnet 连不上 | USB gadget 没建起来 | 屏幕上会打印 `[init] USB 网络就绪：<iface>` 或失败原因 |
| 刷完重启直接进 MIUI | boot.img 没通过 aboot 校验 | 进 Track 3 |
| 完全无反应（黑屏 + 无 USB） | 内核 panic | 设备树里配了 `ramoops`，下次启动后可从 pstore 取日志 |

**关于 ramoops**：`sdm660-xiaomi-jason.dts` 里定义了
`ramoops@b0000000`（4 MiB，含 2 MiB console）。内核崩溃的日志会留在那里，
重启后（甚至重启回 MIUI 后）可以从 `/sys/fs/pstore/` 读出来 ——
这是黑屏无输出时唯一能拿到的证据。

---

## 7. 附录：事实核查结果

本工程的所有参数都来自直接核查，不是推测：

| 结论 | 依据 |
|---|---|
| jason 设备树已就绪 | `sdm660-mainline/linux:qcom-sdm660-7.2.y` → `arch/arm64/boot/dts/qcom/sdm660-xiaomi-jason.dts`（署名 Kernel114514 + minlexx） |
| DTB 输出名 | 同目录 Makefile：`dtb-$(CONFIG_ARCH_QCOM) += sdm660-xiaomi-jason.dtb` |
| 内核配置存在 | `arch/arm64/configs/sdm660_defconfig`（25 KB） |
| 无 dtbo 分区 | 实机 `partitions.txt`（70 项，无 dtbo） |
| 无 vbmeta 分区 | 同上 |
| boot 分区是 mmcblk0p62 | 同上 |
| 屏幕面板 | DTS：`jdi,fhd-r63452` on `mdss_dsi0` |
| 触摸屏 | DTS：Synaptics `syna,rmi4-i2c` @ `blsp_i2c4` 0x20 |
| GPU 固件名 | DTS：`&adreno_gpu_zap { firmware-name = "a512_zap.mbn"; }` |
| GPU 固件已在 vendor 仓库 | `LineageOS-jason/proprietary_vendor_xiaomi_jason` → `proprietary/vendor/firmware/a512_zap.elf` |
| pmaports 无 jason 设备包 | postmarketOS Wiki："cannot be selected in pmbootstrap" |
| IPA 上游无 SDM660 | `torvalds/linux:drivers/net/ipa/ipa_main.c` of_match 表无 sdm660/sdm630 |
| 社区 IPA 工作在进行 | `sdm660-mainline/linux` 分支 `setotau/qcom-sdm660-7.2.y-ipa2-lite`（2026-10-19） |

---

## 8. 关于「最新内核」

社区主线分支现在是 **`qcom-sdm660-7.2.y`**（最后提交 2026-10-22）。
分支序列为 `7.0.y` → `7.1.y` → `7.2.y`，所以 Linux 7.3 出来后跟进方式是：

```bash
git clone https://github.com/sdm660-mainline/linux -b qcom-sdm660-7.2.y
git remote add torvalds https://github.com/torvalds/linux
git fetch torvalds --tags
git rebase torvalds/linux-7.3.y
```

真正有技术含量那部分（SDM660 专属的 clk / regulator / SMMU / GPU 补丁）社区已经维护好了，
rebase 时主要处理少量 API 漂移导致的编译错误。
