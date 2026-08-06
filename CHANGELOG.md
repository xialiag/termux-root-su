# CHANGELOG

## v3.5 (2026-08-06)
- **修复交互式 `su` 无输出、Ctrl+C 无法退出**:proxy 对交互会话
  (cmd_len==0) 改用 `forkpty` 给 child 分配真实 pty。
  - 根因: 旧版用 pipe 给 child,sh 以非交互模式运行 —— 无提示符、
    无回显;su 客户端 raw mode 清除了本地 ISIG,Ctrl+C 变成 0x03 字节
    发给管道另一端的非交互 sh,sh 忽略 → 会话看起来"死了",且
    Ctrl+C 无法中断。
  - 修复后: sh 有控制终端,提示符/回显/ISIG 全由 pty 驱动提供,
    Ctrl+C → SIGINT 中断当前命令,shell 保持;exit/^D 正常退出。
  - 验证: python pty 驱动实测 —— 启动提示符、命令回显、sleep 30 +
    Ctrl+C → `^C` + exit 130、中断后 shell 仍活、exit 干净退出。
- **修复 su 扫描端口时被"吞 SYN 的死监听者"卡死**:阻塞式 connect()
  遇到 accept 但不应答/不响应 SYN 的残留监听者时,内核重试可挂
  数十秒(实测 48000 死监听 → 32s 后才扫到 48009)。connect 改为
  非阻塞 + 1s poll 超时,每个端口最多 1s,扫描总时间有界。
- **修复客户端断开后 proxy 阻塞 accept 循环**:客户端死亡而 child
  继续运行(如 `su -c 'sleep 30'` 被 kill)时,旧代码在 waitpid 上
  阻塞,整个 proxy 无法接受新连接。现在:
  - send_frame 失败(客户端彻底消失)立即 kill child;
  - stdin EOF 后 idle 超时兜底: 交互 10s / 非交互 60s kill 失控
    child。
  - 验证: 客户端被杀后 ~2s 内新连接正常服务。

## v3.4 (2026-08-06)
- **修复容器内 su 连不上 proxy（端口发现）**: proot 容器内通常看不到宿主路径
  `/data/data/com.termux/files/usr/tmp/magisk-proxy.port`，旧版 su 只能回退
  默认 48000；若 proxy 因端口占用落在 48000+ 其他端口（实测出现过 48123 被占、
  48124 成功），容器内 su 必然连不上。现在：
  - su 扫描 48000-48019 全端口（端口文件仅作提示，hint 优先）。
  - 每个候选端口 1 秒握手超时：残留的"接受连接但不响应"的死监听者被快速
    跳过，不再每个端口挂 5 秒（旧版会卡在死端口上报超时）。
  - service.sh 把端口文件同步到每个容器 rootfs 的 `/tmp/magisk-proxy.port`
    （容器内可见），su 直接命中正确端口。
- **修复 Bad system call (SIGSYS, rc=159)**: 二进制改用 **musl 静态编译**。
  - 根因: 静态 glibc (aarch64-linux-gnu-gcc -static, glibc 2.35) 启动时注册
    `rseq` syscall; 用户环境的 seccomp 策略 (Seccomp_filters=1, 非 app 上下文)
    白名单不含 rseq → `rseq` 触发 SIGSYS → su 启动即死, 无任何输出,
    proxy 日志无连接记录。容器内 (Seccomp_filters=2, Android 13 app 策略含
    rseq) 同二进制运行正常, 故此前排查困难。
  - 验证: 用 seccomp-bpf 模拟器 (拦 rseq) 在本机复现 rc=159; musl 版同条件下
    正常执行 (rc=0)。musl 不注册 rseq, 与任何 seccomp 策略兼容。
- **修复 su 未部署进 proot rootfs**: service.sh 之前只部署到宿主
  `files/usr/bin` 和 `files/usr/local/bin`, 容器内 `/usr/local/bin/su`
  永远是旧版 (unix socket 协议, 连不上 TCP proxy)。现在遍历
  `proot-distro/containers/*/rootfs` 部署到容器 `usr/local/bin/su`。
- **新增 proxy watchdog**: `magisk-proxy-watchdog.sh` (nohup 常驻, 由
  service.sh 启动), 每 15 秒用 `/proc/net/tcp` 检测 48000-48019 监听,
  proxy 死后自动重启。用端口检测而非 pgrep, 兼容 proxy 运行在 SELinux
  域 (magisk) 时 /proc/<pid> 不可读的情况。
- **修正 pkill/pgrep 模式**: `pkill -f "magisk-proxy"` → `pkill -x
  magisk-proxy`, 避免误杀 watchdog 自身 (命令行含 magisk-proxy-watchdog)。
- **build.sh 优先 musl-gcc**; prebuilt/ 二进制全部替换为 musl 静态版
  (约 67KB, 原 glibc 版约 603KB)。

## v3.3 (2026-08-06)
- **传输层改为 TCP loopback**,彻底绕开 proot 对 unix socket 的劫持。
  - **根因(v3.1/v3.2 挂死)**: proot 对被 bind 进容器的 unix socket 路径做虚拟挂载
    (在宿主 `usr/tmp` 创建 `proot-<pid>-XXXXXX` 临时文件并 bind 到容器路径)。
    容器内 `connect()` 到该路径实际连到 proot 的临时"死 socket"——连接成功但
    无人 accept/无响应 → su 挂死无输出,proxy 日志无连接记录。
  - **v3.2 的 su-relay 为何无效**: proot 的劫持挂载是虚拟的(只对容器内进程可见),
    宿主侧 `su-relay` 扫描 `/proc/self/mountinfo` 永远看不到 proot-* 条目,
    修补从未发生。整个 su-relay 思路建立在对 proot 机制的误判上。
  - **修复**: proxy 监听 `127.0.0.1:48000+`(service.sh 自动选可用端口,写入
    `magisk-proxy.port`),su 客户端读端口文件后连 loopback。proot 不做
    路径翻译就没有劫持;容器与宿主共享网络,loopback 直达。
