## v3.12 — watchdog 自愈传输/二进制版本错配

### 现象
容器内 `su -c id` 报 `Cannot connect to daemon (127.0.0.1:48000-48019)`，
`/sdcard/Download/trsu-boot.log` 里 **1515 条** `port open but not root (id -u=),
killing fake` → `proxy down, restarting on 48000`，su 自 11-11 起静默失效三天，
没有任何一条日志点出真正原因。

### 根因（三条缺陷叠加）
1. **部署与标记错配**：`service.sh` v3.10 把 `abstract:termux-root-su` 写进
   `magisk-proxy.port`，但机器上实际跑的仍是 v3.9 的 TCP-only 二进制 ——
   它永远绑不上抽象名。
2. **watchdog 判活太弱**：只认「有 comm=`magisk-proxy` 的进程」+「`su -c id -u`
   返回 0」。v3.9 客户端连不上抽象 socket，探测输出恒空；而空输出被当作
   doze 瞬态「放过不杀」→ 既不杀也不启 → 空转 1515 轮。
3. **空探测无诊断价值**：「代理忙」和「代理是另一个传输层版本」无法区分。

### 修复
- **`magisk-proxy --probe`**：新增探针模式，直接 `bind()` 判定目标传输是否
  已被占用（`EADDRINUSE` = 有人监听），**不读 `/proc/net`** —— Android 对
  非 root 拒绝 `/proc/net/unix`，表格法会静默误报「无人监听」并造成重复
  spawn 全部 `Address in use`。支持 `@name` / `abstract:name` / `tcp:PORT` /
  裸端口。
- **二进制/传输自检**：watchdog 每轮比对 `PORT_FILE` 标记与部署的二进制是否
  真的支持该传输（检查 `.text` 内的启动日志串）；不匹配立即从 `$MODDIR`
  重新部署并重启，不再重复重启同一对错配组合。
- **探测连续失败熔断**：连续 4 次身份探测为空时，先原地重放 `service.sh`
  （与开机同一代码路径，把 marker、二进制、监听三者对齐），重放成功则自退；
  仍失败则打印明确 FATAL 与恢复命令，而不是无限空转。
- `start_proxy` 改为逐参数引号传递（原来 `setsid $_raw &` 依赖分词），并把
  真实 magiskd socket 作为 argv[3] 传出；`MODDIR` 绝对化。
- `boot-completed.sh` 给 `service.sh` 重放加 `timeout 420` 上限。
- `su`：对 `TRSU_SOCK` 长度做边界检查后再写入 `sun_path[108]`。

### 验证
本地沙箱用**真实 v3.9 二进制**复现错配：日志
`MISMATCH: deployed proxy does not support abstract:termux-root-su` →
自动重部署 → 单次启动 → `su -c 'id -u'` = `0`。
另测：正常态完全静默、marker 缺失自恢复、TCP legacy 传输可用；
relay 数据完整性 500KB/1MB `cat` 逐字节一致，退出码 / stderr 分流 /
8 路并发 / SIGPIPE / 交互 pty 全部通过。

### 升级
Magisk 管理器刷入 `termux-root-su-v3.12.zip`，或宿主 Termux 执行：
```sh
/product/bin/su -c 'sh /sdcard/Download/install-v312.sh'
```
