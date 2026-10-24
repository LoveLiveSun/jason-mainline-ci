#!/bin/bash
# ---------------------------------------------------------------------------
# jason 刷机脚本（Windows + Git Bash 可直接运行）
#
# 前置条件：
#   1. 手机 bootloader 已解锁（实机已确认：flash.locked=0）
#   2. 已下载 CI 产出的 boot.img
#   3. 手上备有 MIUI 官方 ROM（万一要回滚，见 restore 子命令）
#
# 用法：
#   bash scripts/flash-jason.sh check              # 检查设备与镜像
#   bash scripts/flash-jason.sh backup-boot        # 备份 boot 分区（需 root/TWRP）
#   bash scripts/flash-jason.sh flash out/boot.img # 仅刷内核
#   bash scripts/flash-jason.sh restore stock-boot.img  # 回滚
#   bash scripts/flash-jason.sh reboot
# ---------------------------------------------------------------------------
set -euo pipefail

FASTBOOT="${FASTBOOT:-/c/Users/Administrator/AppData/Local/Android/Sdk/platform-tools/fastboot.exe}"
ADB="${ADB:-/c/Users/Administrator/AppData/Local/Android/Sdk/platform-tools/adb.exe}"

# jason 的 boot 分区（来自 device-report/partitions.txt：boot -> mmcblk0p62）
BOOT_PART="boot"

log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

need_fastboot() {
  [ -x "$FASTBOOT" ] || die "找不到 fastboot：$FASTBOOT
请用 FASTBOOT=/path/to/fastboot.exe 指定路径"
}

fb() { "$FASTBOOT" "$@"; }

# ---------------------------------------------------------------------------
cmd_check() {
  need_fastboot
  log "fastboot 版本"
  fb --version | head -1

  log "当前连接的设备"
  fb devices

  if ! fb devices 2>/dev/null | grep -q .; then
    warn "没有检测到 fastboot 设备。"
    echo ""
    echo "进入 fastboot 的方法："
    echo "  手机关机 → 按住【音量下】+【电源】开机"
    echo "  或者：$ADB reboot bootloader"
    echo ""
    return 1
  fi

  log "分区与解锁状态"
  echo "  unlocked : $(fb getvar unlocked 2>&1 | head -1 | sed 's/.*: //')"
  echo "  slot     : $(fb getvar current-slot 2>&1 | head -1 | sed 's/.*: //' || echo 'N/A')"
  echo "  secure   : $(fb getvar secure 2>&1 | head -1 | sed 's/.*: //')"

  log "jason 关键分区存在性检查"
  # 注意：jason 没有 vbmeta / dtbo 分区，这两项报错属于正常
  for p in boot recovery system userdata modem dsp; do
    out="$(fb getvar partition-size:$p 2>&1 | head -1)"
    if echo "$out" | grep -qi 'not found\|no such\|FAILED'; then
      warn "  $p : 不存在或不可查询"
    else
      echo "  $p : $out"
    fi
  done
}

# ---------------------------------------------------------------------------
cmd_backup_boot() {
  need_fastboot
  mkdir -p backup

  warn "fastboot 无法直读小米分区，备份需要通过 TWRP 完成。"
  echo ""
  echo "两种做法，任选其一："
  echo ""
  echo "  A. 【推荐】直接用官方 ROM 里的 boot.img 作为回滚源："
  echo "     下载 jason 的 MIUI fastboot 包，从 images/ 里取 boot.img"
  echo "     存为 backup/stock-boot.img，回滚时执行："
  echo "       bash scripts/flash-jason.sh restore backup/stock-boot.img"
  echo ""
  echo "  B. 临时引导 TWRP 后 dd 出真实分区内容："
  echo "       fastboot boot twrp-jason.img"
  echo "       # TWRP 里执行："
  echo "       adb shell dd if=/dev/block/mmcblk0p62 of=/sdcard/boot-backup.img"
  echo "       adb pull /sdcard/boot-backup.img backup/boot-backup.img"
  echo ""
}

# ---------------------------------------------------------------------------
cmd_flash() {
  local img="${1:-}"
  [ -n "$img" ] || die "用法：bash scripts/flash-jason.sh flash <boot.img>"
  [ -f "$img" ] || die "找不到镜像文件：$img"

  need_fastboot

  local size
  size="$(stat -c%s "$img")"
  log "待刷镜像：$img（$((size / 1024 / 1024)) MiB）"

  # 合理性检查：boot.img 应该远小于 boot 分区（jason 的 boot 约 64MB）
  if [ "$size" -gt 67108864 ]; then
    warn "镜像超过 64 MiB，jason 的 boot 分区可能装不下，确认这是 boot.img 而不是 rootfs。"
  fi

  if ! fb devices 2>/dev/null | grep -q .; then
    die "未检测到 fastboot 设备。先执行：bash scripts/flash-jason.sh check"
  fi

  log "写入 $BOOT_PART 分区"
  fb flash "$BOOT_PART" "$img"

  echo ""
  warn "已写入。首次启动可能需要 1–2 分钟（内核在初始化硬件）。"
  echo ""
  echo "启动后观察："
  echo "  - 屏幕出现内核日志 / banner  → 内核与 DTS 都对了"
  echo "  - 屏幕全黑但能 telnet 进去   → 内核起来了，显示驱动有问题"
  echo "  - 完全无反应                 → 试 lk2nd 链路，见 README"
  echo ""
  read -r -p "现在重启设备？[y/N] " a
  case "$a" in [yY]*) fb reboot ;; *) echo "跳过。手动重启：bash scripts/flash-jason.sh reboot" ;; esac
}

# ---------------------------------------------------------------------------
cmd_restore() {
  local img="${1:-}"
  [ -n "$img" ] || die "用法：bash scripts/flash-jason.sh restore <stock-boot.img>"
  [ -f "$img" ] || die "找不到镜像文件：$img"

  need_fastboot
  warn "即将用官方 boot.img 覆盖 boot 分区，设备将回到 MIUI。"
  read -r -p "确认？[y/N] " a
  case "$a" in [yY]*) : ;; *) echo "已取消"; return 0 ;; esac

  fb flash "$BOOT_PART" "$img"
  fb reboot
}

# ---------------------------------------------------------------------------
cmd_reboot() {
  need_fastboot
  fb reboot
}

# ---------------------------------------------------------------------------
case "${1:-help}" in
  check)        cmd_check ;;
  backup-boot)  cmd_backup_boot ;;
  flash)        shift; cmd_flash "${1:-}" ;;
  restore)      shift; cmd_restore "${1:-}" ;;
  reboot)       cmd_reboot ;;
  *)
    cat <<'EOF'
jason 刷机脚本

  check                   检查设备连接、解锁状态、关键分区
  backup-boot             获取 boot 分区备份的方法（需 TWRP 或官方 ROM）
  flash <boot.img>        把 boot.img 刷入 boot 分区
  restore <stock-boot.img> 用官方 boot.img 回滚到 MIUI
  reboot                  重启设备

环境变量：
  FASTBOOT   指定 fastboot.exe 路径
  ADB        指定 adb.exe 路径
EOF
    ;;
esac
