# CHANGELOG

## v3.12.1 (2026-11-14)

#### 现象与根因：watchdog 版本错配死循环（su 静默死亡 3 天）
现象：容器内 `su -c id` 报 `Cannot connect to daemon (127.0.0.1:48000-48019)`，
`trsu-boot.log` 里 1515 条 `port open but not root (id -u=), killing fake` →
`proxy down, restarting on 48000`，su 从 2026-11-11 起全程不可用而无人察觉。

根因链（三条独立缺陷叠加）：
1. **部署/标记错配**。`service.sh` v3.10 把 `abstract:termux-root-su` 写入
   `magisk-proxy.port`，但机器上实际部署的是 v3.9 TCP-only 二进制——它按
   numeric 端口起监听，抽象名永远绑不上，日志只见 `tcp=127.0.0.1:48000`。
2. **watchdog 只看进程名 + 身份探测**。存活判据是「有 comm=`magisk-proxy`
   的进程」+「`su -c 'id -u'` 返回 0」。旧 TCP 客户端连不上抽象 marker，
   探测输出**恒为空**；而空输出按 v3.8 设计被当作 doze 瞬态「放过不杀」，
   于是既不杀也不启，循环空转。
3. **探测空 = 无信息**。原逻辑无法区分「代理忙/系统冻结」与「代理根本是
   另一个传输层版本」，所以 3 天里没有任何一条日志说明真正原因。

#### 修复（`service.sh` 内嵌 watchdog 重写为 v3.12）
- **【严重回归修复】watchdog 根本没被启动**。改 heredoc 时误删了
  `chmod 755 "$WD"` 之后的整段启动代码（`kill_pat` 旧 watchdog +
  `setsid nohup "$WD"`），只剩一句 `log "watchdog started (pid $!)"`。
  后果：日志声称「已启动」而实际没有任何 watchdog，`$!` 报的还是上游
  残留 pid（实测把 **proxy 的 pid 28269** 当成 watchdog 回报），自愈
  能力归零——正是本次事故的同一失败模式再次出现。
  修复要点：① 恢复启动段；② `$!` 在 `setsid nohup ... &` 后指向 wrapper
  而非脱离后的真 watchdog，改为 2 秒后回读 `/proc/*/comm` 找
  `magisk-proxy-wa`（15 字符截断），拿到真实 pid 才记 "watchdog started"；
  ③ 找不到就写 `FATAL: watchdog did NOT start` 并给恢复命令，不再无条件
  报成功；④ 顺带校验 heredoc 占位符替换是否成功（未替换会让 proxy 以
  `allow_uid=0` 拒绝 Termux uid，表现为 `Connection reset`）。
  **真机验证**（2026-11-14 19:31）：`watchdog started (pid 20837)` 为真实
  watchdog；`kill -9` 掉 proxy 后 18 秒内日志出现
  `proxy process alive but not listening` → `starting proxy with
  @termux-root-su`，`su -c 'id -u'` 恢复 `0`。
- **`magisk-proxy --probe <transport>`**：新增探针模式，直接 `bind()` 判定
  目标传输是否已被占用（`EADDRINUSE` = 在监听），**不读 `/proc/net`**——
  Android 常对非 root 拒绝 `/proc/net/unix`，表格法会静默误报「无人监听」
  并导致重复 spawn → 全部 `Address in use` 死掉。支持 `@name` /
  `abstract:name` / `tcp:PORT` / 裸端口四种写法。
- **二进制/传输自检**：watchdog 每轮比较 `PORT_FILE` 里的 marker 与部署的
  proxy 二进制是否真的支持该传输（在 .text 里找启动日志串
  `abstract=@` / `tcp=127.0.0.1`）；不匹配立刻从 `$MODDIR` 重新部署并重启，
  不再重复重启同一对错配组合。
- **探测连续失败熔断**：连续 `PROBE_FAILS_MAX`(4) 次身份探测为空时，先原地
  重放 `service.sh`（与开机同一代码路径，会把 marker、二进制、监听三者对齐），
  重放后仍失败则打印明确 FATAL（含推荐恢复命令）而不是继续空转。
