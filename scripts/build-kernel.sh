#!/bin/bash
# ---------------------------------------------------------------------------
# jason 主线内核构建脚本
#   内核源：sdm660-mainline/linux  @ qcom-sdm660-7.2.y
#   产物：Image、sdm660-xiaomi-jason.dtb、内核模块
# 可在 GitHub Actions 或任意 x86_64 Linux 上运行。
# ---------------------------------------------------------------------------
set -euo pipefail

KERNEL_REPO="${KERNEL_REPO:-https://github.com/sdm660-mainline/linux}"
KERNEL_BRANCH="${KERNEL_BRANCH:-qcom-sdm660-7.2.y}"
KERNEL_DIR="${KERNEL_DIR:-kernel}"
OUT_DIR="${OUT_DIR:-out}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
log "1/6 获取内核源码（浅克隆，节省时间与磁盘）"
# ---------------------------------------------------------------------------
if [ -d "$KERNEL_DIR/.git" ]; then
  echo "目录已存在，跳过克隆：$KERNEL_DIR"
else
  git clone --depth=1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
fi
cd "$KERNEL_DIR"

echo "分支：$(git rev-parse --abbrev-ref HEAD)"
echo "提交：$(git rev-parse --short HEAD)"
echo "内核版本：$(make kernelversion 2>/dev/null || echo '未知')"
git rev-parse --short HEAD > "../$OUT_DIR/kernel-commit.txt"

# ---------------------------------------------------------------------------
log "2/6 生成内核配置 sdm660_defconfig"
# ---------------------------------------------------------------------------
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" sdm660_defconfig

# 首次点亮验证需要屏幕输出。jason 没有可用的 UART 排针，
# 显示是唯一反馈通道，因此强制打开 DRM fbdev 模拟与控制台。
log "2.1 叠加显示控制台配置（仅用于首次点亮验证）"
if [ "${ENABLE_FBCON:-1}" = "1" ]; then
  # 这些 symbol 必须内建为 =y，不能是 =m。
  #
  # 为什么不能用模块：本工程的 initramfs 里只有一个静态 busybox，
  # 没有 modprobe、也没有任何 .ko 文件，启动时不存在任何东西会去加载模块。
  # 只要 DRM_MSM 是 =m，fbcon 就找不到 framebuffer，屏幕永远全黑。
  #
  # 这不是理论担忧 —— 首轮构建产物的 kernel.config 实测就是：
  #     CONFIG_DRM_MSM=m
  #     CONFIG_DRM_DISPLAY_HELPER=m
  #     CONFIG_DRM_PANEL_JDI_R63452=m
  # 三项全是模块，刷进去必然黑屏。这里逐个改成 =y。
  #
  # 用 sed 原地替换而不是 cat >> .config：追加会在 .config 里留下同一 symbol
  # 的重复定义（原 =m 与新 =y 并存），Kconfig 取哪一个不可靠。
  for sym in \
      DRM DRM_KMS_HELPER DRM_DISPLAY_HELPER DRM_MIPI_DSI \
      DRM_PANEL DRM_PANEL_BRIDGE DRM_PANEL_JDI_R63452 DRM_MSM \
      BACKLIGHT_CLASS_DEVICE BACKLIGHT_QCOM_WLED \
      DRM_FBDEV_EMULATION DRM_FBDEV_EMULATION_DEFAULT_ON \
      FB FB_CORE FRAMEBUFFER_CONSOLE \
      FRAMEBUFFER_CONSOLE_DETECT_PRIMARY FRAMEBUFFER_CONSOLE_ROTATION \
      VT VT_CONSOLE DUMMY_CONSOLE ; do
    if grep -q "^CONFIG_${sym}=" .config; then
      sed -i "s/^CONFIG_${sym}=.*/CONFIG_${sym}=y/" .config
    elif grep -q "^# CONFIG_${sym} is not set" .config; then
      sed -i "s/^# CONFIG_${sym} is not set/CONFIG_${sym}=y/" .config
    else
      echo "CONFIG_${sym}=y" >> .config
    fi
  done

  make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

  # 硬性校验：配置没真正生效就立刻失败。
  # 否则要等 30 分钟编译完、刷进手机、看着黑屏，才知道是配置没改上。
  missing=""
  for sym in DRM_MSM DRM_DISPLAY_HELPER DRM_PANEL_JDI_R63452 \
             DRM_FBDEV_EMULATION FRAMEBUFFER_CONSOLE VT_CONSOLE ; do
    val="$(sed -n "s/^CONFIG_${sym}=//p" .config | tail -n1)"
    [ "$val" = "y" ] || missing="$missing ${sym}(=${val:-unset})"
  done
  if [ -n "$missing" ]; then
    echo "错误：以下配置没能内建，显示链路不完整，刷入后会黑屏：" >&2
    echo "  $missing" >&2
    echo "请检查这些 symbol 在 defconfig 里是否存在、名字是否写对。" >&2
    exit 1
  fi
  echo "显示链路已确认全部内建 (=y)"
