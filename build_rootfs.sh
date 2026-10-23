#!/bin/bash
set -e

SKELETON="./skeleton"
OUTPUT="./output"
mkdir -p ${OUTPUT}

# 增加busybox存在性校验
if [ ! -f "${SKELETON}/bin/busybox" ];then
    echo "ERROR: ${SKELETON}/bin/busybox missing，请先拷贝busybox实体文件！"
    exit 1
fi

case "$1" in
cpio)
    echo "打包initramfs cpio（QEMU内核启动用）"
    cd ${SKELETON}
    find . -print0 | cpio --null -ov --format=newc > ../${OUTPUT}/initramfs.cpio
    echo "cpio镜像输出：${OUTPUT}/initramfs.cpio"
    cd -
    ;;
ext4)
    echo "打包ext4镜像（SD卡分区使用）"
    IMG=${OUTPUT}/rootfs.ext4
    SIZE=128M
    rm -f ${IMG}
    dd if=/dev/zero of=${IMG} bs=1M count=128
    mkfs.ext4 ${IMG}
    mkdir -p /tmp/mnt_rootfs
    mount ${IMG} /tmp/mnt_rootfs
    cp -r ${SKELETON}/* /tmp/mnt_rootfs/
    umount /tmp/mnt_rootfs
    echo "ext4镜像输出：${IMG}"
    ;;
*)
    echo "使用方法：$0 cpio | $0 ext4"
    ;;
esac