- **watchdog 重放 service.sh 后自退**：`service.sh` 会清掉旧 watchdog 并
  起新的，自退避免「多个 watchdog 争抢代理」（v3.9 曾出现 4 个 proxy 抢
  48000-48003）。
- **`start_proxy` 参数传递修正**：原 `setsid $_raw &` 依赖 shell 分词，路径
  含空格会错位；改为逐参数引号传递，并把真实 magiskd socket 作为 argv[3]
  传出（proxy 不强依赖，但日志诊断更诚实）。
- **`service.sh` 的 `MODDIR` 转为绝对路径**（相对调用时重部署会失败）。
- **`boot-completed.sh`**：健康/成功日志改用 `transport=` 而非 `port=`，
  避免 abstract 模式打印空端口。

验证（本地沙箱，`/tmp/wdtest`，真实 v3.9 二进制 + v3.12 模块目录）：
- 错配场景：日志 `MISMATCH: deployed proxy does not support
  abstract:termux-root-su ... redeploying` → 二进制覆盖 → 起代理一次成功，
  `su -c 'id -u'` 返回 `0`。
- 正常态：watchdog 完全静默（0 行写入），无重启。
- marker 缺失：自动推断 `abstract:termux-root-su` 并恢复。
- TCP legacy 传输：按 marker 启动 `tcp=127.0.0.1:PORT` 正常服务。
- 大输出：500KB / 1MB `cat` 逐字节对拍（md5 + cmp）一致；exit code、
  stderr 分流、8 路并发、`head -c` 触发 SIGPIPE、交互 pty 全部通过。

## v3.10 (2026-11-08)
- **安全：消除本地提权面（高危）**。原来 proxy 监听 `127.0.0.1:48000`，TCP
  无法识别对端，**设备上任意 app 都能连上并执行任意 root 命令**（日志/实测
  均证实：容器内普通 Termux uid 连 48000 即得 `id -u=0`）。
  - 传输层改为 **AF_UNIX 抽象命名空间 socket**（`@termux-root-su`）。proot
    只劫持文件系统 socket 路径，不劫持抽象名，故容器内可达（已实测跨边界
    连通）。抽象 socket 可用 `SO_PEERCRED` 拿到对端**真实 uid/pid**。
  - proxy 校验 `cred.uid == 0 || cred.uid == Termux uid`，其余一律
    `REJECT` 并断开；service.sh 把 Termux uid 作为 argv[4] 传入（proxy 在
    magisk 域`getuid()==0`，不能自推）。watchdog 重启时也带同一 uid。
  - su 客户端优先连抽象 socket，失败才回退 TCP 扫描（兼容老 ROM）。
  - 实测：TCP 48000 不再 LISTEN，容器连 TCP 直接 ConnectionRefused；抽象
    socket 上 Termux uid 放行、错误 uid 被拒（日志
    `accept peer uid=10279` / `REJECT peer uid=...`）——**具备来源审计**。
  - 附：文件系统 unix socket 分支的 chmod 从 0666 收紧为 0600。
- **修复大输出被静默截断（数据完整性，严重）**。`su -c 'cat bigfile'` 只拿到
  16-28KB 就结束（500KB 文件 md5 不符）。两个独立根因：
  - **proxy（src/magisk-proxy.c）**：relay 循环用 `waitpid(child, WNOHANG)`
    一检测到子进程退出就 `break`，丢弃 pipe 里**尚未读出的** stdout/stderr。
    快速命令（`cat`）瞬间写满 64K 管道后退出，handler 来不及 drain，尾部丢失。
    修复：子进程退出只记录 exit_code 不 break；非交互模式继续 drain 两个 pipe
    直到 EOF（read 返回 0）；交互模式先一次性非阻塞 drain pty master（设
    `O_NONBLOCK`，遇 EAGAIN 停）再收尾，避免后台占 slave 时阻塞。补 `#include
    <fcntl.h>`。
  - **su（src/su.c）**：`write(STDOUT_FILENO, buf, n)` 的返回值被 `(void)`
    丢弃。信号打断（Ctrl+C/SIGWINCH）或慢管道时 write 返回短写，尾部字节被
    丢。新增 `xxwrite()`（EINTR 重试 + 循环写满），用于 stdout 与 stdin→sock
    两处。同时修 stdin 分支把 `read()==EINTR` 误当 EOF 而提前 `shutdown` 的
    老 bug，`xxread` 也加 EINTR 重试，end-marker 的 exit_code 读取失败时回落
    为 1。
