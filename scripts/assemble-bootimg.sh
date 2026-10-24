#!/bin/bash
# ---------------------------------------------------------------------------
# 组装 Android boot.img（jason 可刷入内核镜像）
#
# 为什么是这种格式：
#   jason 的 stock bootloader (aboot) 只认 Android boot image。
#   把主线内核按这个格式打包，aboot 就能直接加载它 —— 不需要 lk2nd。
#
# 为什么 DTB 要拼在 kernel 后面：
#   jason 分区表里没有 dtbo 分区（见 device-report/partitions.txt），
#   bootloader 无法从别处读设备树，只能靠 append_dtb。
#
# 偏移参数取自 postmarketOS 同 SoC 设备（xdm660 / xiaomi-lavender）的 deviceinfo。
# ---------------------------------------------------------------------------
set -euo pipefail

OUT_DIR="${OUT_DIR:-out}"
CMDLINE="${CMDLINE:-loglevel=7 console=ttyMSM0,115200n8 console=tty0}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

for f in "$OUT_DIR/Image-dtb" "$OUT_DIR/initramfs.cpio.gz"; do
  [ -f "$f" ] || { echo "错误：缺少 $f" >&2; exit 1; }
done

command -v mkbootimg >/dev/null || {
  echo "错误：找不到 mkbootimg。" >&2
  echo "安装方式（任选其一）：" >&2
  echo "  git clone https://android.googlesource.com/platform/system/tools/mkbootimg" >&2
  echo "  pip3 install --user mkbootimg" >&2
  exit 1
}

# ---------------------------------------------------------------------------
log "1/3 压缩内核镜像"
# ---------------------------------------------------------------------------
gzip -9 -c "$OUT_DIR/Image-dtb" > "$OUT_DIR/Image-dtb.gz"
echo "压缩后：$(stat -c%s "$OUT_DIR/Image-dtb.gz") 字节"

log "2/3 调用 mkbootimg"
# ---------------------------------------------------------------------------
mkbootimg \
  --kernel        "$OUT_DIR/Image-dtb.gz" \
  --ramdisk       "$OUT_DIR/initramfs.cpio.gz" \
  --base          0x00000000 \
  --kernel_offset 0x00008000 \
  --ramdisk_offset 0x01000000 \
  --second_offset 0x00f00000 \
  --tags_offset   0x00000100 \
  --pagesize      4096 \
  --header_version 0 \
  --cmdline       "$CMDLINE" \
  --output        "$OUT_DIR/boot.img"

log "3/3 校验 boot.img"
# ---------------------------------------------------------------------------
echo "文件大小：$(stat -c%s "$OUT_DIR/boot.img") 字节"
if command -v unpack_bootimg >/dev/null; then
  unpack_bootimg --boot_img "$OUT_DIR/boot.img" \
    --out "$OUT_DIR/bootimg-verify" --info 2>/dev/null || true
fi

echo ""
echo "cmdline  : $CMDLINE"
echo "产物      : $OUT_DIR/boot.img"
