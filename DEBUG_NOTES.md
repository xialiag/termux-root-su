# termux-root-su v3.5 — 模块记忆与排障手册

随模块安装到 /data/adb/modules/termux-root-su/。改代码前先读 src/ 注释与
CHANGELOG.md; 真机排障按本文档流程走。

## 架构速览 (v3.5)

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
  → 交互式 (cmd_len==0): proxy 用 forkpty, child 有真实 pty
    (提示符/回显/Ctrl+C→SIGINT 全正常)
```

关键文件 (宿主侧):
- 日志:  /data/local/tmp/termux-root-su.log
- 端口:  /data/data/com.termux/files/usr/tmp/magisk-proxy.port
- proxy 日志: /data/data/com.termux/files/usr/tmp/magisk-proxy.log
- watchdog:  /data/data/com.termux/files/usr/tmp/magisk-proxy-watchdog.sh

## 已知坑 (务必记住)

### 1. 交互式 su 无输出/退不出 = 没有 pty
- v3.4 用 pipe 给 child → sh 非交互 (无提示符无回显) + su 客户端 raw
  mode 清 ISIG → Ctrl+C 变 0x03 字节, 非交互 sh 忽略 → 挂死。
- v3.5 交互模式 forkpty 修复。若复现, 看 proxy.log 的
  "cmd=[] interactive=1" 是否出现 (连接到了) 与 child 退出码。

### 2. Bad system call (rc=159) = seccomp SIGSYS
- **静态 glibc 二进制**启动时注册 rseq syscall; 非 app 上下文
  (Seccomp_filters=1 的策略) 白名单无 rseq → 启动即死, 无输出,
  proxy.log 无连接记录。
- **修复**: 二进制必须用 musl 静态编译 (musl 不注册 rseq)。
- 排查: 对比宿主/容器 `/proc/self/status` 的 Seccomp_filters 数量;
  proxy.log 有无 cmd= 记录区分"启动死"还是"connect 后死"。
- 复现: 本机用 seccomp-bpf 拦 __NR_rseq (aarch64=293) 再 exec 被测二进制。

### 3. proxy 存活检测用端口, 不用 pgrep
- magisk SELinux 域 (u:r:magisk:s0) 内进程的 /proc/<pid> 对 app 不可读,
  pgrep/ps 看不见 (显示 [magisk-proxy])。
- 检测: `grep -q ":BB80 " /proc/net/tcp` (48000=0xBB80) 或遍历 48000-48019。

### 4. pkill 模式
- `pkill -f "magisk-proxy"` 会匹配 watchdog 脚本自身 (命令行含
  magisk-proxy-watchdog) → 用 `pkill -x magisk-proxy` (精确进程名)。

### 5. 死监听者拖慢 su 扫描
- 阻塞 connect() 到"吞 SYN/accept 不应答"的残留监听者时内核重试,
  可挂 32s+。v3.5 su 用非阻塞 connect + 1s poll, 每端口最多 1s。
- 症状: su 长时间无输出然后才连上 (或超时报 Cannot connect)。

### 6. 客户端断开后 proxy 不能卡
- send_frame 失败 (客户端 socket 消失) → kill child。
- stdin EOF 后 idle 兜底: 交互 10s / 非交互 60s kill 失控 child。
- 若 proxy 不再 accept 新连接, 先查是否还有 waitpid 阻塞的旧逻辑。

### 7. proot unix socket 劫持 (v3.3 之前的历史, 已弃用 unix socket)
- proot 对被 bind 进容器的 unix socket 做虚拟挂载 (宿主 usr/tmp 出现
  proot-<pid>-XXXXXX), 容器内 connect "成功"但无响应 → 挂死。
- 正解: TCP loopback。proot 只劫持路径翻译, 不隔离网络。

### 8. service.sh 部署位置
- 容器内 PATH 的 su 是 rootfs/usr/local/bin/su, 不是宿主
  files/usr/local/bin/su。改部署逻辑时两处都要覆盖。

## 排障流程

1. `cat /data/local/tmp/termux-root-su.log | tail` — service.sh 死在哪步
2. `grep -q ":BB80 " /proc/net/tcp && echo alive` — proxy 端口检测
3. `cat /data/data/com.termux/files/usr/tmp/magisk-proxy.log | tail` — 连接记录
4. 宿主侧 `su -c 'echo hi'` — 若 Bad system call → 二进制不是 musl 版
   (`md5sum /data/data/com.termux/files/usr/bin/su` 与模块内 prebuilt/su 对比)
5. 容器内 `su -c id` — 若报 Cannot connect / 挂死 → 端口文件/网络问题
6. 容器内交互 `su` — 无提示符/Ctrl+C 无效 → proxy 不是 v3.5 (pty 缺失)

## 版本历史速查
- v2.2: C proxy + su-relay (symlink 修补, 思路错)
- v3.1: 帧协议 + 自定义 su 客户端 (unix socket, proot 劫持挂死)
- v3.2: su-relay 监控 proxy socket (从未生效)
- v3.3: TCP loopback (挂死修复), 移除 su-relay
- v3.4: musl 编译 (SIGSYS 修复) + watchdog + rootfs 部署
- v3.5: 交互 forkpty (无输出/退不出修复) + connect 超时 + proxy 防阻塞