- **修复 watchdog 自杀**（根因：`kill_pat` 读 `/proc/<pid>/cmdline` 时内核
  阻塞 open）。现象：代理+看门狗在某时刻后一起消失，`su -c 'id -u'` 报
  `Cannot connect ... 48000-48019`，只能手动跑恢复脚本救回。
  - 根因：watchdog 每 15s 调用一次 `kill_pat`，函数用 shell 重定向
    `< /proc/<pid>/cmdline` 读命令名。当目标进程在 **magisk 域**（执行
    shell 自己也在 magisk 域）时，内核会**阻塞 open()**，函数永久挂住 →
    watchdog 卡死 → 代理死后无人在 15s 内重启 → 全灭。
  - 修复：3 处 `kill_pat` 改为读取 `/proc/<pid>/comm`（15 字符任务名，永不
    阻塞），彻底不再碰会阻塞的 `cmdline`。分两个函数：`kill_comm_eq`（精确
    comm 匹配，用于 kill proxy「magisk-proxy」而不误杀 watchdog
    「magisk-proxy-wa」，后者是前者的子串）与 `kill_pat`（子串匹配）。
    用 shell 内建 `read` 读 comm，**零 fork**：一次全 /proc 扫描从原来的
    ~14 秒（逐 pid `timeout 2 cat`）降到 ~85ms。这正是「恢复要等几分钟」
    的根因——kill_pat 在 service.sh 里被调用多次、watchdog 每 15s 调一次。
  - 实测：service.sh 全流程 3 秒、restart3（含部署+重启）8 秒、单实例
    （1 listener + 1 watchdog）。
- **脚本稳健性（审查发现）**：
  - `service.sh` bashrc 片段删除加了护栏：只有 start+end 两个 marker 都在时
    才做区间删除，否则 `sed` 会从 start 删到 EOF，摧毁用户 .bashrc 其余内容。
  - `service.sh` 起 proxy 与 watchdog 重启 proxy 均改用 `setsid`（可用时）
    脱离 service.sh 会话，避免随其退出收 SIGHUP。
  - watchdog heredoc 的 `REAL_SOCK` 由硬编码 `/debug_ramdisk` 改为按
    `magisk --path` / `/sbin` 探测，与 service.sh 一致。
  - `tools/trsu-restart3.sh` 源目录改为 `$TRSU_SRC` > staging(trsu-v310/v38) >
    `/data/adb/modules/termux-root-su`，不再硬编码已过期的 `trsu-v38`（新设备
    不存在、旧设备会把 v3.9 写回模块）；验证段按 `id -u == 0` 给出 OK/WARN。
  - `build.sh` 打包 `tools/trsu-restart3.sh` 与 `CHANGELOG.md`；`update-binary`
    版本串升 v3.10 并 chmod tools 脚本。
- **prebuilt 重新构建并对拍**：验证 `prebuilt/` 就是 `src/` 的 musl 静态构建
  （旧 `su`/`magisk-proxy` 与 src 编译产物 md5 逐字节一致），本版按同一流程
  重建两枚二进制。真机回归：`su -c` 大输出 500KB 完整、退出码透传、stdin
  管道、stderr 分离、interactive pty 提示/回显/退出均正常。
- 排障附录（本次实测确认的非显性事实）：
  - 容器内 `/proc/uptime` 是 **proot 伪造的静态值**，不能据此判断"设备刚
    重启"。
  - `su` 客户端报 `EINPROGRESS (os error 115)` 是误导表象；Python 直连
    48000 才见真 `ECONNREFUSED(111)`＝端口确无人监听。
  - 代理日志时间戳是 **UTC**（magisk 域 TZ），比容器 CST 慢 8 小时，非异常。
  - 并发跑两个 `restart3.sh` 会互相覆盖脚本文件，导致
    `Syntax error ")" unexpected`；必须单跑。

