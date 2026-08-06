# termux-root-su 开发记忆

## 当前状态 (v3.4, 2026-08-06)
- **Bad system call 根因已定位并修复**: 静态 glibc 的 rseq syscall 在部分
  seccomp 策略下触发 SIGSYS。v3.4 改用 musl 静态编译, 免疫。
- **proxy 死后自动重启**: service.sh 启动 watchdog (每 15s 查 /proc/net/tcp)。
- **su 部署进 proot rootfs**: service.sh 遍历 containers/*/rootfs 部署。
- **容器内端口发现修复 (v3.4 二次修订, versionCode 341)**:
  - 容器内读不到宿主端口文件 → su 扫描 48000-48019 (hint 优先)。
  - 每个候选 1s 握手超时, 死监听者 (accept 但不应答) 快速跳过。
  - service.sh 把端口文件同步到 rootfs/tmp/magisk-proxy.port (容器内可见)。
  - 本机端到端验证: 死端口 48000 + proxy 48001 → su 0.2s 命中 48001, uid=0。
- 手机上 v3.3 的 proxy 实际活着 (18:16 boot 时 service.sh 成功, magisk 域内
  进程容器内 ps 不可见), "proxy 没跑" 是用户侧旧检测结果; v3.4 已加守护。

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
