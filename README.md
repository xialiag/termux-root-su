# Termux Root SU

**在 Termux proot 容器内获取 Magisk 真 root 权限。**

注意: 此模块用于在proot环境中使用真实su，需要设备已root，并不能帮你获取root
一个 Magisk 模块，通过 root 代理架构，让 proot 容器内的 `su` 命令绕过 magiskd 的 `check-client` 门禁，直接以 uid=0 执行 shell。

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

# 打包 zip（--build 从源码编译，不加则用 prebuilt 二进制）
./build.sh v3.6 --build
```

> 编译必须使用 musl-gcc（build.sh 自动优先选择）：静态 glibc 启动时注册
> `rseq` syscall，在部分 Android seccomp 策略下触发 SIGSYS（Bad system call，
> rc=159），musl 静态二进制无此问题。

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

1. **magiskd 的 check-client 门禁**：Magisk 的 `su` 二进制连接 magiskd 时，
   daemon 会检查连接进程的 exe 与 magisk 二进制是否同 dev+inode。proot
   容器内的进程 `/proc/<pid>/exe` 指向 proot loader，永远无法通过。
2. **proot 劫持 unix socket**：proot 会把容器 rootfs 中的 unix socket 路径
   虚拟挂载为宿主侧临时文件（`proot-<pid>-XXXXXX`），容器内 `connect()` 实际
   连到无人响应的"死 socket"。**跨 proot 边界的 IPC 不能走 unix socket**。
3. **seccomp 差异**：部分环境的 seccomp 策略不含 `rseq`，静态 glibc 二进制
   启动即 SIGSYS（rc=159）。必须 musl 静态编译。

### 解决方案：TCP loopback 代理架构

```
┌──────────────────────────────────────────────────────┐
│                  Host (Android)                       │
│                                                      │
│  ┌─────────────────────┐        ┌──────────────────┐ │
│  │  magisk-proxy       │        │  watchdog        │ │
│  │  (C daemon, uid 0)  │◀───────│  (每 15s 查端口) │ │
│  │  监听 127.0.0.1:    │        └──────────────────┘ │
│  │  48000-48019        │                             │
│  └──────────▲──────────┘                             │
│             │ TCP loopback（proot 不做路径翻译，无劫持）│
│  ┌──────────┴──────────────────────────────────────┐ │
│  │              proot Container                     │ │
│  │                                                 │ │
│  │  /usr/local/bin/su ──TCP──▶ 127.0.0.1:<port>    │ │
│  │       │  (musl 静态自定义客户端)                  │ │
│  │       └── su -c 'cmd' / 交互 shell (pty)         │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

### 组件

#### 1. `magisk-proxy`（C daemon，宿主侧，uid 0）

**核心作用**：绕过 magiskd，直接 fork shell 实现 su。

- 监听 `127.0.0.1:48000-48019`（service.sh 自动选可用端口，写入
  `magisk-proxy.port`，并同步到各容器 rootfs 的 `/tmp/magisk-proxy.port`）
- 每个连接 fork 独立 handler 进程（v3.6 起），单个会话挂死不影响其他请求
- 交互会话（无命令）用 `forkpty` 分配真实 pty：提示符/回显/Ctrl+C 全部正常
- `send_frame` 失败或 stdin EOF 后 idle 超时兜底 kill 失控 child，监听器永不阻塞

#### 2. `su`（musl 静态客户端，部署在宿主与各容器）

**核心作用**：替代 Magisk su 二进制，通过 TCP 帧协议与 proxy 通信。

- 读端口文件（容器内读 `/tmp/magisk-proxy.port`），失败则扫描 48000-48019，
  每个端口非阻塞 connect + 1s 超时（防被吞 SYN 的死监听者卡死）
- 帧协议：`uint32 cmd_len + cmd` → `uint32 child_pid` →
  `uint32 frame_len + data`（stdout/stderr，len=0 结束）→ `uint32 exit_code`
- stdin 原始字节流，EOF 时半关闭

#### 3. `service.sh` / `boot-completed.sh`（Shell 脚本，模块安装后自动运行）

