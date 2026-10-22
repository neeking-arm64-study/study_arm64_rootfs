#!/bin/bash
# run_qemu.sh - 稳定版机架包启动入口
# 直接引用同目录的 u-boot.bin 和 sd.img（完整可复现快照，自洽）
set -e
cd "$(dirname "$0")"

SD_IMG=${1:-sd.img}
UBOOT=u-boot.bin

[ -f "${UBOOT}" ] || { echo "ERROR: ${UBOOT} 不存在"; exit 1; }
[ -f "${SD_IMG}" ] || { echo "ERROR: ${SD_IMG} 不存在（验证充分后手动 cp output/sd.img 到此）"; exit 1; }

exec qemu-system-aarch64 \
    -M raspi3b \
    -cpu cortex-a53 \
    -m 1G \
    -smp 4 \
    -nographic \
    -serial mon:stdio \
    -kernel ${UBOOT} \
    -drive file=${SD_IMG},format=raw,if=sd
