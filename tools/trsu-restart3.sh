#!/system/bin/sh
# termux-root-su v3.10 一次性恢复脚本(宿主机 root 执行)
#
# 背景(2026-11-06 事故): 旧 restart 脚本经 su -c 执行时, 脚本自身的清场
# pkill 命中了 父 su / 父 proxy 的 cmdline, 把自己连坐杀死(rc=143),
# service.sh 跑到一半夭折; 之后又用 killall magisk-proxy 诊断, Termux 的
# killall 前缀匹配到 comm="magisk-proxy-wa"(watchdog), 代理+看门狗全灭.
#
# v3.10(2026-11-08): kill_pat 原来用 shell 重定向 `< /proc/<pid>/cmdline`
# 读命令名; 目标是 magisk 域进程时内核阻塞 open(), 函数永久挂住 —— watchdog
# 每 15s 调一次, 卡死后自身死掉, 代理无人重启即全灭。现改为 timeout 子进程
# 读取, 卡住即跳过。staging 目录名沿用 trsu-v38 以匹配现有部署。
#
# 本脚本规则:
#  1) 全程不用 pkill/pgrep/killall, 用 /proc/PID/comm 扫描 + kill -9(comm 不阻塞;cmdline 的 open 在 magisk 域会卡)
#  2) 绝不匹配可能命中自身祖先的宽模式: 代理模式带尾空格 "magisk-proxy <port>"
#  3) 开头 setsid 自脱离, 调用方 su -c 立即返回, 之后杀任何进程都不连坐
#
# 用法(宿主 Termux, 一条命令):
#   env -u LD_PRELOAD /product/bin/su -c 'setsid sh /sdcard/Download/trsu-restart3.sh </dev/null >/dev/null 2>&1 &'
# 进度看: cat /sdcard/Download/trsu-fix.log

LOG=/sdcard/Download/trsu-fix.log
exec >>"$LOG" 2>&1
echo "===== restart3 $(date) pid=$$ ====="

# 自脱离: 若调用方没有先 setsid, 这里自己再来一次
if [ -z "$TRSU_REENTER" ]; then
    if command -v setsid >/dev/null 2>&1; then
        TRSU_REENTER=1 setsid sh "$0" </dev/null >/dev/null 2>&1 &
        exit 0
    fi
fi

T=/data/data/com.termux/files/usr/tmp
M=/data/adb/modules/termux-root-su
# v3.10: pick the source of truth in this order:
#   1. $TRSU_SRC (explicit override, e.g. an updated staging dir)
#   2. a complete staging dir under /sdcard/Download (trsu-v310 / trsu-v38) —
#      used when you have a freshly-built set to apply without re-flashing
#   3. the INSTALLED MODULE dir (what Magisk last flashed)
# Previously this hard-coded the stale /sdcard/Download/trsu-v38 (v3.9): on a
# fresh device it is missing, and here it would have written v3.9 files back.
S=""
if [ -n "$TRSU_SRC" ] && [ -f "$TRSU_SRC/magisk-proxy" ] && [ -f "$TRSU_SRC/service.sh" ]; then
    S="$TRSU_SRC"
fi
if [ -z "$S" ]; then
    for cand in /sdcard/Download/trsu-v310 /sdcard/Download/trsu-v38; do
        [ -f "$cand/magisk-proxy" ] && [ -f "$cand/service.sh" ] && { S="$cand"; break; }
    done
fi
if [ -z "$S" ] && [ -f "$M/magisk-proxy" ] && [ -f "$M/service.sh" ]; then
    S="$M"
fi
if [ -z "$S" ]; then
    echo "FATAL: 找不到模块源目录(TRSU_SRC / staging / $M)；请先重刷模块 zip"
    exit 1
fi
echo "源目录: $S"

# v3.10: read /proc/<pid>/comm (15-char task name, never blocks), NOT cmdline
# — cmdline's open() blocks for magisk-domain targets and made this scan take
# minutes. Exact-comm variant separates the proxy (comm "magisk-proxy") from
# the watchdog (comm "magisk-proxy-wa", which contains "magisk-proxy").
kill_pat() {
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        { read -r _c < "$_d/comm"; } 2>/dev/null || continue
        [ -z "$_c" ] && continue
        case "$_c" in
            *"$1"*) echo "kill $_pid [$_c]"; kill -9 "$_pid" 2>/dev/null ;;
        esac
    done
}
kill_comm_eq() {
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        { read -r _c < "$_d/comm"; } 2>/dev/null || continue
        [ "$_c" = "$1" ] && { echo "kill $_pid [$_c]"; kill -9 "$_pid" 2>/dev/null; }
    done
}

echo "== 1) 清场: 旧代理/看门狗 =="
kill_comm_eq "magisk-proxy"
kill_pat "magisk-proxy-wa"
kill_pat "su-relay"
sleep 1

echo "== 2) 重部署二进制到 $T =="
rm -f "$T/magisk-proxy" "$T/su"
cp "$S/magisk-proxy" "$T/magisk-proxy" && chmod 755 "$T/magisk-proxy" && echo "proxy ok"
cp "$S/su" "$T/su" && chmod 755 "$T/su" && echo "su ok"

echo "== 3) 跑 service.sh ($S 权威源, 重新部署 su 到容器 + 起 proxy/watchdog) =="
sh "$S/service.sh" 2>&1
echo "service rc=$?"
sleep 3
echo "== 4) 验证 =="
U=$(timeout 10 "$T/su" -c 'id -u' 2>&1)
echo "su -c id -u => [$U]"
echo "port file: $(cat "$T/magisk-proxy.port" 2>/dev/null)"
if [ "$U" = "0" ]; then
    echo "OK: root 代理已恢复"
else
    echo "WARN: su 未返回 0, 看 $T/magisk-proxy.log 与 /sdcard/Download/trsu-boot.log"
fi
echo "== done $(date) =="
