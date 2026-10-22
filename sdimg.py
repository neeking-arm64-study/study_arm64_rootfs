#!/usr/bin/env python3
"""SD 镜像构建辅助工具（纯 Python 直写镜像文件，无 root 依赖）

背景：宿主机无免密 sudo、无 mtools，无法 mount/losetup 镜像分区，
因此 FAT32 文件写入和 MBR 分区表均直接按字节坐标改写镜像文件。

子命令：
  fat  FSIMG name=path...   向 FAT32 文件系统镜像（普通文件）写入文件
                            自动生成 8.3 SFN + LFN 目录项与 FAT 簇链
  mbr  IMG type:start:count...   写入 MBR 分区表（type 支持 0x 前缀）
  show IMG PART_START_SECTORS    显示 FAT32 布局与根目录内容（调试用）

FAT32 关键坐标公式（分区起始 LBA=P，扇区 512B）：
  BPB 位于 P*512；FAT 表绝对偏移 (P+reserved)*512
  数据区起始绝对 LBA = P + reserved + nfats*spf，簇 N 绝对 LBA = 该值 + (N-2)*spc
  目录项首簇 = (offset20-21 << 16) | offset26-27
"""

import os
import struct
import sys


def eprint(msg):
    print(msg, file=sys.stderr)


# ---------------------------------------------------------------- FAT32 写入

