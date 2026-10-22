# raspi3b ca53 rootfs 工程（最终预览模板 + 稳定版本机架包）

本仓 = raspi3b aarch64 QEMU 启动时挂载的 **rootfs 文件系统快照** + 稳定版本机架包。
clone 本仓即可产出可启动 sd.img（stable/deps/ 自带所有外部依赖二进制和 boot.src）。

## 快速启动（clone 本仓后三步）

```bash
# 1. 构建最新可启动镜像
./build_sd.sh

# 2. QEMU 启动（跑 output/sd.img，快速验证）
./stable/release/run_qemu.sh ../output/sd.img

# 3. 日常秒级迭代（改 ko / app → 注入现有 sd.img p2，不用重出整盘）
./inject_skeleton_into_sd_p2.sh output/sd.img path/to/file.ext lib/modules/myko.ko
```

验证充分后，把 `output/sd.img` 手动拷到 `stable/release/sd.img`，
更新 `stable/release/manifest.txt` 记录新的源码仓 HEAD hash，就成了新的稳定版机架包。

## 目录结构

```
rootfs_test_dir/raspi3b_rootfs/
├── stable/
│   ├── deps/                      build_sd.sh 的输入依赖（全部归档，clone 即跑）
│   │   ├── Image                      kernel 构建产物
│   │   ├── bcm2837-rpi-3-b.dtb      kernel 构建产物
│   │   ├── u-boot.bin               U-Boot 构建产物（build_sd.sh 引用的 u-boot）
│   │   ├── mkimage                  U-Boot 打包工具
│   │   └── boot.src                 U-Boot 启动脚本源（也归档，build_sd.sh 唯一来源）
│   └── release/                   完整稳定版机架包（自洽，clone 即启稳定版）
│       ├── run_qemu.sh              启动脚本（cd 到同目录后引用 u-boot.bin + sd.img）
│       ├── u-boot.bin               运行时 U-Boot（与 deps/ 中版本相同但职责不同）
│       ├── sd.img                   稳定版固件（验证充分后手动 cp output/sd.img 至此）
│       └── manifest.txt             known-good: 三仓 HEAD hash
├── inject_skeleton_into_sd_p2.sh  debugfs 免 root 向 sd.img p2 注入文件（日常迭代秒级）
├── skeleton/                    预览模板本体：目标系统根文件系统的完整布局
│   ├── bin/ etc/ lib/ sbin/ usr/ ...   所有启动必需的东西都手动放这里
│   └── lib/modules/                   ko 编译产物手动放入
├── output/sd.img                build_sd.sh 一键产出（.gitignore，验证充分后 cp stable/release/）
├── build_sd.sh                  组装 sd.img（只读 skeleton + stable/deps/，不往里写任何东西）
├── sdimg.py                     FAT32 / MBR 直写工具（纯 Python，免 root）
└── build_raspi3b_rootfs.sh      cpio 打包（被 build_sd.sh 调用，ext4 分支已废弃）
```

## deps/ vs release/ 的区别

两者都有 u-boot.bin，职责不同：

| | deps/ | release/ |
|---|---|---|
| 谁用 | build_sd.sh | release/run_qemu.sh |
| 包含 | Image, dtb, mkimage, boot.src, u-boot.bin | run_qemu.sh, u-boot.bin, sd.img, manifest.txt |
| 变化频率 | kernel/uboot/boot.src 改了才更新 | 验证充分后才更新（稳定版） |
| 自洽性 | 给 build_sd.sh 打包流程用 | 给 run_qemu.sh 启动用（clone 后直接启） |

## sd.img 布局与 skeleton 映射

```
output/sd.img (512MiB)
├── p1 FAT32 63MiB (LBA 2048..131071)     ← 启动分区，非 skeleton 映射
│   ├── Image                              ← stable/deps/Image
│   ├── bcm2837-rpi-3-b.dtb                ← stable/deps/bcm2837-rpi-3-b.dtb
│   ├── initramfs.cpio                     ← 兜底内存盘（cpio 流程用）
│   └── boot.scr                           ← deps/boot.src 经 mkimage 打包
└── p2 ext4 448MiB (LBA 131072..)         ← 目标系统根文件系统
    ├── bin/ etc/ lib/ usr/ ...            ← skeleton/ 原样灌入，一对一映射
    └── lib/modules/myko.ko                ← skeleton/lib/modules/myko.ko
```

