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
  cat >> .config <<'EOF'

# --- jason first-light: 显示控制台 ---
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_DRM_FBDEV_EMULATION_DEFAULT_ON=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y
CONFIG_FRAMEBUFFER_CONSOLE_ROTATION=y
CONFIG_VT=y
CONFIG_VT_CONSOLE=y
CONFIG_DUMMY_CONSOLE=y
EOF
  make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
fi

# 记录最终配置里关键项的实际取值，便于排查
{
  echo "--- 最终配置关键项 ---"
  grep -E '^CONFIG_(DRM_FBDEV_EMULATION|FRAMEBUFFER_CONSOLE|VT_CONSOLE|ARM_QCOM|QCOM_SMD_RPM|PINCTRL_SDM660|CLK_SDM660|DRM_MSM|QCOM_IPA|QCOM_Q6V5_MSS|QCOM_Q6V5_PAS)=' .config || true
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
