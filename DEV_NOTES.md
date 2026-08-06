# termux-root-su 开发记忆

## 当前状态 (v3.6, 2026-08-06)
- **多连接修复**: proxy 每个连接 fork 独立 handler 进程,监听器永不
  阻塞(v3.5 单连接串行,一个会话卡死 → 所有 su 排队超时)。
- **会话释放修复**: relay 循环每次 poll 后 waitpid(child, WNOHANG),
  shell 退出即释放连接(防 pty master 不 EIO 永久挂起)。
- **bashrc 自愈**: /root/.bashrc 用 `su -c 'true'` 实测探测,proxy 没跑
  时容器内自动拉起(nohup magisk-proxy <port> &,proot 共享宿主网络栈)。
- v3.5 的 forkpty 交互、connect 非阻塞超时、idle 兜底、musl 静态均保留。

## v3.6 单连接串行缺陷完整排查记忆 (2026-08-06)

### 现象
- 用户: "启动新会话提示 proxy 没跑" + "su 进入交互式但退不出来"。
- 现场: proxy 日志有 `cmd=[] interactive=1`(一次交互连接)但之后
  **没有 child exited 记录**;所有后续 su 报
  `Cannot connect to daemon (127.0.0.1:48000-48019): Operation in
  progress (os error 115)`(残留 errno,扫描全端口失败)。

### 根因 (三层)
1. **proxy 单连接串行**: `for(;;){accept; ...relay loop...;}` 一次只
   处理一个连接。12:06:22 的交互会话(或其残留连接)卡住 relay 循环后,
   后续连接 connect 成功(内核 backlog)但永远收不到 child_pid →
   su 客户端每端口 1s 超时,全部失败。用 python connect + 发 cmd_len
   后 2s 无响应可确认"被死连接占用"。
2. **交互会话退出后连接不释放**: shell exit 后若 pty master 不产生
   EIO(后台作业持有 slave 等),relay 循环永久 poll,连接永不释放。
3. **bashrc 误报**: 检查 v2 时代遗留的 unix socket 文件
   `magisk-proxy.sock`(v3.x TCP 架构下恒假)→ 每次新会话必报
   "proxy 没跑",且提示指向已删除的 fix-proxy2.sh。

### 修复
- 连接处理抽成 handle_connection(cfd),accept 后 fork handler 进程;
  父进程 SIGCHLD handler waitpid(-1, WNOHANG) 收割,handler 内恢复
  SIG_DFL 自行 waitpid shell child。
- relay 循环每次 poll 返回后 waitpid(child, WNOHANG): child 已退出 →
  记 exit_code、break,循环后跳过 waitpid(child_waited 标志)。
- bashrc: `timeout 3 su -c 'true'` 探测(proxy 活着时 hint 端口直达,
  毫秒级);失败则 nohup 容器内拉起 proxy + 再探测;仍失败才提示
  用户去宿主跑 watchdog。

### 验证方法
- 多连接: python 打开一个挂死交互连接(发 cmd_len=0 后不发任何输入),
  并发 `su -c 'echo OK'` 应毫秒级成功(旧版会永久卡)。
- 退出释放: python pty.fork() 驱动交互 su,`exit` 后 waitpid 应返回,
  proxy.log 出现 "child X exited with code 0"。
- bashrc 自愈: `pkill -x magisk-proxy` 后交互加载 bashrc
  (`PS1='x' bash --noprofile -i -c 'exit'`)应打印自动启动并恢复 su。
  ⚠️ `bash -c`(非交互)下 PS1 被清空,bashrc 开头 `[ -z "$PS1" ] && return`
  会提前返回——测试必须用 `-i` 模拟交互加载。

### 容器内诊断限制(重要)
- `/proc/net/tcp` 容器内 Permission denied → 不能像 watchdog 那样查端口。
- ps/pgrep 看不到宿主进程,容器内 pkill 杀不掉宿主侧 proxy。
- 判定 proxy 状态: python connect 127.0.0.1:PORT(共享网络栈,可达);
  connect OK + 发 cmd_len 无响应 = 被死连接占用。
