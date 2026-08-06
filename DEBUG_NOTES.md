# termux-root-su v3.4 — 模块记忆与排障手册

随模块安装到 /data/adb/modules/termux-root-su/。改代码前先读 src/ 注释与
CHANGELOG.md; 真机排障按本文档流程走。

## 架构速览 (v3.4)

```
宿主侧 (root, Magisk boot):
  service.sh ──部署 su → files/usr/bin/su, files/usr/local/bin/su,
                         proot-distro/containers/*/rootfs/usr/local/bin/su
             └─起 magisk-proxy (TCP 127.0.0.1:48000+, 端口写 magisk-proxy.port)
             └─起 magisk-proxy-watchdog.sh (每 15s 查 /proc/net/tcp, 死了拉起)

proot 容器内:
  su (musl 静态) → 读 files/usr/tmp/magisk-proxy.port → 连 127.0.0.1:PORT
  → 帧协议: uint32 cmd_len + cmd / uint32 child_pid /
            uint32 frame_len + data (stdout/stderr) / raw stdin /
            uint32 0 + uint32 exit_code
```

关键文件 (宿主侧):
- 日志:  /data/local/tmp/termux-root-su.log
- 端口:  /data/data/com.termux/files/usr/tmp/magisk-proxy.port
- proxy 日志: /data/data/com.termux/files/usr/tmp/magisk-proxy.log
- watchdog:  /data/data/com.termux/files/usr/tmp/magisk-proxy-watchdog.sh

## 已知坑 (务必记住)

### 1. Bad system call (rc=159) = seccomp SIGSYS
- **静态 glibc 二进制**启动时注册 rseq syscall; 非 app 上下文
  (Seccomp_filters=1 的策略) 白名单无 rseq → 启动即死, 无输出,
  proxy.log 无连接记录。
- **修复**: 二进制必须用 musl 静态编译 (musl 不注册 rseq)。
- 排查: 对比宿主/容器 `/proc/self/status` 的 Seccomp_filters 数量;
  proxy.log 有无 cmd= 记录区分"启动死"还是"connect 后死"。
- 复现: 本机用 seccomp-bpf 拦 __NR_rseq (aarch64=293) 再 exec 被测二进制。

### 2. proxy 存活检测用端口, 不用 pgrep
- magisk SELinux 域 (u:r:magisk:s0) 内进程的 /proc/<pid> 对 app 不可读,
  pgrep/ps 看不见 (显示 [magisk-proxy])。
- 检测: `grep -q ":BB80 " /proc/net/tcp` (48000=0xBB80) 或遍历 48000-48019。

### 3. pkill 模式
- `pkill -f "magisk-proxy"` 会匹配 watchdog 脚本自身 (命令行含
  magisk-proxy-watchdog) → 用 `pkill -x magisk-proxy` (精确进程名)。

### 4. proot unix socket 劫持 (v3.3 之前的历史, 已弃用 unix socket)
- proot 对被 bind 进容器的 unix socket 做虚拟挂载 (宿主 usr/tmp 出现
  proot-<pid>-XXXXXX), 容器内 connect "成功"但无响应 → 挂死。
- 正解: TCP loopback。proot 只劫持路径翻译, 不隔离网络。

### 5. service.sh 部署位置
- 容器内 PATH 的 su 是 rootfs/usr/local/bin/su, 不是宿主
  files/usr/local/bin/su。改部署逻辑时两处都要覆盖。

## 排障流程

1. `cat /data/local/tmp/termux-root-su.log | tail` — service.sh 死在哪步
2. `grep -q ":BB80 " /proc/net/tcp && echo alive` — proxy 端口检测
3. `cat /data/data/com.termux/files/usr/tmp/magisk-proxy.log | tail` — 连接记录
4. 宿主侧 `su -c 'echo hi'` — 若 Bad system call → 二进制不是 musl 版
   (`md5sum /data/data/com.termux/files/usr/bin/su` 与模块内 prebuilt/su 对比)
5. 容器内 `su -c id` — 若报 Cannot connect / 挂死 → 端口文件/网络问题

## 版本历史速查
- v2.2: C proxy + su-relay (symlink 修补, 思路错)
- v3.1: 帧协议 + 自定义 su 客户端 (unix socket, proot 劫持挂死)
- v3.2: su-relay 监控 proxy socket (从未生效)
- v3.3: TCP loopback (挂死修复), 移除 su-relay
- v3.4: musl 编译 (SIGSYS 修复) + watchdog + rootfs 部署