- **移除 su-relay**: TCP 传输不再需要 socket 修补,su-relay 二进制不再打包/部署。
- **修复 stdin EOF 挂死**: su 客户端 stdin EOF 时未 `shutdown(SHUT_WR)`,
  proxy 侧子进程永远等不到 stdin 关闭 → `echo x | su -c cat` 挂死。
  现 EOF 时发送半关闭。
- **新文件**: `magisk-proxy.port`(proxy 实际监听端口,0644 容器可读)。

## v3.2 (2026-08-06)
- **关键修复**: su-relay 现在也监控 proxy socket 路径的 proot 劫持（不仅限于 `.magisk/device/socket`）。
  - **根因**: v3.1 的自定义 su 直接连接 proxy socket (`magisk-proxy.sock`)，但 proot 会拦截
    AF_UNIX connect() 并创建临时文件替换真实 socket。su-relay 只修补 `.magisk/device/socket` 路径，
    不处理 proxy socket 路径 → su 的连接永远到不了 proxy → 挂死无输出。
  - `find_poisoned_sources()` 现在同时匹配 `.magisk/device/socket` 和 `magisk-proxy.sock`。
  - 主循环现在处理所有被污染的 source（而非仅第一个），用 `readlink` 检查避免重复修补。
- **改进**: su 客户端增加 5 秒 poll 超时。如果 proxy 未响应（如 proot 拦截导致连接不到真实 socket），
  不再无限挂死，而是打印诊断信息并退出。
- **重构**: su-relay 移除未使用的 `fixed` 变量。

## v3.1 (2026-08-06)
- **重大重写**: 用帧协议替代 SCM_RIGHTS，彻底修复 proot 环境下 su 无法工作的问题。
- **根因**: proot 破坏 SCM_RIGHTS ancillary data 传递。su 客户端用 `read()` 而非 `recvmsg()`
  接收数据，导致只读到 iov_base payload（"F" 字节），pipe fd 丢失 → `Permission denied`。
- **新协议**:
  - 客户端 → proxy: uint32 cmd_len + cmd（无版本协商，无 su_request 解析）
  - proxy → 客户端: uint32 child_pid
  - stdout/stderr 用帧传输: uint32 length + data[length]，length=0 为结束标记
  - 结束标记后: uint32 exit_code
  - stdin 为原始字节流（无需帧封装）
- **新增 su 客户端**: 自定义 C 实现，替代 Magisk su 二进制。支持 `su`（交互 shell）和 `su -c "cmd"`。
- **修复**: SIGCHLD SIG_IGN 导致 waitpid 无法获取子进程退出码的问题。

## v2.5 (2026-08-06)
- **关键修复**: policy 响应字节数错误。Magisk su 客户端用 `read_int()` 读 4 字节 policy，
  但 proxy 写了 `uint8_t`(1 字节)，导致客户端读到 su_request 的前 3 字节，
  协议完全错位 → `failed to read su_request`。
- 修复：`uint8_t allow = 0` → `int32_t allow = 0`，write 4 字节。
- 同时修复 env var 读取失败时 `continue` 跳错循环层级的潜在死循环。

## v2.4 (2026-08-06)
- **修复**: magisk-proxy 协议解析 bug。Magisk v5 su_request 后面不是 `int32 terminator`，
  而是环境变量（len-prefixed strings, len=0 结束）。proxy 之前把 env 数据当 terminator 读，
  导致 `failed to read su_request`，su 命令卡死无输出。
- 现象：proxy 日志显示 `client version: 5` 然后 `failed to read su_request`
- 根因：协议格式理解错误，v5 的 su_request 结构是：
  uid(4) + access(4) + mode(1) + login(1) + keepenv(1)
  + shell_lp_str + cmd_lp_str
  + [env vars: lp_str... len=0 ends]
  + target_selector(4) + mount_ns(4) + nice(4)

## v2.3 (2026-08-05)
- 纯 C 架构：magisk-proxy（spawns shells directly, bypasses magiskd check-client）
  + su-relay（扫描 mountinfo 替换 proot socket 为 symlink）
- 模块刷入后自动：发现 MAGISKTMP → 等 Termux CE 解锁 → 部署二进制 → 启动 proxy + relay
- su-relay 解决 proot 劫持 magiskd socket 的问题（proot 把 unix socket 变成临时文件）

## v2.0-v2.2
- Python proxy → C proxy 迁移
- su-relay 从 Python 改为纯 C

## 架构说明
- **magisk-proxy v3.x**: 监听 proxy socket，接受 su 客户端连接，直接 fork shell (uid 0)，
  通过帧协议（uint32 length + data）传输 stdout/stderr，stdin 为原始字节流。
  完全绕过 magiskd 的 check-client 门禁。
  不使用 SCM_RIGHTS（proot 会破坏 ancillary data 传递）。
- **su v3.x**: 自定义 su 客户端，直接连接 proxy socket，使用帧协议。
  支持 `su`（交互 shell，自动 raw mode）和 `su -c "cmd"`。
- **su-relay**: 扫描 /proc/self/mountinfo 找 proot 创建的临时文件（挂载在 .magisk/device/socket），
  替换为指向 proxy socket 的 symlink。兼容其他可能使用 Magisk socket 路径的程序。
- **service.sh**: Magisk 模块启动脚本，自动发现路径、部署三个二进制（proxy + relay + su）、
  启动 proxy 和 relay，将 su 部署到 proot 容器的 /usr/local/bin/。