- 容器内能写宿主 /data/data/com.termux/files/usr/tmp 目录(可新建文件),
  但 root 属主 644 文件(如 port 文件)不能覆盖写 → rm 后重建。

## 待办
- [ ] 用户刷入 v3.6 zip (termux-root-su-v3.6.zip, 重启后 service.sh
      会用模块内旧版覆盖部署的 v3.6, 需重刷)
- [ ] 旧宿主 proxy (pid 8177, 占 48000 死连接) 重启后自然消失, 无需处理

## v3.5 交互式 su 挂死完整排查记忆 (2026-08-06)

### 现象
- 容器内 `su`(交互式)无输出,Ctrl+C 无法退出;`su -c 'cmd'` 正常
  (能输出 uid=0)。用户刷 v3.4 后仍未解决。

### 根因 (两层)
1. **proxy 用 pipe 给 child**: sh 的 stdin/stdout 是 pipe 而非 tty →
   sh 以非交互模式运行: 无提示符、无回显。
2. **su 客户端 raw mode 清除本地 ISIG**: 终端 Ctrl+C 不再产生 SIGINT,
   变成 0x03 字节经 socket 发给 proxy 的 sh;非交互 sh(pipe stdin)
   忽略 0x03 → 无法中断、无法退出。

### 修复
- proxy 交互模式(cmd_len==0)用 `forkpty(&master, ...)` 替换
  pipe+fork: child 的 stdin/stdout/stderr 是 pty slave,sh 检测到
  tty 进入交互模式;提示符/回显/ISIG 由 pty 驱动完成,Ctrl+C 字节
  写入 master 后 pty 驱动转成 SIGINT 发给 sh。
- 客户端断开保护:
  - send_frame 失败(客户端 socket 消失)→ kill(child, SIGTERM)
  - stdin EOF 后 idle 超时: 交互 10s / 非交互 60s kill 失控 child
    (如 `su -c 'sleep 30'` 客户端被杀后 child 继续跑,waitpid 会
    阻塞 accept 循环)。
- su 客户端 connect 改非阻塞 + poll 1s: 死监听者(吞 SYN/accept 后
  不应答)不再拖住整个扫描。实测 48000 死监听时从 32s+ 降到 1.1s。

### 验证方法
- 交互: python pty.fork() 驱动 su,检查提示符、回显、`sleep 30` +
  `\x03` → `^C` + exit 130、中断后 shell 存活、exit 退出。
- 防阻塞: `timeout 2 su -c 'sleep 30'` 杀掉客户端后,新连接应
  立即可用(proxy 不再 waitpid 阻塞)。
- 死监听: python 建一个 accept 后不响应的 socket,su 应 1s 内跳过。

## 待办
- [ ] 用户刷入 v3.5 验证 (交互式 su: 提示符/Ctrl+C/exit; -c 模式)

## v3.4 Bad system call (SIGSYS) 完整排查记忆 (2026-08-06)

### 现象
- 宿主侧 `su -c 'echo hi'` → `Bad system call`, rc=159 (=128+31, SIGSYS),
  无任何输出; proxy.log 无连接记录 (su 在 connect 之前就死了)。
- 容器内同二进制 `su -c 'echo hi'` 完全正常。同一手机, 同一二进制,
  容器内外行为不同, 这是排查最大的迷惑点。

### 关键对比数据 (一锤定音)
| 环境 | NoNewPrivs | Seccomp_filters |
|---|---|---|
| 宿主侧 (用户终端) | 0 | 1 |
| proot 容器内 | 1 | 2 |

→ 两个环境的 seccomp 策略**不同**。容器内是 Android 13 (sdk 33) 的 app
策略 (白名单含 rseq, bionic 12+ 用 rseq); 用户终端的策略 (filters=1)
**不含 rseq**。

### 根因
- 静态 glibc (aarch64-linux-gnu-gcc, Ubuntu 22.04 glibc 2.35) 的二进制
  启动时会调用 `rseq` (注册 restartable sequences)。
- 用户环境的 seccomp 过滤器对 rseq 是 `SECCOMP_RET_KILL` → SIGSYS →
  进程启动即死 → "Bad system call"。