fi

# 记录最终配置里关键项的实际取值，便于排查
{
  echo "--- 最终配置关键项 ---"
  grep -E '^CONFIG_(DRM_MSM|DRM_DISPLAY_HELPER|DRM_PANEL_JDI_R63452|DRM_FBDEV_EMULATION|FRAMEBUFFER_CONSOLE|VT_CONSOLE|FB|ARM_QCOM|QCOM_SMD_RPM|PINCTRL_SDM660|CLK_SDM660|QCOM_IPA|QCOM_Q6V5_MSS|QCOM_Q6V5_PAS|USB_GADGET|USB_CONFIGFS|USB_F_RNDIS)=' .config || true
} | tee "../$OUT_DIR/config-checks.txt"

# ---------------------------------------------------------------------------
log "3/6 编译内核镜像 Image"
# ---------------------------------------------------------------------------
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" Image

# ---------------------------------------------------------------------------
log "4/6 编译设备树（sdm660-xiaomi-jason.dtb）"
# ---------------------------------------------------------------------------
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" dtbs

DTB="arch/arm64/boot/dts/qcom/sdm660-xiaomi-jason.dtb"
if [ ! -f "$DTB" ]; then
  echo "错误：未找到 $DTB" >&2
  echo "该分支可用的 sdm660 设备树如下：" >&2
  ls -1 arch/arm64/boot/dts/qcom/sdm660-*.dtb 2>/dev/null >&2 || true
  exit 1
fi
echo "设备树已生成：$DTB ($(stat -c%s "$DTB") 字节)"

# ---------------------------------------------------------------------------
log "5/6 编译内核模块"
# ---------------------------------------------------------------------------
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" modules

# ---------------------------------------------------------------------------
log "6/6 收集产物到 $OUT_DIR"
# ---------------------------------------------------------------------------
cd ..

cp "$KERNEL_DIR/arch/arm64/boot/Image"                        "$OUT_DIR/Image"
cp "$KERNEL_DIR/$DTB"                                         "$OUT_DIR/sdm660-xiaomi-jason.dtb"
cp "$KERNEL_DIR/.config"                                      "$OUT_DIR/kernel.config"

# 模块连同其目录结构打包（modprobe 需要路径）
if [ -n "${KERNEL_DIR:-}" ]; then
  ( cd "$KERNEL_DIR" && \
    find . -name '*.ko' -print0 | tar --null -T - -czf "../$OUT_DIR/modules.tar.gz" )
  echo "模块数量：$(tar -tzf "$OUT_DIR/modules.tar.gz" | grep -c '\.ko$' || echo 0)"
fi

# ---------------------------------------------------------------------------
# DTB 附加到内核镜像
#   jason 没有 dtbo 分区，bootloader 也无法单独读取 dtb，
#   因此必须把 dtb 拼接在 Image 之后（与 deviceinfo_append_dtb="true" 一致）。
# ---------------------------------------------------------------------------
log "附加 DTB 到内核镜像（jason 无 dtbo 分区）"
cat "$OUT_DIR/Image" "$OUT_DIR/sdm660-xiaomi-jason.dtb" > "$OUT_DIR/Image-dtb"
echo "Image        : $(stat -c%s "$OUT_DIR/Image") 字节"
echo "Image-dtb    : $(stat -c%s "$OUT_DIR/Image-dtb") 字节"

log "构建完成"
ls -lh "$OUT_DIR"
