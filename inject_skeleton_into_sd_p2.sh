#!/bin/bash
# inject_skeleton_into_sd_p2.sh - 免 root 向现有 sd.img 的 p2 ext4 注入文件
# 用途：日常 ko/app 迭代秒级验证，无需重跑 build_sd.sh
# 用法:
#   inject_skeleton_into_sd_p2.sh sd.img <file> [目标路径在 ext4 根下]
#   inject_skeleton_into_sd_p2.sh output/sd.img path/to/file.ext lib/modules/myko.ko
#   inject_skeleton_into_sd_p2.sh output/sd.img /tmp/hello usr/local/bin/hello
set -e

SD=$1; SRC=$2; DST=${3:-$(basename "$SRC")}
[ -f "${SD}" ] || { echo "ERROR: ${SD} 不存在"; exit 1; }
[ -f "${SRC}" ] || { echo "ERROR: ${SRC} 不存在"; exit 1; }

# 从 MBR 解析 p2 起始扇区和大小（跳过 p1=0x0C，取第二个分区 entry=16:32）
P2_START=$(python3 -c "
import struct
d=open('${SD}','rb').read(512)
pt=d[446:]
e=pt[16:32]
print(struct.unpack_from('<I', e, 8)[0])
")
P2_COUNT=$(python3 -c "
import struct
d=open('${SD}','rb').read(512)
pt=d[446:]
e=pt[16:32]
print(struct.unpack_from('<I', e, 12)[0])
")

TMP=$(mktemp /tmp/p2.XXXXXX)
dd if=${SD} of=${TMP} bs=512 skip=${P2_START} count=${P2_COUNT} status=none
debugfs -w -R "write ${SRC} ${DST}" ${TMP}
dd if=${TMP} of=${SD} bs=512 seek=${P2_START} count=${P2_COUNT} conv=notrunc status=none
rm -f ${TMP}
echo "[inject] ${SRC} -> ${SD}:p2/${DST}"
