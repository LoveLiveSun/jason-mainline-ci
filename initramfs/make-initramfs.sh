#!/bin/bash
# ---------------------------------------------------------------------------
# 生成最小 bootstrap initramfs（用于首次点亮验证）
#   - 取 Alpine 官方 aarch64 静态 busybox
#   - 打包成 initramfs.cpio.gz
# 首次点亮的目标：确认内核能起来、屏幕有输出、USB 网络可用。
# ---------------------------------------------------------------------------
set -euo pipefail

ALPINE_BRANCH="${ALPINE_BRANCH:-v3.21}"
ALPINE_ARCH="${ALPINE_ARCH:-aarch64}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"

WORK="${WORK:-initramfs-work}"
OUT_DIR="${OUT_DIR:-out}"

# 统一转成绝对路径，避免子 shell 里 cd 之后相对路径失效
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
WORK_ABS="$(pwd)/$WORK"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

rm -rf "$WORK"
mkdir -p "$WORK/rootfs" "$WORK/dl"

# ---------------------------------------------------------------------------
log "1/5 解析 Alpine busybox-static 版本号"
# ---------------------------------------------------------------------------
INDEX="${ALPINE_MIRROR}/${ALPINE_BRANCH}/main/${ALPINE_ARCH}"
curl -fsSL "${INDEX}/APKINDEX.tar.gz" -o "$WORK/dl/APKINDEX.tar.gz"
tar -xzf "$WORK/dl/APKINDEX.tar.gz" -C "$WORK/dl" APKINDEX

VER="$(awk '
  /^P:busybox-static$/ { found = 1; next }
  found && /^V:/       { sub(/^V:/, ""); print; exit }
' "$WORK/dl/APKINDEX")"

if [ -z "$VER" ]; then
  echo "错误：无法解析 busybox-static 版本号" >&2
  exit 1
fi
echo "busybox-static 版本：$VER"

APK="busybox-static-${VER}.apk"
log "2/5 下载并解包 $APK"
curl -fsSL "${INDEX}/${APK}" -o "$WORK/dl/$APK"

# apk 由两个 gzip 流拼接而成（签名 + 数据）。用 gzip -dc 交给 tar 依序解析。
mkdir -p "$WORK/pkg"
gzip -dc "$WORK/dl/$APK" 2>/dev/null | tar -x -C "$WORK/pkg" 2>/dev/null || true

BUSYBOX=""
for cand in "$WORK/pkg/bin/busybox.static" "$WORK/pkg/usr/bin/busybox.static" \
            "$WORK/pkg/bin/busybox" "$WORK/pkg/usr/bin/busybox"; do
  if [ -f "$cand" ]; then BUSYBOX="$cand"; break; fi
done
if [ -z "$BUSYBOX" ]; then
  echo "错误：解包后未找到 busybox 可执行文件。包内容如下：" >&2
  find "$WORK/pkg" -maxdepth 3 -type f | head -40 >&2
  exit 1
fi
echo "找到 busybox：$BUSYBOX ($(stat -c%s "$BUSYBOX") 字节)"

# ---------------------------------------------------------------------------
log "3/5 组装 initramfs 目录树"
# ---------------------------------------------------------------------------
R="$WORK/rootfs"
mkdir -p "$R"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,tmp,run,etc,mnt}
mkdir -p "$R"/lib/firmware/qcom "$R"/lib/firmware/postmarketos "$R"/lib/firmware/ath10k/WCN3990/hw1.0
mkdir -p "$R"/lib/modules

install -Dm755 "$BUSYBOX" "$R/bin/busybox"

# ---------------------------------------------------------------------------
log "4/5 安装 init 与设备节点"
# ---------------------------------------------------------------------------
install -Dm755 "$(dirname "$0")/init" "$R/init"

# 静态设备节点。
# 只在 Linux 上创建 —— 其他平台（MSYS/Cygwin）的 mknod 会产出假的 *.lnk
# 常规文件，事后清理既麻烦又容易踩到宿主的安全策略。
# 非 Linux 环境直接跳过，启动时由 devtmpfs 提供。
if [ "$(uname -s)" = "Linux" ]; then
  mknod -m 622 "$R/dev/console" c 5 1 2>/dev/null || true
  mknod -m 666 "$R/dev/null"    c 1 3 2>/dev/null || true
  mknod -m 666 "$R/dev/tty"     c 5 0 2>/dev/null || true
  mknod -m 666 "$R/dev/tty0"    c 4 0 2>/dev/null || true

  for d in console null tty tty0; do
    if [ -c "$R/dev/$d" ]; then
      echo "  设备节点 /dev/$d 已创建"
    else
      echo "  提示：/dev/$d 未能创建为字符设备，将由 devtmpfs 提供"
    fi
  done
else
  echo "  当前平台为 $(uname -s)，不预置设备节点（启动时由 devtmpfs 提供）"
fi

cat > "$R/etc/os-release" <<'EOF'
NAME="jason-bootstrap"
ID=jason-bootstrap
PRETTY_NAME="jason mainline bootstrap initramfs"
VERSION_ID=1
EOF

# ---------------------------------------------------------------------------
log "5/5 打包 initramfs.cpio.gz"
# ---------------------------------------------------------------------------
# 内核 initramfs 只接受 newc 格式 cpio。
# 优先用系统 cpio；没有就退到自带的 Python 实现（GNU tar 不支持 newc）。
if command -v cpio >/dev/null; then
  echo "打包器：系统 cpio"
  ( cd "$R" && find . -print0 \
      | cpio --null --create --format=newc --owner=0:0 2>/dev/null \
      > "$WORK_ABS/initramfs.cpio" )
else
  echo "打包器：内置 Python 实现（系统无 cpio）"
  command -v python3 >/dev/null || {
    echo "错误：既没有 cpio 也没有 python3，无法打包 initramfs。" >&2
    echo "  Debian/Ubuntu: sudo apt-get install -y cpio" >&2
    exit 1
  }
  python3 "$(dirname "$0")/mkcpio.py" "$R" "$WORK_ABS/initramfs.cpio"
fi

gzip -9 -c "$WORK_ABS/initramfs.cpio" > "$OUT_DIR/initramfs.cpio.gz"

SIZE="$(stat -c%s "$OUT_DIR/initramfs.cpio.gz")"
echo "initramfs 大小：$SIZE 字节（未压缩 $(stat -c%s "$WORK_ABS/initramfs.cpio") 字节）"

# 合理性检查：静态 busybox 解压后就有 1 MB 以上，压缩后不该这么小。
# 空包或截断的包会在这里被拦下，而不是等到刷机之后才发现。
if [ "$SIZE" -lt 100000 ]; then
  echo "错误：initramfs 只有 $SIZE 字节，明显不完整。" >&2
  ls -la "$R/bin/busybox" "$R/init" >&2 || true
  exit 1
fi

log "完成"
