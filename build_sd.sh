#!/bin/bash
# build_sd.sh - 一键产出最终双分区 SD 镜像
#
# 依赖查找优先级：
#   1. artifacts/stable/deps/  ← 已归档的外部依赖二进制（换电脑 clone 本仓也能跑）
#   2. ../../raspi3b_kernel/output/ + ../../raspi3b_uboot/...  ← 本地其他仓的 HEAD
#
# 产物：output/sd.img（512MiB）
#   p1: FAT32 63MiB  LBA 2048..131071   Image / dtb / initramfs.cpio(兜底) / boot.scr
#   p2: ext4  448MiB LBA 131072..       skeleton 原样灌入（目标系统根文件系统）
#
# 全程免 root：FAT32 用 sdimg.py 按字节直写，ext4 用 mkfs.ext4 -d 灌目录，
# MBR 分区表用 sdimg.py mbr 写入，无需 mount / losetup / parted。
set -e
cd "$(dirname "$0")"

OUT=output
SD=${OUT}/sd.img
DEPS=stable/deps

P1_START=2048
P1_COUNT=129024            # 63MiB
P2_START=$((P1_START + P1_COUNT))   # 131072
P2_COUNT=917504            # 448MiB，总计 512MiB

# 依赖查找：优先 stable/deps，其次相对路径（其他仓 HEAD）
KOUT=../../raspi3b_kernel/output
KIMAGE=${KOUT}/Image
KDTB=${KOUT}/bcm2837-rpi-3-b.dtb
UBOOT_BIN=${KOUT}/u-boot.bin
MKIMAGE=../../raspi3b_uboot/build-rpi3b-ca53/tools/mkimage

if [ -f ${DEPS}/Image ]; then KIMAGE=${DEPS}/Image; fi
if [ -f ${DEPS}/bcm2837-rpi-3-b.dtb ]; then KDTB=${DEPS}/bcm2837-rpi-3-b.dtb; fi
if [ -f ${DEPS}/u-boot.bin ]; then UBOOT_BIN=${DEPS}/u-boot.bin; fi
if [ -f ${DEPS}/mkimage ]; then MKIMAGE=${DEPS}/mkimage; fi

BOOTSRC=${DEPS}/boot.src

echo "[build] 依赖: Image=${KIMAGE##*/} DTB=${KDTB##*/} u-boot=${UBOOT_BIN##*/} mkimage=${MKIMAGE##*/} boot.src=${BOOTSRC##*/}"

# 0. 依赖校验
for f in ${KIMAGE} ${KDTB} ${MKIMAGE} ${BOOTSRC} skeleton/bin/busybox; do
    [ -e "$f" ] || { echo "ERROR: 缺少 $f"; exit 1; }
done

# 1. 刷新兜底 initramfs.cpio（复用本工程既有脚本，免 root）
./build_rootfs.sh cpio

# 2. 打包 boot.scr（tr 去 CR：boot.src 若带 CRLF 行尾，\r 会并入命令行
#    尾参数，导致 U-Boot 按 "Image\r" 找不到文件，报 Failed to load）
tr -d '\r' < ${BOOTSRC} > ${OUT}/.boot.src.unix
${MKIMAGE} -A arm64 -O linux -T script -C none -d ${OUT}/.boot.src.unix ${OUT}/boot.scr >/dev/null
rm -f ${OUT}/.boot.src.unix
echo "[build] boot.scr 已生成 (from ${BOOTSRC})"

# 3. p1：FAT32 文件系统 + 写入启动文件（sdimg.py 直写）
P1=${OUT}/p1.fat
rm -f ${P1}
truncate -s $((P1_COUNT * 512)) ${P1}
mkfs.fat -F32 ${P1} >/dev/null
python3 sdimg.py fat ${P1} \
    Image=${KIMAGE} \
    bcm2837-rpi-3-b.dtb=${KDTB} \
    initramfs.cpio=${OUT}/initramfs.cpio \
    boot.scr=${OUT}/boot.scr

# 4. p2：ext4 免 root 灌入 skeleton（目标系统根文件系统，一对一映射）
P2=${OUT}/p2.ext4
rm -f ${P2}
truncate -s $((P2_COUNT * 512)) ${P2}
mkfs.ext4 -q -F -d skeleton -L rootfs ${P2} $((P2_COUNT * 512 / 1024))K
echo "[build] p2.ext4 已生成（skeleton 原样灌入）"

# 5. 拼装整盘 + 写 MBR 分区表
rm -f ${SD}
truncate -s $(((P2_START + P2_COUNT) * 512)) ${SD}
dd if=${P1} of=${SD} bs=512 seek=${P1_START} conv=notrunc status=none
dd if=${P2} of=${SD} bs=512 seek=${P2_START} conv=notrunc status=none
python3 sdimg.py mbr ${SD} 0x0C:${P1_START}:${P1_COUNT} 0x83:${P2_START}:${P2_COUNT}

# 6. 清理中间产物，仅保留最终 sd.img
rm -f ${P1} ${P2} ${OUT}/boot.scr
echo "[build] 完成: ${SD} ($(( (P2_START + P2_COUNT) * 512 / 1024 / 1024 ))MiB, p1=FAT32 p2=ext4)"
