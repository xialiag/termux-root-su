## v3.12.1 — 修复 v3.12 的严重回归：watchdog 根本没被启动

> **必须升级。** v3.12 的 zip 里 `service.sh` 丢失了启动 watchdog 的整段代码，
> 装上去等于**没有看门狗**，下次代理挂掉不会自愈。

### 回归根因
v3.12 重写内嵌 watchdog 时，heredoc 替换把 `chmod 755 "$WD"` 与结尾
`log "watchdog started"` 之间的全部内容吞掉了——包括 `kill_pat "magisk-proxy-wa"`
和真正拉起 watchdog 的 `setsid nohup "$WD" &`。只剩一句日志：
```sh
log "watchdog started (pid $!)"
```
两个后果：
1. **没有任何 watchdog 在跑**，自愈能力归零；
2. `$!` 是上游残留值 —— 真机上它把 **proxy 的 pid 28269** 当成 watchdog 回报，
   日志写着"已启动"而进程根本不存在，正是本次事故同一种"假成功"模式。

### 修复
- 恢复启动段；
- `setsid nohup ... &` 后的 `$!` 指向 wrapper 而非脱离后的 watchdog，
  改为 2 秒后回读 `/proc/*/comm` 匹配 `magisk-proxy-wa`（内核 15 字符截断），
  **拿到真实 pid 才记 "watchdog started"**；
- 找不到就写 `FATAL: watchdog did NOT start` 并给出恢复命令，不再无条件报成功；
- 校验 heredoc 占位符替换是否落地（未替换会让 proxy 以 `allow_uid=0`
  拒绝 Termux uid，现象是 `Connection reset`）。

### 真机验证（2026-11-14 19:31–19:36，本机实机）
```
[service] watchdog started (pid 29331)          <- 真实 watchdog pid
[watchdog] proxy process alive but not listening on abstract:termux-root-su
[watchdog] starting proxy with @termux-root-su
su -c 'id -u' => 0

# 伪造"不支持 abstract 的二进制"注入后：
[watchdog] MISMATCH: deployed proxy does not support abstract:termux-root-su; redeploying
[watchdog] redeployed binaries from /data/adb/modules/termux-root-su
su -c 'id -u' => 0
```

### 升级
Magisk 管理器刷入 `termux-root-su-v3.12.1.zip`，或宿主 Termux 执行：
```sh
/product/bin/su -c 'sh /sdcard/Download/install-v3121.sh'
```