开机时由 Magisk 以 root 身份执行：

1. 自动发现 MAGISKTMP 路径（`/debug_ramdisk` 或 `/sbin`）
2. 等待 Termux CE 存储解锁（最多 120 秒）
3. 部署 `magisk-proxy` + `su` 到 Termux tmp 目录和 files/usr/bin、
   files/usr/local/bin，并同步到每个 proot 容器 rootfs 的 usr/local/bin
4. 启动 `magisk-proxy` + watchdog（每 15s 用 /proc/net/tcp 检测端口，
   proxy 死后自动重启）
5. 清理 v3.3 之前的 su-relay 遗留（TCP 架构不再需要 socket 修补）

#### 4. 容器 bashrc 自愈（v3.6，部署在容器 `/root/.bashrc`）

proxy 未运行时，bashrc 用 `timeout 3 su -c 'true'` 实测探测；失败则容器内
`nohup magisk-proxy <port> &` 自动拉起（proot 与宿主共享网络栈，监听
127.0.0.1 立即可用）；仍失败才提示去宿主 Termux 跑 watchdog。

### 传输协议（v3.x 帧协议）

```
客户端 → proxy:  uint32 cmd_len + cmd        # cmd_len=0 表示交互 shell
proxy → 客户端:  uint32 child_pid
proxy → 客户端:  uint32 frame_len + data     # stdout/stderr，len=0 结束
客户端 → proxy:  raw stdin（EOF 时半关闭）
proxy → 客户端:  uint32 exit_code
```

> v2.x 的 Magisk su 原生协议（版本握手 + su_request + SCM_RIGHTS）已废弃：
> proot 会破坏 SCM_RIGHTS ancillary data 传递，且 check-client 门禁无法绕过。

## 文件结构

```
/data/adb/modules/termux-root-su/
├── module.prop           # Magisk 模块元数据
├── service.sh            # 开机启动脚本
├── boot-completed.sh     # boot 完成后的 fallback 检查
├── magisk-proxy          # root 代理 daemon（musl 静态）
└── su                    # 自定义 su 客户端（musl 静态）
```

运行时产物（自动生成在 Termux tmp 目录）：
```
/data/data/com.termux/files/usr/tmp/
├── magisk-proxy          # 部署的代理二进制
├── magisk-proxy.port     # 实际监听端口（0644，容器可读）
├── magisk-proxy.log      # 代理日志
├── magisk-proxy-watchdog.sh  # 端口检测看门狗
└── su                    # 部署的 su 客户端

proot 容器 rootfs：
/tmp/magisk-proxy.port    # 端口同步（容器内可见）
/usr/local/bin/su         # su 客户端
```

## 日志与排障

```bash
# 模块日志（开机流程）
cat /data/local/tmp/termux-root-su.log

# 代理日志（su 请求处理）
cat /data/data/com.termux/files/usr/tmp/magisk-proxy.log

# proxy 是否在监听（48000=0xBB80）
grep -q ":BB80 " /proc/net/tcp && echo "proxy listening"
```

### 常见问题

**`Cannot connect to daemon: Operation in progress`**
- v3.5 及更早版本的串行缺陷：某个会话卡住 relay 循环后所有请求排队
- 升级到 v3.6+（每连接独立 handler）即可修复

**交互 `su` 无提示符、无输出，Ctrl+C 无效**
- proxy 不是 v3.5+（交互会话无 pty）。升级模块并确认 `magisk-proxy`
  已更新（md5sum 对比 prebuilt/）

**`Bad system call`（rc=159, SIGSYS）**
- 二进制是静态 glibc 版（注册 rseq syscall 被 seccomp 拦截）
- 确认使用 musl 静态编译版（v3.4+ 默认）

**`Accessed denied` / `Cannot connect to daemon: No such file or directory`**
- 模块未正确安装或未重启
- 检查 `/data/adb/modules/termux-root-su/` 是否存在
- 查看 `/data/local/tmp/termux-root-su.log` 中是否有 FATAL 错误

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
