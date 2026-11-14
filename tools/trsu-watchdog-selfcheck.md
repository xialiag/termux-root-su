# watchdog 自检速查（v3.12+）

## 1. 看 watchdog 到底在做什么

```sh
tail -50 /sdcard/Download/trsu-boot.log     # 容器内可读，无需 root
```

正常态下 **watchdog 不写任何日志**。出现以下行即表示自愈动作：

| 日志行 | 含义 | 下一步 |
|---|---|---|
| `MISMATCH: deployed proxy does not support <transport>` | 部署的二进制与 `magisk-proxy.port` 记录不一致 | 已在自动重部署，等待 15s 后确认 |
| `redeployed binaries from <moddir>` | 已从模块目录覆盖二进制 | 检查是否 `su -c 'id -u'` == 0 |
| `proxy process alive but not listening on <transport>` | 进程在但没绑上 | 自动 kill + 重启 |
| `identity probe empty (streak=n/4, transport=...)` | 探测无输出 | n 到 4 会触发重放 service.sh |
| `FATAL: root proxy not answering after replay` | 自动手段用尽 | 宿主 root 执行 `sh /sdcard/Download/fix-root-now5.sh` |

## 2. 手动核对 marker 与二进制是否匹配

```sh
cat /data/data/com.termux/files/usr/tmp/magisk-proxy.port
# abstract:termux-root-su  -> 二进制必须含 "abstract=@"
# 48000                    -> 二进制必须含 "tcp=127.0.0.1"
grep -c 'abstract=@' /data/data/com.termux/files/usr/tmp/magisk-proxy
```

## 3. 用探针判断是否真的在监听（不读 /proc/net）

```sh
M=/data/data/com.termux/files/usr/tmp/magisk-proxy
$M --probe abstract:termux-root-su ; echo $?   # 0=在监听 1=无人 2=参数错
$M --probe tcp:48000              ; echo $?
```

## 4. 为什么不能再信 /proc/net/unix

Android 对非 root 常返回 `Permission denied`。早期按表格 grep 判定「无人监听」，
于是重复 spawn 代理，全部 `bind: Address in use` 立即死掉，看门狗每 15s 重试，
表现为 su 长时间不可用而不是报错。
