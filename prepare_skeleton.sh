#!/bin/bash
set -e

SKELETON="./skeleton"

# 创建rootfs基础目录
mkdir -p ${SKELETON}/{bin,sbin,usr/bin,usr/sbin,proc,sys,tmp,dev,lib,etc/init.d}

# inittab
cat > ${SKELETON}/etc/inittab <<EOF
::sysinit:/etc/init.d/rcS
::askfirst:-/bin/sh
EOF

# rcS 启动脚本，挂载文件系统 + mdev
cat > ${SKELETON}/etc/init.d/rcS <<EOF
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t tmpfs none /tmp

echo /sbin/mdev > /proc/sys/kernel/hotplug
mdev -s

echo "==== Rootfs mount success ===="
EOF

chmod +x ${SKELETON}/etc/init.d/rcS

echo "skeleton目录和基础配置文件创建完成"
echo "下一步：复制静态aarch64 busybox到 ${SKELETON}/bin/"
