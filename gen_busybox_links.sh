#!/bin/bash
set -e

SKELETON="./skeleton"
BIN_DIR="${SKELETON}/bin"
BUSYBOX="${BIN_DIR}/busybox"

if [ ! -f "${BUSYBOX}" ]; then
  echo "ERROR: ${BUSYBOX} 不存在，请先拷贝busybox实体!"
  exit 1
fi

chmod +x "${BUSYBOX}"
echo "开始生成busybox命令软链接..."

cd "${BIN_DIR}" || { echo "ERROR: 无法进入 ${BIN_DIR}"; exit 1; }

# 1. 清理旧链接
rm -f init
./busybox --list | xargs rm -f

# 2. 遍历busybox命令，手动创建相对链接，全部生成在当前 skeleton/bin 目录
./busybox --list | while read cmd; do
    ln -sf busybox "${cmd}"
done

# 3. 单独处理init
ln -sf busybox init

cd - >/dev/null
echo "软链接生成完成。后续打包直接执行build脚本即可。"
