# Termux Root SU

**在 Termux proot 容器内获取 Magisk 真 root 权限。**

一个 Magisk 模块，通过 root 代理 + symlink 修复的架构，让 proot 容器内的 `su` 命令绕过 magiskd 的 `check-client` 门禁，直接以 uid=0 执行 shell。

## 效果

```
~ $ su -c id
uid=0(root) gid=0(root) groups=0(root) context=u:r:magisk:s0
```

## 前提条件

- Android 设备已 root（Magisk 20.4+）
- 已安装 Termux
- 已通过 `proot-distro` 安装至少一个 Linux 发行版（如 Ubuntu/Debian/Alpine）

## 安装

### 方法一：Magisk 管理器刷入（推荐）

1. 从 [Releases](https://github.com/xialiag/termux-root-su/releases) 下载最新 `termux-root-su-vX.X.zip`
2. 打开 Magisk 管理器 → 模块 → 从本地安装
3. 选择下载的 zip 文件
4. 重启设备
5. 进入 proot 容器，运行 `su -c id` 验证

### 方法二：Termux 命令行安装

```bash
# 需要 Termux 有 root 权限（tsu 或 su）
su -c 'magisk --install-module /sdcard/Download/termux-root-su-vX.X.zip'
# 重启
su -c reboot
```

### 从源码构建

```bash
git clone https://github.com/xialiag/termux-root-su.git
cd termux-root-su

# 使用 Android NDK 交叉编译器
make CC=aarch64-linux-android-gcc

# 或使用 GNU 工具链
make CC=aarch64-linux-gnu-gcc

# 打包 zip（--build 从源码编译，不加则用 prebuilt 二进制）
./build.sh v2.5 --build
```

## 使用方法

### 基本用法

```bash
# 进入 proot 容器
proot-distro login ubuntu

# 获取 root shell
su

# 以 root 执行单条命令
su -c 'apt update'

# 确认身份
su -c id
# uid=0(root) gid=0(root) groups=0(root) context=u:r:magisk:s0
```

### 典型场景

```bash
# 在 proot 中安装需要 root 权限的软件
su -c 'apt install -y nginx'

# 修改系统级配置
su -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'

# 挂载文件系统
su -c 'mount -t tmpfs tmpfs /mnt'

# 运行需要 root 的服务
su -c 'service ssh start'
```

## 架构与原理

### 问题：为什么 proot 容器内无法使用 su？

Magisk 的 `su` 二进制连接 magiskd daemon 时，daemon 会执行 **`check-client` 门禁检查**：

1. 读取连接进程的 `SO_PEERCRED`（uid、pid）
2. 通过 `readlink(/proc/<pid>/exe)` 获取进程的可执行文件
3. 比较该文件的 `st_dev + st_ino` 是否与 magisk 二进制相同

**只有匹配才放行。** proot 容器内的进程，其 `/proc/<pid>/exe` 指向 proot 的 loader（`/data/data/com.termux/.../bin/proot`），永远无法通过此检查。

此外，proot 会劫持容器 rootfs 中的 unix socket 文件：它将 socket 替换为 host 侧的临时文件（`proot-<pid>-XXXXXX`），导致 `connect()` 失败。

### 解决方案：代理 + symlink 两层架构

```
┌──────────────────────────────────────────────────────────┐
│                    Host (Android)                         │
│                                                          │
│  ┌─────────────┐     ┌──────────────┐     ┌───────────┐ │
│  │  su-relay   │────▶│ magisk-proxy │────▶│  magiskd  │ │
│  │ (symlink    │     │ (C daemon,   │     │ (real     │ │
│  │  fixer)     │     │  uid 0)      │     │  daemon)  │ │
│  └──────┬──────┘     └──────┬───────┘     └───────────┘ │
│         │                   │                            │
│         │ symlink           │ unix socket                │
│         ▼                   ▼                            │
│  ┌──────────────────────────────────────┐               │
│  │  proot-<pid>-XXXXXX (hijacked path)  │               │
│  │  → symlink to magisk-proxy.sock      │               │
│  └──────────────────────────────────────┘               │
│         ▲                                                │
│         │ proot path translation                         │
│         │                                                │
│  ┌──────┴──────────────────────────────────────────┐    │
│  │            proot Container                        │    │
│  │                                                  │    │
│  │  /usr/local/bin/su ──bind──▶ Magisk su binary    │    │
│  │       │                                          │    │
│  │       ▼ connect(".magisk/device/socket")         │    │
│  │       │                                          │    │
│  │       └── proot translates ──▶ proot-<pid>-XXXXXX│    │
│  │                              (symlink → proxy)   │    │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

### 三个组件

#### 1. `magisk-proxy`（C daemon，宿主侧，uid 0）

**核心作用**：作为 su 客户端和 shell 之间的中间人，**不转发 socket 给 magiskd**，而是直接 fork shell。

- 监听 proxy socket（`/data/data/.../usr/tmp/magisk-proxy.sock`）
- 接收 su 协议请求（uid、shell 路径、命令）
- `fork()` + `exec()` 启动 shell（以请求的 uid 身份）
- 通过 `SCM_RIGHTS` 将 stdin/stdout/stderr pipe 的 fd 传回客户端
- 等待子进程结束，返回 exit code

**为什么不直接转发给 magiskd？**

因为 `check-client` 门禁要求连接进程的 `exe` 与 magisk 二进制是同一个文件（同 dev+inode）。代理进程的 exe 是自身二进制，永远不匹配。所以代理**绕过 magiskd**，直接实现 su 的功能。

#### 2. `su-relay`（C daemon，宿主侧）

**核心作用**：修复 proot 对 socket 的劫持。

- 轮询 `/proc/self/mountinfo`，查找 proot 创建的临时文件（`proot-<pid>-XXXXXX`）
- 这些临时文件被 proot bind-mount 到容器内的 `.magisk/device/socket` 路径
- 用 `symlink()` 将临时文件替换为指向 `magisk-proxy.sock` 的符号链接
- 内核沿 symlink 解析，客户端的 `connect()` 直达代理

**为什么用 symlink 而不是文件复制/转发？**

symlink 由内核透明解析，`getpeercred()` 返回的是**客户端自己的** uid/pid。如果用中转进程转发，peer 就变成了 relay 进程，身份信息丢失。

#### 3. `service.sh` / `boot-completed.sh`（Shell 脚本，模块安装后自动运行）

开机时由 Magisk 以 root 身份执行：

1. 自动发现 MAGISKTMP 路径（`/debug_ramdisk` 或 `/sbin`）
2. 等待 Termux CE 存储解锁（最多 120 秒）
3. 部署二进制到 Termux tmp 目录
4. bind mount Magisk su 到 proot 容器的 `/usr/bin/su` 和 `/usr/local/bin/su`
5. 启动 `magisk-proxy` 和 `su-relay`

### su 协议详解（Magisk v5）

Magisk su 客户端和 daemon 之间使用自定义二进制协议，包含版本握手：

**阶段 1：版本握手**
```
客户端 → daemon:  int32   version         # 当前为 5
daemon → 客户端:  int32   policy          # 0=ALLOW, 1=DENY, 2=INTERACTIVE
```

> **v2.5 关键修复**：policy 必须写 4 字节 `int32_t`。之前写 `uint8_t`(1 字节)，
> 客户端读 4 字节时吃掉了 su_request 的前 3 字节，导致协议错位 → `failed to read su_request`。

**阶段 2：su_request（客户端 → daemon）**
```
int32   uid           # 目标 uid（0 = root）
int32   access        # 0xffffffff = interactive
uint8   mode          # 0
uint8   login         # 0
uint8   keepenv       # 0
int32   shell_len
char[]  shell_path    # e.g. "/system/bin/sh"
int32   cmd_len
char[]  cmd_data      # e.g. "id" for su -c 'id'

# 环境变量（len=0 结束，非 terminator）
[int32  env_len]      # >0 时读 env_len 字节
[char[] env_data]     # 重复直到 env_len == 0

int32   target_selector
int32   mount_ns
int32   nice
```

**阶段 3：shell I/O（daemon → 客户端）**
```
SCM_RIGHTS × 3        # stdin(write-end), stdout(read-end), stderr(read-end)
int32   child_pid     # 子进程 PID
...                   # I/O 通过传回的 3 个 fd 进行
int32   exit_code     # 子进程退出码
```

## 文件结构

```
/data/adb/modules/termux-root-su/
├── module.prop           # Magisk 模块元数据
├── service.sh            # 开机启动脚本
├── boot-completed.sh     # boot 完成后的 fallback 检查
├── magisk-proxy          # C 编译的 root 代理 daemon
└── su-relay              # C 编译的 symlink 修复 daemon
```

运行时产物（自动生成在 Termux tmp 目录）：
```
/data/data/com.termux/files/usr/tmp/
├── magisk-proxy          # 部署的代理二进制
├── magisk-proxy.sock     # 代理监听的 unix socket
├── magisk-proxy.log      # 代理日志
├── su-relay              # 部署的 relay 二进制
├── su-relay.log          # relay 日志
└── su                    # Magisk su 的 bind mount
```

## 日志与排障

```bash
# 模块日志（开机流程）
cat /data/local/tmp/termux-root-su.log

# 代理日志（su 请求处理）
cat /data/data/com.termux/files/usr/tmp/magisk-proxy.log

# relay 日志（symlink 修复）
cat /data/data/com.termux/files/usr/tmp/su-relay.log
```

### 常见问题

**`Cannot connect to daemon: No such file or directory`**
- 模块未正确安装或未重启
- 检查 `/data/adb/modules/termux-root-su/` 是否存在
- 查看 `/data/local/tmp/termux-root-su.log` 中是否有 FATAL 错误

**`Accessed denied`**
- su 二进制是副本而非 bind mount（exe 不匹配）
- 检查 `ls -la /usr/local/bin/su`，应指向 Magisk su

**`failed to read su_request`（proxy 日志）**
- v2.4 及更早版本的 bug：policy 响应写 1 字节，客户端期望 4 字节，协议错位
- 升级到 v2.5+ 即可修复
- 如果日志显示 `client version: 5` 后紧跟此错误，确认二进制已更新

**重启后失效**
- `boot-completed.sh` 会自动检查并重启服务
- 如果仍然失败，手动运行：`su -c 'sh /data/adb/modules/termux-root-su/service.sh'`

## 兼容性

- Magisk 20.4+
- Android 7.0+
- ARM64 (aarch64)
- Termux + proot-distro（Ubuntu、Debian、Alpine 等）

## 许可证

MIT License

## 致谢

- [Magisk](https://github.com/topjohnwu/Magisk) — Android root 框架
- [proot](https://proot-me.github.io/) — 用户空间的 chroot/bind mount
- [Termux](https://termux.dev/) — Android 终端模拟器
- [proot-distro](https://github.com/termux/proot-distro) — Termux 的 Linux 发行版管理