- glibc 的 rseq 注册失败若返回 ENOSYS 会静默跳过, 但 seccomp KILL 直接
  杀进程, 没有回退机会。

### 验证方法 (本机可复现)
- 用 seccomp-bpf 写拦截器 (kill-rseq.c): PR_SET_NO_NEW_PRIVS + filter
  拦 `__NR_rseq` (aarch64 = 293) 其余 ALLOW, 然后 exec 被测二进制。
- glibc 版 su → rc=159 ✅ 复现; musl 版 su → rc=0 ✅ 免疫。
- 结论: musl 不注册 rseq, 与任何 seccomp 策略兼容。

### 修复
- **所有二进制改用 musl 静态编译**: `musl-gcc -O2 -static`。
  - musl 版 su 66KB / magisk-proxy 67KB (glibc 版 603KB)。
  - build.sh 现在优先 musl-gcc。
- 注意: 静态 glibc 还有 clone3 (2.34+)、faccessat2 (2.33+) 等新 syscall
  同样是 Android seccomp 的潜在雷, musl 全部规避。

### 排查教训
1. **"同一二进制容器内正常、宿主侧 Bad system call" ≠ 二进制问题,
   是 seccomp 策略不同**。先对比两边的 `/proc/self/status` 的
   Seccomp/Seccomp_filters/NoNewPrivs。
2. **proxy.log 有没有连接记录**是分水岭: 没有 → 客户端死在 connect 前
   (启动 syscall 被拦); 有 → 协议/传输问题。
3. **Android 13 的 app seccomp 策略含 rseq** (bionic 12+ 用 rseq),
   但 shell/root/其他上下文的策略可能不含 → 静态 glibc 二进制在非 app
   上下文跑必死。**跨 Android 环境分发二进制一律用 musl 静态**。
4. **magisk SELinux 域 (u:r:magisk:s0) 内跑的进程, 容器内 ps 读不到
   /proc/<pid>** (显示为 [magisk-proxy] 方括号) → 检测存活用
   `/proc/net/tcp` 端口监听, 不要用 pgrep 进程名。
5. **pkill -f 会误杀命令行含关键字的进程** (watchdog 脚本名含
   magisk-proxy) → 用 `pkill -x` (精确进程名) 或带空格模式。

## 核心问题与修复历程

### 真正的根因 (v3.3 确认)
- proot 对被 bind 进容器的 unix socket 做**虚拟挂载劫持**:
  在宿主 `usr/tmp` 创建 `proot-<pid>-XXXXXX` 临时文件,虚拟 bind 到容器内路径。
  容器内 connect() 到该路径 → 连到 proot 临时"死 socket"(可能 listen 但无转发)
  → 连接"成功"但无任何响应 → su 挂死,proxy 无连接记录。
- **v3.2 su-relay 无效的原因**: proot 的挂载是**虚拟的**(ptrace 拦截 mountinfo
  读取注入,只对容器内进程可见),宿主侧 su-relay 扫 `/proc/self/mountinfo`
  永远找不到 proot-* 条目 → 修补从未发生。宿主的真实 mountinfo 与容器视角
  完全不同,任何"宿主侧扫描 mountinfo"的方案都不可行。
- **TCP loopback 为什么可行**: proot 只劫持 unix socket 路径翻译,不隔离网络。
  容器与宿主共享 loopback。127.0.0.1:PORT 无路径、无翻译、无劫持。

### 本机验证结论 (proot 环境实测)
- 普通 unix socket(直接建在可访问路径): connect 直达,无劫持
- bind 进来的 socket: mountinfo 出现 proot-* 虚拟条目,connect "成功"但 recv 超时
- v3.1 协议链在"无劫持"路径下完整工作(本机 trace 证明)

## 已知 Bug 与修复

### 1. SIGCHLD SIG_IGN 导致 exit code 全为 0
- `signal(SIGCHLD, SIG_IGN)` 让内核自动回收子进程但丢弃退出状态
- **修复**: 移除 `signal(SIGCHLD, SIG_IGN)`

