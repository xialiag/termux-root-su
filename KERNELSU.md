# KernelSU 支持（KernelSU patch）

上游 v3.10 是 Magisk 模块：`service.sh` 会查找 `MAGISKTMP`，找不到就 `exit 1`。
KernelSU 没有 Magisk 的 tmpfs，因此在 KernelSU 上模块脚本会直接退出，`su` 不会部署。

本补丁只改两处（见 `patches/termux-root-su-kernelsu.patch`）：

1. `MAGISKTMP` 探测失败时回退到 `/data/adb/ksu`，而不是退出——proxy 自己 fork
   root shell，本来就不依赖 magiskd；
2. 没有 `$MAGISKTMP/.magisk` 时跳过 15 秒的 magiskd socket 等待。

其余逻辑（abstract socket `@termux-root-su`、SO_PEERCRED 鉴权、musl 静态 `su`、
watchdog、proot rootfs 部署）与上游一致，Magisk 下行为不变。

## 安装

已经打包好：`dist/termux-root-su-v3.10-kernelsu.zip`

```bash
# KernelSU
/data/adb/ksu/bin/ksud module install termux-root-su-v3.10-kernelsu.zip

# 立即生效（不必重启）
sh /data/adb/modules_update/termux-root-su/service.sh
```

重启后模块会从 `modules_update` 合并到 `modules`；KernelSU 会执行模块
`service.sh`，也可以用 `/data/adb/service.d/` 兜底。

## 验证

```bash
proot-distro login ubuntu -- su -c id
# uid=0(root) ... context=u:r:ksu:s0
```

## 说明

- 抽象 socket 不会被 proot 的路径翻译劫持，因此容器内可直接连到 root daemon。
- 任何 Termux uid（10009）进程都能通过该 socket 获得 root——这是模块的设计，
  请仅在可信设备上使用。
- 已在 KernelSU 3.3.1 + Android 15（vivo X80 / PD2183）验证。
