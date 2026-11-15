#!/system/bin/sh
# termux-root-su v3.12.2 一键修复(宿主 Termux root 执行)
#
# 用法(宿主原生 Termux, 不是 proot):
#   env -u LD_PRELOAD -u LD_LIBRARY_PATH /product/bin/su -c \
#     'setsid sh /sdcard/Download/trsu-fix-v3122.sh </dev/null >/dev/null 2>&1 &'
# 进度: cat /sdcard/Download/trsu-fix.log
#
# 规则(沿袭 trsu-restart3):
#  1) 不用 pkill/pgrep/killall, 只扫 /proc/*/comm (cmdline 在 magisk 域会阻塞)
#  2) 开头 setsid 自脱离, 杀进程不连坐
#  3) 绝不用"文件存在"推断"进程活着", 一律功能验收

LOG=/sdcard/Download/trsu-fix.log
exec >>"$LOG" 2>&1
echo "===== fix-v3122 $(date) pid=$$ ====="

if [ -z "$TRSU_REENTER" ]; then
    if command -v setsid >/dev/null 2>&1; then
        TRSU_REENTER=1 setsid sh "$0" </dev/null >/dev/null 2>&1 &
        exit 0
    fi
fi

M=/data/adb/modules/termux-root-su
S=/sdcard/Download/trsu-v3122
T=/data/data/com.termux/files/usr/tmp

echo "== 0) 宿主侧取证 =="
echo "boot_id: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
echo "module dir: $(ls "$M" 2>&1 | head -3 | tr '\n' ' ')"
echo "module version: $(grep ^version "$M/module.prop" 2>/dev/null)"
for f in /data/local/tmp/termux-root-su.log; do
    [ -f "$f" ] && { echo "--- $f tail ---"; tail -15 "$f"; }
done

kill_pat() {
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        { read -r _c < "$_d/comm"; } 2>/dev/null || continue
        [ -z "$_c" ] && continue
        case "$_c" in *"$1"*) echo "kill $_pid [$_c]"; kill -9 "$_pid" 2>/dev/null ;; esac
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

echo "== 1) 清场 =="
kill_comm_eq "magisk-proxy"
kill_pat "magisk-proxy-wa"
kill_pat "magisk-proxy-pa"
kill_pat "su-relay"
sleep 1

echo "== 2) 同步模块目录 <- $S =="
if [ -d "$M" ]; then
    cp "$S/service.sh" "$S/module.prop" "$S/boot-completed.sh" "$M/" && chmod 755 "$M/service.sh" "$M/boot-completed.sh" && echo "module scripts synced"
    cp "$S/magisk-proxy" "$S/su" "$M/" && chmod 755 "$M/magisk-proxy" "$M/su" && echo "module binaries synced"
    grep ^version "$M/module.prop"
else
    echo "WARN: $M 不可见/不存在 —— 模块可能未安装, 仅部署运行时"
fi

echo "== 3) 部署运行时到 $T =="
rm -f "$T/magisk-proxy" "$T/su"
cp "$S/magisk-proxy" "$T/magisk-proxy" && chmod 755 "$T/magisk-proxy" && echo "proxy ok"
cp "$S/su" "$T/su" && chmod 755 "$T/su" && echo "su ok"

echo "== 4) 跑 v3.12.2 service.sh =="
sh "$S/service.sh" 2>&1
echo "service rc=$?"
sleep 3

echo "== 4.5) 宿主 bash.bashrc 自动恢复防线 =="
HOSTRC=/data/data/com.termux/files/usr/etc/bash.bashrc
if [ -f "$HOSTRC" ]; then
    sed -i '/# ===== termux-root-su v3/,/# ===== end termux-root-su =====/d' "$HOSTRC" 2>/dev/null
    sed -i '/# ===== end termux-root-su =====/d' "$HOSTRC" 2>/dev/null
    cat "$S/bashrc-snippet.sh" >> "$HOSTRC"
    echo "host bashrc snippet deployed"
else
    echo "WARN: $HOSTRC missing"
fi

echo "== 5) 验收(功能, 非文件) =="
U=$(timeout 10 "$T/su" -c 'id -u' 2>&1)
echo "su -c id -u => [$U]"
echo "port file: $(cat "$T/magisk-proxy.port" 2>/dev/null)"
for d in /proc/[0-9]*; do
    { read -r c < "$d/comm"; } 2>/dev/null || continue
    case "$c" in magisk-proxy*) echo "live: pid=${d#/proc/} comm=$c" ;; esac
done
if [ "$U" = "0" ]; then
    echo "OK: v3.12.2 installed, root proxy healthy"
else
    echo "WARN: su 未返回 0; 看 $T/magisk-proxy.log 与 /sdcard/Download/trsu-boot.log"
fi
echo "== done $(date) =="
