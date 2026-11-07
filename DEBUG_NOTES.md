# termux-root-su v3.6 — 模块记忆与排障手册

随模块安装到 /data/adb/modules/termux-root-su/。改代码前先读 src/ 注释与
CHANGELOG.md; 真机排障按本文档流程走。

## 架构速览 (v3.6)

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
  → 多连接: 每个连接一个 handler 进程 (v3.6), 一个会话卡死不阻塞他人

容器内自愈 (v3.6, /root/.bashrc):
  proxy 没跑时自动 nohup 拉起容器内 proxy — proot 与宿主共享网络栈,
  监听 127.0.0.1:<port> 即可被 su 使用。宿主导常驻时不会重复拉起。
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

### 6b. 单连接串行缺陷 (v3.6 已修) — "连接全部超时" 的元凶
- 症状: proxy.log 有 `cmd=[] interactive=1` 但之后没有 child exited;
  所有后续 su 报 `Cannot connect to daemon: Operation in progress`,
  su 扫描每端口 1s 超时 (connect 成功但收不到 child_pid)。
- 根因: 旧 proxy `for(;;){accept; relay;}` 一次只服务一个连接, 一个
  会话卡住 relay 循环 → 所有新连接在内核 backlog 排队。
- v3.6: accept 后 fork handler 进程, 监听器永不阻塞。
- 判定: python connect + 发 `struct.pack('<I', 0)` 后 2s 无响应 =
  被死连接占用 (旧版) / proxy 异常 (新版)。

### 6c. 交互 shell 退出后连接不释放 (v3.6 已修)
- shell exit 后 pty master 不产生 EIO (后台作业持有 slave) → 旧 relay
  循环永久 poll → 连接永久挂起, 日志停在 cmd= 无 child exited。
- v3.6: relay 循环每次 poll 后 `waitpid(child, WNOHANG)`, shell 已退出
  立即结束会话发送 exit_code。

### 6d. bashrc "proxy 没跑" 误报 (v3.6 已修)
- 旧检查 `[ -S magisk-proxy.sock ]` 是 v2 unix socket 遗留, v3.x TCP
  架构恒假 → 每次新会话误报。
- v3.6 bashrc: `timeout 3 su -c 'true'` 实测探测; 失败自动容器内拉起
  proxy; 仍失败才提示去宿主跑 watchdog。
- ⚠️ 改 bashrc 后测试必须交互加载 (`bash --noprofile -i`), `bash -c`
  非交互下 PS1 为空, bashrc 开头 `[ -z "$PS1" ] && return` 提前返回。

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
   (容器内 /proc/net/tcp 不可读, 改用 python connect 127.0.0.1:PORT)
3. `cat /data/data/com.termux/files/usr/tmp/magisk-proxy.log | tail` — 连接记录
   (有 cmd= 无 child exited = 会话挂着/连接未释放, 查 6c)
4. 宿主侧 `su -c 'echo hi'` — 若 Bad system call → 二进制不是 musl 版
   (`md5sum /data/data/com.termux/files/usr/bin/su` 与模块内 prebuilt/su 对比)
5. 容器内 `su -c id` — 若报 Cannot connect / 挂死 → 端口文件/网络问题,
   python 探测: connect OK + 发 cmd_len 无响应 = 死连接占用 (查 6b)
6. 容器内交互 `su` — 无提示符/Ctrl+C 无效 → proxy 不是 v3.5 (pty 缺失)
7. 交互 `su` 退出: 输入 `exit` 或 Ctrl+D。退出后 proxy.log 应出现
   child exited; 若没有 → 连接未释放 (查 6c)。

## 版本历史速查
- v2.2: C proxy + su-relay (symlink 修补, 思路错)
- v3.1: 帧协议 + 自定义 su 客户端 (unix socket, proot 劫持挂死)
- v3.2: su-relay 监控 proxy socket (从未生效)
- v3.3: TCP loopback (挂死修复), 移除 su-relay
- v3.4: musl 编译 (SIGSYS 修复) + watchdog + rootfs 部署
- v3.5: 交互 forkpty (无输出/退不出修复) + connect 超时 + proxy 防阻塞
- v3.6: 多连接 handler (单连接串行修复) + child 退出检测 (连接释放)
        + bashrc 自愈 (容器内自动拉起 proxy)
- v3.7: bashrc 改纯探测 (容器内假 root 占端口修复)
- v3.8: 修"重启后 su 永远不可用"。双重根因:
        (a) service.sh 的 CE 解锁等待只有 120s。本 ROM 的 late_start 远早于
            用户首次解锁, 超时 exit 1 → su 部署和 proxy 启动整段静默跳过
            (证据: su/端口文件时间戳停在 11-01, /debug_ramdisk/.magisk/device/
            socket 的死 symlink 未被删 = service.sh 没跑到那行)。→ 提到 240s。
        (b) boot-completed.sh 只要 watchdog **脚本文件**存在就 exit 0
            ("watchdog 15s 内会拉起")。但 watchdog 是上次开机的进程, 重启后
            进程没了、文件还在 → 开机自检恒过, 谁都不起 proxy → 无论重启
            多少次都不行。→ 改成: 等 CE 解锁(最长 15min) → 无条件跑
            service.sh → 用 `su -c 'id -u' == 0` 按身份验收, 绝不再按
            文件是否存在推断进程状态。
        另: 日志双写 /sdcard/Download/trsu-boot.log —— proot 绑定了 /sdcard,
        容器里的 agent 免 root 就能看开机证据 (以前只能靠宿主人肉贴日志)。

## 坑 9: Termux 里 /product/bin/su 报 CANNOT LINK EXECUTABLE (v3.8 文档化)
- 症状: Termux 宿主 shell 里执行 `/product/bin/su -c '...'` →
  `CANNOT LINK EXECUTABLE "/product/bin/su": library
  "/data/data/com.termux/files/usr/lib/libtermux-exec-ld-preload.so"
  needed or dlopened by "/product/bin/magisk" is not accessible for the
  namespace "(default)"`
- 根因: /product/bin/su 是 magisk 的符号链接, 客户端会重执行为 magisk 本体;
  Termux 终端导出的 LD_PRELOAD 指向 Termux 私有 .so, Android linker 的
  default namespace 拒绝加载 → 客户端在联系 magiskd 之前就死。
- 复现: `LD_PRELOAD=...so /product/bin/magisk -v` 报同样错;
  `env -u LD_PRELOAD /product/bin/magisk -v` 恢复正常(报 Cannot connect)。
- 正解(以后所有文档/提示都用这条):
  `env -u LD_PRELOAD /product/bin/su -c 'sh /sdcard/Download/fix-root2.sh'`