## v3.9 (2026-11-07)
- **彻底移除 pkill/pgrep/killall**（本 MIUI ROM 上三者均不可靠，曾导致
  代理+看门狗全灭且无人拉起）:
  - toybox `pkill -x magisk-proxy` 返回 rc=1 且什么都不杀（僵尸代理长期
    占 48000-48003 即其遗留）；
  - Termux `killall magisk-proxy` 按截断 comm **前缀匹配**，连带杀掉
    comm="magisk-proxy-wa" 的 watchdog → 代理死后无人重启；
  - 经 `su -c` 执行修复脚本时宽匹配 pkill 命中调用方自身 cmdline →
    脚本被连坐(rc=143)，service.sh 半途夭折。
  - 正解: `kill_pat()` 扫 /proc/PID/cmdline + kill -9（跳过 $$），代理
    匹配串带尾空格 `"magisk-proxy "` 以区分 watchdog 脚本。
- **端口分配改为启动后确认**: 起 proxy 后轮询日志最多 3s 等待
  `tcp=127.0.0.1:<port>` 出现，成功即 break，失败才 kill_pat 换下一端口
  （替代坏掉的 pkill 抢占式清端口）。

## v3.8 (2026-11-05)
- **修复"重启后 su 永远不可用"**。双重根因:
  - (a) service.sh 的 CE 解锁等待只有 120s。本 ROM 的 late_start 远早于
    用户首次解锁，超时 exit 1 → su 部署和 proxy 启动整段静默跳过。→ 240s。
  - (b) boot-completed.sh 只要 watchdog **脚本文件**存在就 exit 0。但
    watchdog 进程不跨重启，文件还在 → 开机自检恒过，谁都不起 proxy →
    重启多少次都不行。→ 改为: 等 CE 解锁(最长 15min) → 无条件跑
    service.sh → 用 `su -c 'id -u' == 0` 按身份验收，绝不按文件存在推断
    进程状态。
- **日志双写 /sdcard/Download/trsu-boot.log**: proot 绑定了 /sdcard，
  容器内 agent 免 root 即可看开机证据。

## v3.7 (2026-11-01)
- **bashrc 改纯探测**（修复容器内假 root 占端口）: 容器内自起的 proxy 以
  Termux uid(fake root) 运行并抢占 TCP 端口，宿主 watchdog 按身份验收会
  杀掉它，期间容器内 su 拿到的却是假 root。snippet 现在只探测并提示去
  宿主执行恢复命令，不再容器内自举。

## v3.6 (2026-08-06)
- **修复 proxy 单连接串行缺陷**: 旧 accept 循环一次只处理一个连接——一个
  会话(如交互 shell 的 pty master 迟迟不产生 EIO,或客户端半断开)卡住
  relay 循环后,所有后续 su 请求全部排队,connect 成功但永远收不到
  child_pid,表现为 "Cannot connect to daemon: Operation in progress"。
  现在每个连接 fork 独立 handler 进程,监听器永不阻塞;父进程 SIGCHLD
  收割,handler 内恢复 SIG_DFL 自行 waitpid shell。
  - 实测: 挂死交互会话占住一个 handler 时,并发 `su -c` 0.03s 完成。
- **修复交互 shell 退出后连接不释放**: shell exit 后若 pty master 因后台
  作业持有 slave 而不产生 EIO,旧 relay 循环永远 poll 等待,连接永久挂起。
  relay 循环现在每次 poll 返回后 `waitpid(child, WNOHANG)` 检测 shell
  是否已退出,已退出则立即结束会话、发送 exit_code,释放连接。
- **bashrc 自愈(部署在容器 /root/.bashrc)**: 旧检查检测 unix socket
  文件 `magisk-proxy.sock`(v2 时代遗留),v3.x TCP 架构下恒假 → 每次
  新会话误报 "proxy 没跑" 且提示指向已删除的 fix-proxy2.sh。现在:
  - 用 `su -c 'true'` 实测探测(proxy 活着时 hint 端口直达,毫秒级);
  - proxy 未运行则自动在容器内拉起(`nohup magisk-proxy <port> &`),
    利用 proot 与宿主共享网络栈,监听 127.0.0.1 立即可用;
  - 拉起失败才提示用户去宿主 Termux 跑 watchdog。
  - 实测: 杀 proxy 后交互加载 bashrc → 自动启动 + su 恢复可用。

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