### 2. stdin EOF 未 shutdown → 子进程挂死 (v3.3 修复)
- su 客户端 stdin EOF 只停止转发,未 `shutdown(SHUT_WR)` → proxy 侧
  子进程(如 `cat`)永远等不到 stdin EOF → 挂死
- 现象: `echo x | su -c cat` 不退出
- **修复**: EOF 时 `shutdown(sock, SHUT_WR)` 半关闭,proxy 收到 EOF 关 stdin pipe

### 3. su 客户端部署遗漏
- 重新编译后忘记把 su 二进制拷贝到 /usr/local/bin/su
- 导致运行的还是旧版二进制

### 4. v3.1/v3.2 su 在 proot 内挂死无输出 (v3.3 修复)
- 根因见上"真正的根因": proot 虚拟挂载劫持 unix socket,su 连到死 socket
- v3.2 的 su-relay 修补方案基于错误假设(宿主侧可见虚拟挂载),从未生效
- **修复**: 弃用 unix socket,改用 TCP loopback

### 5. build.sh 打包残留 (v3.3 修复)
- build/ 旧产物不清理 + zip 更新模式不删旧条目 → 旧 su-relay 混进新 zip
- **修复**: 构建前 rm build/ 下旧二进制,打包前 rm 旧 zip

## 教训 (2026-08-06, v3.3)

1. **宿主侧永远看不到 proot 的虚拟挂载/路径翻译**。proot 用 ptrace 拦截
   mountinfo 读取并注入虚拟条目,只对容器内进程可见。任何"宿主侧扫描
   mountinfo/proc 修补 proot 产物"的方案(如 v3.2 su-relay)都不可行。
2. **proot 环境下的跨边界 IPC 首选 TCP loopback**。proot 只劫持 unix socket
   路径、不隔离网络;127.0.0.1 共享且无路径翻译。unix socket 只在容器内
   进程间可用,跨 proot 边界一律选 loopback。
3. **用户刷 v3.2 未解决 = su-relay 从未生效的直接证据**。v3.2 假设
   "proot 创建临时文件 + 宿主 mountinfo 可见",实际两者都错:临时文件
   真实存在但挂载是虚拟的,宿主侧匹配不到。
4. **本机工作站本身就是 PRoot-Distro**,可以直接复现 unix socket 劫持
   (建 socket 看 mountinfo 的 proot-* 条目、connect 到 bind 进来的
   socket 观察"成功但无响应")。调试 proot 相关问题不必上真机。
5. 判断"二进制是否真的部署了":v3.1 起 su 有 5 秒 poll 超时,若刷新版本后
   仍无限挂死,先怀疑跑的是旧二进制(部署遗漏/旧进程残留),再怀疑逻辑。

## 文件结构

```
termux-root-su/
├── src/
│   ├── magisk-proxy.c    # v3.3 TCP loopback 代理(帧协议)
│   ├── su.c              # v3.3 自定义 su 客户端(TCP + 端口文件)
│   ├── su-relay.c        # 已废弃(参考保留,不再构建部署)
│   └── test-proxy-client.c  # 旧版测试客户端(未适配)
├── prebuilt/              # 预编译二进制(magisk-proxy + su)
├── build.sh               # 打包脚本
├── service.sh             # Magisk 模块启动脚本(TCP 端口分配)
├── boot-completed.sh      # 启动后检查脚本
└── module.prop            # 模块属性(v3.3)
```

## 协议规格 (v3.3, 与 v3.1 相同仅传输层不同)

```
客户端 → proxy:  uint32 cmd_len, char cmd[cmd_len]
proxy → 客户端:  uint32 child_pid
[relay phase]
  proxy → 客户端:  uint32 frame_len, char data[frame_len]  (stdout/stderr)
  客户端 → proxy:  raw stdin bytes
[end relay]
proxy → 客户端:  uint32 0  (end marker)
proxy → 客户端:  uint32 exit_code
```

## 待办
- [ ] 用户刷入 v3.4 验证 (宿主侧 su -c echo hi / 容器内 su -c id)
- [ ] GitHub commit & push (v3.4)
