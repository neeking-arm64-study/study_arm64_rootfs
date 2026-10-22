#!/bin/bash
set -e
OUTPUT="./output"
TYPE="$1"

case "${TYPE}" in
cpio)
    CPIO_FILE="${OUTPUT}/initramfs.cpio"
    echo "校验 [cpio] : ${CPIO_FILE}"
    [ -f "${CPIO_FILE}" ] || { echo "[FAIL] cpio 文件不存在"; exit 1; }

    cpio_list() {
        cpio -it < "${CPIO_FILE}"
    }

    cpio_list | grep -q "^bin/busybox" && echo "[OK] bin/busybox" || { echo "[FAIL] bin/busybox missing"; exit 1; }
    cpio_list | grep -q "^bin/sh"       && echo "[OK] bin/sh"       || echo "[WARN] bin/sh missing"
    cpio_list | grep -q "^init"         && echo "[OK] /init"         || echo "[WARN] /init missing"
    ;;
ext4)
    EXT4_IMG="${OUTPUT}/rootfs.ext4"
    echo "校验 [ext4] : ${EXT4_IMG}"
    [ -f "${EXT4_IMG}" ] || { echo "[FAIL] ext4 文件不存在"; exit 1; }

    TMP_MNT="/tmp/mnt_rootfs_verify"
    mkdir -p "${TMP_MNT}"
    trap 'umount "${TMP_MNT}" 2>/dev/null; rmdir "${TMP_MNT}" 2>/dev/null' EXIT
    mount "${EXT4_IMG}" "${TMP_MNT}"

    [ -f "${TMP_MNT}/bin/busybox" ] && echo "[OK] bin/busybox" || { echo "[FAIL] bin/busybox missing"; exit 1; }
    [ -e "${TMP_MNT}/bin/sh" ]      && echo "[OK] bin/sh"       || echo "[WARN] bin/sh missing"
    [ -e "${TMP_MNT}/init" ]         && echo "[OK] /init"         || echo "[WARN] /init missing"

    umount "${TMP_MNT}"
    rmdir "${TMP_MNT}"
    trap - EXIT
    ;;
*)
    echo "用法: $0 cpio | ext4"
    exit 1
;;
esac

echo -e "\n✅ 镜像校验完成"
