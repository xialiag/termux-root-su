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
#  1) 全程不用 pkill/pgrep/killall, 只用 /proc/PID/cmdline 扫描 + kill -9
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
S=/sdcard/Download/trsu-v38   # v3.9 文件源(staging)

# v3.10: reading /proc/<pid>/cmdline via shell redirection (`< file`) HANGS
# when the target is in the magisk domain (this shell also runs there); the
# kernel blocks the open. Use `cat | tr` so the reader is a killable child
# wrapped in timeout, and skip anything that won't answer in 2s.
kill_pat() {
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        _c=$(timeout 2 sh -c 'tr "\0" " " < "$1" 2>/dev/null' _ "$_d/cmdline" 2>/dev/null)
        [ -z "$_c" ] && continue
        case "$_c" in
            *"$1"*) echo "kill $_pid [$_c]"; kill -9 "$_pid" 2>/dev/null ;;
        esac
    done
}

echo "== 1) 清场: 旧代理/看门狗 =="
kill_pat "magisk-proxy "
kill_pat "magisk-proxy-watchdog.sh"
kill_pat "su-relay"
sleep 1

echo "== 2) 重部署二进制 =="
rm -f "$T/magisk-proxy" "$T/su"
cp "$S/magisk-proxy" "$T/magisk-proxy" && chmod 755 "$T/magisk-proxy" && echo "proxy ok"
cp "$S/su" "$T/su" && chmod 755 "$T/su" && echo "su ok"

echo "== 3) 同步模块 (v3.9 文件覆盖已安装模块) =="
if [ -d "$M" ]; then
    cp "$S/service.sh" "$M/service.sh" && chmod 755 "$M/service.sh" && echo "module service.sh synced"
    cp "$S/module.prop" "$M/module.prop" 2>/dev/null
    cp "$S/bashrc-snippet.sh" "$M/bashrc-snippet.sh" 2>/dev/null
else
    echo "WARN: $M 不存在(模块未安装?)"
fi

echo "== 4) 跑 service.sh (staging v3.9) =="
sh "$S/service.sh" 2>&1
echo "service rc=$?"
sleep 2
echo "== 5) 验证 =="
U=$(timeout 8 "$T/su" -c 'id -u' 2>&1)
echo "su -c id -u => [$U]"
echo "port file: $(cat $T/magisk-proxy.port 2>/dev/null)"
echo "== done $(date) =="
