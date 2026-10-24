#!/usr/bin/env python3
"""
最小 newc 格式 cpio 归档器。

用途：系统缺少 cpio 时的后备方案。Linux 的 initramfs 只接受 newc 格式。

用法：
    mkcpio.py <源目录> <输出文件.cpio>

为什么不用 tar：
    GNU tar 不支持 newc（实测 `tar --format=newc` 报 Invalid archive format），
    bsdtar 在很多环境里也没有。而 Python 到处都有。
"""

import os
import stat
import sys

MAGIC = b"070701"
HDR_LEN = 110
TRAILER = "TRAILER!!!"


def _pad4(n: int) -> bytes:
    """按 4 字节对齐所需的填充字节。"""
    rem = n % 4
    return b"\x00" * (4 - rem) if rem else b""


def _entry(out, name, ino, mode, size, nlink, mtime, rdev, src=None, data=None):
    """写入一条归档记录。

    src  为文件路径时从磁盘读数据体
    data 为 bytes 时直接写入（符号链接的目标走这条路）
    """
    name_b = name.encode("utf-8", "surrogateescape") + b"\x00"
    rdev_major = (rdev >> 8) & 0xFF if rdev else 0
    rdev_minor = rdev & 0xFF if rdev else 0

    fields = [
        ino,
        mode,
        0,               # uid
        0,               # gid
        nlink,
        int(mtime),
        size,            # filesize
        0,               # devmajor
        0,               # devminor
        rdev_major,
        rdev_minor,
        len(name_b),     # namesize
        0,               # check
    ]
    header = MAGIC + b"".join(b"%08X" % (f & 0xFFFFFFFF) for f in fields)
    assert len(header) == HDR_LEN, len(header)

    out.write(header)
    out.write(name_b)
    # newc 规范：路径名的 NUL 填充要保证「110 字节固定头 + 路径名」是 4 的倍数。
    # 只按路径名长度对齐会让第二条记录起 magic 错位（实测踩过）。
    out.write(_pad4(HDR_LEN + len(name_b)))

    if data is not None and size:
        out.write(data)
        out.write(_pad4(size))
    elif src is not None and size:
        with open(src, "rb") as fh:
            while True:
                chunk = fh.read(1 << 20)
                if not chunk:
                    break
                out.write(chunk)
        out.write(_pad4(size))


def _mode_for(rel: str, st) -> tuple:
    """决定归档里记录的模式，不信任磁盘上的权限位。

    原因：Windows/MSYS 下 install -m755 不会真正设置可执行位（实测记录成 0666），
    而 /init 不可执行内核会直接 panic。这里按用途硬编码，保证跨平台一致。
    返回 (mode_含类型位, rdev)。
    """
    if stat.S_ISCHR(st.st_mode) or stat.S_ISBLK(st.st_mode):
        kind = stat.S_IFCHR if stat.S_ISCHR(st.st_mode) else stat.S_IFBLK
        return kind | 0o600, st.st_rdev
    if stat.S_ISLNK(st.st_mode):
        return stat.S_IFLNK | 0o777, 0

    # 需要可执行的：/init 本身，以及 bin/ sbin/ usr/bin/ usr/sbin/ 下的文件
    executable = (
        rel == "init"
        or any(rel.startswith(p) for p in ("bin/", "sbin/", "usr/bin/", "usr/sbin/"))
    )
    return stat.S_IFREG | (0o755 if executable else 0o644), 0


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    root, dest = sys.argv[1], sys.argv[2]
    if not os.path.isdir(root):
        print(f"错误：{root} 不是目录", file=sys.stderr)
        return 1

    # 先收集，保证父目录排在子项之前（内核按顺序解析）
    items = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        items.append((dirpath, True))
        for fn in filenames:
            items.append((os.path.join(dirpath, fn), False))

    ino = 1
    count = 0
    with open(dest, "wb") as out:
        for path, is_dir in items:
            rel = os.path.relpath(path, root)
            rel = "." if rel == "." else rel.replace(os.sep, "/")
            st = os.lstat(path)

            if is_dir:
                _entry(out, rel, ino, stat.S_IFDIR | 0o755, 0, 2, st.st_mtime, 0)
            elif stat.S_ISCHR(st.st_mode) or stat.S_ISBLK(st.st_mode):
                mode, rdev = _mode_for(rel, st)
                _entry(out, rel, ino, mode, 0, 1, st.st_mtime, rdev)
            elif stat.S_ISLNK(st.st_mode):
                target = os.readlink(path).encode("utf-8", "surrogateescape")
                _entry(out, rel, ino, stat.S_IFLNK | 0o777, len(target), 1,
                       st.st_mtime, 0, data=target)
            elif stat.S_ISREG(st.st_mode):
                mode, _ = _mode_for(rel, st)
                _entry(out, rel, ino, mode, st.st_size, 1, st.st_mtime, 0, src=path)
            else:
                continue
            ino += 1
            count += 1

        # 结束记录
        _entry(out, TRAILER, 0, 0, 0, 1, 0, 0)
        # 整个归档补齐到 512 字节边界（顺带保证 4 字节对齐）
        pad = (-out.tell()) % 512
        if pad:
            out.write(b"\x00" * pad)

    print(f"已写入 {count} 个条目 → {dest} ({os.path.getsize(dest)} 字节)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
