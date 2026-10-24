# 固件获取指引

主线设备树 `sdm660-xiaomi-jason.dts` 里显式声明的固件依赖：

```dts
&adreno_gpu_zap   { firmware-name = "a512_zap.mbn"; };
&adsp_pil         { firmware-name = "adsp_c8.mdt"; };
&remoteproc_mss   { firmware-name = "mba.mbn", "modem.mdt"; };
```

另有 WiFi（ath10k WCN3990）需要 `wlanmdsp.mbn` 与 `firmware-5.bin`。

**这些都不是要「反编译」的东西。** 它们是原厂签名的可执行二进制，直接取来用即可。

---

## 一、能直接用现成的（推荐）

### GPU 固件 —— 已由 `firmware-xiaomi-jason` 包提供

`a512_zap.elf` 与 Adreno A5xx 微码（`a530_gpmu.fw2` / `a530_pfp.fw` / `a530_pm4.fw`）
都已包含在 pmaports 的 `firmware-xiaomi-jason` 里，从
[LineageOS-jason/proprietary_vendor_xiaomi_jason](https://github.com/LineageOS-jason/proprietary_vendor_xiaomi_jason)
（分支 `lineage-23.2-4.4`，提交 `5c0b9b1`）获取。**不需要额外操作。**

### Modem / ADSP 固件 —— 手机上本来就有

jason 的分区表里这两个分区还在（实机已确认）：

| 分区 | 设备节点 | 内容 |
|---|---|---|
| `modem` | `/dev/block/mmcblk0p66` | `modem.mdt`、`mba.mbn` |
| `dsp`   | `/dev/block/mmcblk0p58` | `adsp_c8.mdt` |

只要你还打算从 MIUI 刷过来（也就是**不**做 `fastboot erase`），
这两块分区的原厂固件就一直躺在机器里。

设备包依赖的 `msm-firmware-loader` 会在启动时把它们取出来给内核用。
**所以首次点亮验证根本不用手动准备固件。**

---

## 二、需要手动准备的情况

只有满足以下任一条件时才需要手动提取：

- 你曾 `fastboot erase modem` / `erase dsp`，或刷过会覆盖这两区的包
- 你走 Track 2（完整 postmarketOS），rootfs 里要自带一份固件副本
- 你要把这些固件放进 CI 产物里分发

### 2.1 从 MIUI 官方 ROM 提取

**下载**：jason 的 MIUI fastboot 包（`jason_images_*.tgz` 或 `jason_global_images_*.tgz`）。
搜索关键词：`jason fastboot rom MIUI V12.0.1.0.PCHCNXM`。

解包后在 `images/` 与 `firmware-update/` 里找这两个文件：

| ROM 里的文件 | 是什么 | 提取出的固件 |
|---|---|---|
| `NON-HLOS.bin` | modem 固件的磁盘镜像 | `modem.mdt`、`modem.b*`、`mba.mbn` |
| `adspso.bin`   | ADSP 固件的磁盘镜像 | `adsp_c8.mdt`、`adsp_c8.b*` |

这两个 `.bin` 是带文件系统的镜像，不是裸数据。挂载或解包它：

```bash
# 方式 A：Linux 上直接 loop 挂载
mkdir -p mnt-nonhlos
sudo mount -o ro,loop NON-HLOS.bin mnt-nonhlos
ls mnt-nonhlos            # 里面就是 modem.mdt / mba.mbn / *.b01 *.b02 ...

# 方式 B：任何平台上用 7z 解（Windows 也行）
7z x NON-HLOS.bin -oout-nonhlos
7z x adspso.bin   -oout-adspso
```

### 2.2 放到哪里

```bash
# 首次点亮 / 临时用：推到设备的 /lib/firmware/postmarketos/
adb push modem.mdt modem.b01 modem.b02 mba.mbn  /lib/firmware/postmarketos/
adb push adsp_c8.mdt adsp_c8.b01 adsp_c8.b02    /lib/firmware/postmarketos/
```

注意 **`.mdt` 和它的 `.bNN` 分片必须放在同一目录**，`remoteproc` 会把它们拼起来。

对于 Track 2 的 rootfs 集成，做法与 `firmware-xiaomi-lavender` 一致 ——
新建一个 `firmware-xiaomi-jason-modem` 包，把这些文件装到
`/lib/firmware/postmarketos/`。

---

## 三、WiFi 固件是可选项（建议先不要）

jason 上 ath10k 有个已知问题：**加载 WiFi 会把 modem 搞崩**（社区 wiki 原文
"Wi-Fi is crashing modem"），而手动断开 WiFi 又会把连接彻底破坏直到重启。

既然 modem 目前本来就因为缺 IPA 不可用，首轮点亮**建议不装 WiFi 固件**，
先把「内核能起、屏幕能亮、USB 网络能通」这三件事坐实。

需要时再补，做法与 lavender 相同（参考 pmaports 的 `firmware-xiaomi-lavender`）：

```bash
# 需要 qca-swiss-army-knife 提供 ath10k-fwencoder
ath10k-fwencoder --create \
  --features=wowlan,no-nwifi-decap-4addr-padding,allows-mesh-bcast,mgmt-tx-by-ref,non-bmi,single-chan-info-per-channel \
  --set-wmi-op-version=tlv --set-htt-op-version=tlv \
  --set-fw-api=5
# 产物 firmware-5.bin 与 board-2.bin 放到：
#   /lib/firmware/ath10k/WCN3990/hw1.0/
```

`board-2.bin` 是天线/板级校准数据。lavender 的那份可以直接用（同为 WCN3990），
若 WiFi 表现异常再考虑针对 jason 重新调。

---

## 四、一张速查表

| 固件 | 用途 | 来源 | 首轮是否需要 |
|---|---|---|---|
| `a512_zap.mbn` | GPU 解密固件 | `firmware-xiaomi-jason` 包 | ✅ 已打包 |
| `a530_gpmu.fw2` / `a530_pfp.fw` / `a530_pm4.fw` | Adreno A5xx 微码 | 同上 | ✅ 已打包 |
| `adsp_c8.mdt` | 音频 DSP | 手机 `dsp` 分区 / ROM | ⬜ 可选 |
| `modem.mdt` + `mba.mbn` | 调制解调器 | 手机 `modem` 分区 / ROM | ⬜ 可选（IPA 未完成，装了也不能打电话） |
| `firmware-5.bin` + `board-2.bin` | WiFi | ath10k-fwencoder 生成 | ⬜ 建议先不装 |