class Fat32:
    """解析 FAT32 BPB 并支持向根目录写入新文件（要求根目录无同名文件）

    path 可为独立文件系统镜像（base=0）或整盘镜像（base=分区起始字节偏移）。
    """

    EOC = 0x0FFFFFFF
    EOC_MIN = 0x0FFFFFF8  # 链尾标记范围 [EOC_MIN, EOC]

    def __init__(self, path, base=0):
        self.path = path
        self.base = base
        self.f = open(path, "r+b")
        self.f.seek(base)
        bpb = self.f.read(512)
        if bpb[510:512] != b"\x55\xaa":
            raise ValueError("BPB 校验失败（不是 FAT32 引导扇区）")
        self.bps = struct.unpack_from("<H", bpb, 11)[0]
        self.spc = bpb[13]
        self.reserved = struct.unpack_from("<H", bpb, 14)[0]
        self.nfats = bpb[16]
        self.fatsz = struct.unpack_from("<I", bpb, 36)[0]
        self.rootclus = struct.unpack_from("<I", bpb, 44)[0]
        self.csize = self.bps * self.spc
        self.fat_off = base + self.reserved * self.bps
        self.data_off = base + (self.reserved + self.nfats * self.fatsz) * self.bps
        self.f.seek(self.fat_off)
        self.fat = bytearray(self.f.read(self.fatsz * self.bps))

    # -- 簇管理 ------------------------------------------------------------
    def fat_get(self, n):
        return struct.unpack_from("<I", self.fat, n * 4)[0] & 0x0FFFFFFF

    def fat_set(self, n, val):
        struct.pack_into("<I", self.fat, n * 4, val)

    def free_clusters(self):
        n = len(self.fat) // 4
        return [c for c in range(2, n) if self.fat_get(c) == 0]

    def alloc_chain(self, count):
        """顺序分配 count 个空闲簇并链接，返回首簇号"""
        free = self.free_clusters()
        if len(free) < count:
            raise RuntimeError(f"空闲簇不足：需要 {count}，仅剩 {len(free)}")
        got = free[:count]
        for i, c in enumerate(got):
            self.fat_set(c, got[i + 1] if i + 1 < count else self.EOC)
        return got[0]

    def cluster_off(self, c):
        return self.data_off + (c - 2) * self.csize

    # -- 目录项 --------------------------------------------------------------
    @staticmethod
    def sfn_encode(name):
        """8.3 短名（大写、超长时 ~1 截断），返回 11 字节"""
        base, _, ext = name.partition(".")
        bad = set('"*+,/:;<=>?[]|\\ ')
        base = "".join(c for c in base.upper() if c not in bad and c.isascii())
        ext = "".join(c for c in ext.upper() if c not in bad and c.isascii())
        if len(base) > 8 or len(ext) > 3:
            base = base[:6] + "~1"
            ext = ext[:3]
        return base.ljust(8).encode() + ext.ljust(3).encode()

    @staticmethod
    def lfn_checksum(sfn):
        c = 0
        for b in sfn:
            c = (((c & 1) << 7) + (c >> 1) + b) & 0xFF
        return c

    def dir_entries(self, name, size, first_cluster, dos_time, dos_date):
        """生成 name 的全部目录项（LFN 在前、SFN 最后），按磁盘顺序"""
        sfn = self.sfn_encode(name)
        short = sfn[:8].decode().rstrip().lower()
        ext = sfn[8:].decode().rstrip().lower()
        short_name = short + ("." + ext if ext else "")
        ents = []
        if name != short_name:  # 长名（大小写或超 8.3）需 LFN
            cksum = self.lfn_checksum(sfn)
            chars = list(struct.unpack("<%dH" % len(name),
                                       name.encode("utf-16-le")))
            chars.append(0x0000)  # 终止符，其后补 0xFFFF
            nent = (len(chars) + 12) // 13
            while len(chars) < nent * 13:
                chars.append(0xFFFF)
            for seq in range(nent, 0, -1):
                e = bytearray(32)
                e[0] = 0x40 | seq
                e[11] = 0x0F
                e[13] = cksum
                for i, ch in enumerate(chars[(seq - 1) * 13: seq * 13]):
                    if i < 5:
                        struct.pack_into("<H", e, 1 + i * 2, ch)
                    elif i < 11:
                        struct.pack_into("<H", e, 14 + (i - 5) * 2, ch)
                    else:
                        struct.pack_into("<H", e, 28 + (i - 11) * 2, ch)
                ents.append(bytes(e))
        e = bytearray(32)
        e[0:11] = sfn
        e[11] = 0x20  # 归档属性
        struct.pack_into("<H", e, 22, dos_time)
        struct.pack_into("<H", e, 24, dos_date)
        struct.pack_into("<H", e, 26, first_cluster & 0xFFFF)
        struct.pack_into("<H", e, 20, first_cluster >> 16)
        struct.pack_into("<I", e, 28, size)
        ents.append(bytes(e))
        return ents

    def root_dir_bytes(self):
        """按 rootclus 簇链读取整个根目录"""
        out = b""
        c = self.rootclus
        while 2 <= c < self.EOC_MIN:
            self.f.seek(self.cluster_off(c))
            out += self.f.read(self.csize)
            c = self.fat_get(c)
        return out

    def append_root_entries(self, ents):
        """向根目录追加目录项，空间不足时扩展根目录簇链"""
        blob = b"".join(ents)  # 目录项拼接为字节流，统一按 32B 槽位处理
        root = bytearray(self.root_dir_bytes())
        # 从头找连续空闲槽（0x00 从未使用；0xE5 已删除）
        free = 0
        for i in range(0, len(root), 32):
            if root[i] in (0x00, 0xE5):
                free += 32
                if free >= len(blob):
                    break
            else:
                free = 0
        need = len(blob) - free
        if need > 0:
            nclus = (need + self.csize - 1) // self.csize
            c = self.rootclus
            while 2 <= self.fat_get(c) < self.EOC_MIN:  # 找根目录链尾并接链
                c = self.fat_get(c)
            self.fat_set(c, self.alloc_chain(nclus))
            root += b"\x00" * (nclus * self.csize)
        i = pos = 0
        while i < len(blob):
            if root[pos] not in (0x00, 0xE5):
                pos += 32
                continue
            root[pos:pos + 32] = blob[i:i + 32]
            i += 32
            pos += 32
        c = self.rootclus  # 写回根目录簇链
        off = 0
        while 2 <= c < self.EOC_MIN:
            self.f.seek(self.cluster_off(c))
            self.f.write(bytes(root[off:off + self.csize]))
            off += self.csize
            c = self.fat_get(c)

    # -- 对外 ------------------------------------------------------------
    def write_file(self, name, data, dos_time=0x6000, dos_date=0x5D55):
        # dos 默认 2026-10-21 12:00，固定时间保证构建产物确定
        root = self.root_dir_bytes()
        for i in range(0, len(root), 32):
            if root[i] in (0x00, 0xE5):
                break
            if root[i:i + 11] == self.sfn_encode(name):
                raise RuntimeError(f"根目录已存在 {name}，请在全新文件系统上写入")
        first = self.alloc_chain(max(1, (len(data) + self.csize - 1) // self.csize))
        self.f.seek(self.cluster_off(first))
        self.f.write(data + b"\x00" * ((-len(data)) % self.csize))
        self.append_root_entries(self.dir_entries(name, len(data), first,
                                                  dos_time, dos_date))

    def flush_fat(self):
        for i in range(self.nfats):
            self.f.seek(self.fat_off + i * self.fatsz * self.bps)
            self.f.write(self.fat)
        self.f.flush()
        os.fsync(self.f.fileno())

    def summary(self):
        return (f"bps={self.bps} spc={self.spc}(簇{self.csize}B) "
                f"reserved={self.reserved} nfats={self.nfats} spf={self.fatsz} "
                f"rootclus={self.rootclus}")


# ---------------------------------------------------------------- MBR 分区表

def chs(lba):
    """标准 255 头/63 扇区 CHS 编码（超 8GB 截断为 0xFEFFFF）"""
    c, h, s = lba // (255 * 63), (lba // 63) % 255, lba % 63 + 1
    if c > 1023:
        return bytes([0xFE, 0xFF, 0xFF])
    return bytes([h, ((c >> 8) << 6) | s, c & 0xFF])


def cmd_mbr(img, parts):
    mbr = bytearray(512)
    mbr[440:444] = os.urandom(4)
    mbr[510:512] = b"\x55\xaa"
    if len(parts) > 4:
        raise ValueError("最多 4 个主分区")
    for i, spec in enumerate(parts):
        f = spec.split(":")
        ptype, start, count = int(f[0], 16), int(f[1]), int(f[2])
        off = 446 + 16 * i
        mbr[off + 1:off + 4] = chs(start)
        mbr[off + 4] = ptype
        mbr[off + 5:off + 8] = chs(start + count - 1)
        struct.pack_into("<I", mbr, off + 8, start)
        struct.pack_into("<I", mbr, off + 12, count)
        print(f"[mbr] p{i+1}: type=0x{ptype:02X} start={start} "
              f"count={count}({count * 512 >> 20}MiB)")
    with open(img, "r+b") as fp:
        fp.seek(0)
        fp.write(bytes(mbr))
        fp.flush()
        os.fsync(fp.fileno())


# ---------------------------------------------------------------- 查看工具

def cmd_show(img, part_start):
    P = int(part_start) * 512
    fat = Fat32(img, base=P)
    data_lba = int(part_start) + fat.reserved + 2 * fat.fatsz
    print(f"BPB: {fat.summary()}")
    print(f"分区起始 LBA={part_start}  FAT 绝对偏移={fat.fat_off:#x}  "
          f"数据区簇2绝对LBA={data_lba}")
    root = fat.root_dir_bytes()
    i = 0
    while i < len(root) and root[i] != 0:
        e = root[i:i + 32]
        if e[11] == 0x0F:
            print(f"  LFN seq={e[0]:#04x} cksum={e[13]:#04x}")
        else:
            clus = (struct.unpack_from("<H", e, 20)[0] & 0x0FFF) << 16 | \
                   struct.unpack_from("<H", e, 26)[0]
            size = struct.unpack_from("<I", e, 28)[0]
            print(f"  SFN {e[:11].decode()} attr={e[11]:#04x} clus={clus} size={size}")
        i += 32


def cmd_fat(fsimg, specs):
    fat = Fat32(fsimg)
    print(f"[fat] BPB: {fat.summary()}")
    for spec in specs:
        name, _, path = spec.partition("=")
        if not path:
            raise ValueError(f"参数格式应为 name=path：{spec}")
        with open(path, "rb") as fp:
            data = fp.read()
        fat.write_file(name, data)
        print(f"[fat] {name}: {len(data)} 字节写入完成")
    fat.flush_fat()
    print(f"[fat] FAT 已回写（x{fat.nfats}）")


def main():
    if len(sys.argv) < 3:
        eprint(__doc__)
        sys.exit(1)
    cmd, img, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    if cmd == "fat":
        cmd_fat(img, args)
    elif cmd == "mbr":
        cmd_mbr(img, args)
    elif cmd == "show":
        cmd_show(img, args[0] if args else 2048)
    else:
        eprint(f"未知子命令 {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