**skeleton 只映射到 p2 ext4**（目标系统根文件系统），p1 FAT32 里的启动文件由
build_sd.sh 从 stable/deps/ 拷贝。build_sd.sh 只读 skeleton，**不往里写任何东西**——
你手动放什么、放什么位置，最终 rootfs 就是什么布局（自由摆放）。

## 依赖查找优先级（build_sd.sh）

1. `stable/deps/`  ← 已归档的二进制和 boot.src（clone 本仓即可跑）
2. `../../raspi3b_kernel/output/` + `../../raspi3b_uboot/...` ← 本地其他仓的 HEAD

boot.src 只有 stable/deps/boot.src 一个来源，日常编辑直接改这个文件。

## 日常操作

| 场景 | 怎么做 | 触不触发 build_sd.sh |
|---|---|---|
| 改 skeleton 配置 | 直接改 skeleton/etc/... | **是**（必须重出整盘） |
| 改 boot.src | 直接改 stable/deps/boot.src | **是** |
| 改 ko 源码 | kernel 仓 make → 拷 .ko 到 skeleton/lib/modules/ | 可选；日常 inject 秒级跳过 |
| 改用户态程序源码 | apps 仓 make → 拷二进制到 skeleton/ | 可选；日常 inject 秒级跳过 |
| kernel 版本变了 | kernel 重编 → ko 重编 → 拷产物到 skeleton + stable/deps/ | **是** |
| 长期版本归档 | 验证充分后 cp output/sd.img → stable/release/sd.img，更新 manifest.txt → commit | - |

## inject_skeleton_into_sd_p2.sh 用法

免 root 向现有 sd.img 的 **p2 ext4** 注入单个文件，秒级：

```bash
./inject_skeleton_into_sd_p2.sh output/sd.img path/to/file.ext lib/modules/myko.ko
./inject_skeleton_into_sd_p2.sh output/sd.img /tmp/hello usr/local/bin/hello
```

针对 p2 的原因：日常迭代改的都是 rootfs 里的东西（配置、ko、用户态程序），
都是 p2 的内容。p1 FAT32 只有 kernel 换版本才变，那种情况直接重编 kernel →
拷 stable/deps/ → 重跑 build_sd.sh，不走 inject。

内部流程：从 MBR 解析 p2 起始扇区 → dd 提取 p2 → debugfs -w write → dd 写回。
不影响 p1 FAT32 启动分区。

## build_sd.sh 用法

```bash
./build_sd.sh
```

## release/sd.img 归档流程

验证充分后：
```bash
cp output/sd.img stable/release/sd.img
# 更新 stable/release/manifest.txt 记录新的源码仓 HEAD hash
git add -A && git commit -m "归档稳定版机架包: sd.img + manifest"
```
stable/release/ 就成了完整可复现快照——clone 本仓后直接跑
`./stable/release/run_qemu.sh` 启稳定版。

## 跨仓协作

skeleton 里的 ko / 用户态程序产物**手动从其他仓拷进来**（不写自动 sync 脚本，
版本稳定性靠手动确认 commit 入仓保证）。对应源码仓：

| 产物 | 源码仓 | 编译 | 拷到 |
|---|---|---|---|
| .ko | raspi3b_kernel/ko/ | `make KDIR=../../raspi3b_kernel modules` | skeleton/lib/modules/ |
| 用户态程序 | raspi3b_apps/（按需建） | `aarch64-linux-gnu-gcc` | skeleton/ 你指定的任意位置 |
| kernel Image/dtb | raspi3b_kernel/ | `make` | stable/deps/（build_sd.sh 直接引用） |
| u-boot.bin | raspi3b_uboot/ | `make` | stable/deps/（build_sd.sh 引用） + stable/release/（run_qemu.sh 引用） |
| mkimage | raspi3b_uboot/ | `make tools` | stable/deps/ |
| boot.src | 本仓 stable/deps/ | 纯文本，直接编辑 | stable/deps/（build_sd.sh 唯一来源） |
