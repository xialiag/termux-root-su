# ===== termux-root-su v3.12.2: probe + auto-recover (host bashrc) =====
# v3.10: probe only, no auto-spawn — a container-spawned proxy runs as the
#        Termux uid (fake root) and squats the transport.
# v3.12.2: the 2026-11-15 03:18 incident killed proxy+watchdog+patrol in the
#        magisk domain overnight with zero logs. A process can't guard itself
#        against whatever killed them, so recovery must hang off an action
#        the user ALWAYS performs when su is broken: opening Termux.
#        This snippet probes the transport and, if dead, replays service.sh
#        VIA MagiskSU (/product/bin/su -> magiskd -> magisk domain), which
#        redoes deploy + proxy + watchdog + patrol + CE waiter in one shot.
# Debounce: one attempt per 10 minutes, marker in Termux tmp (cleared on
# reboot — exactly when a fresh attempt is wanted).
_snip_marker="termux-root-su v3.12.2"
if ! timeout 3 su -c 'true' >/dev/null 2>&1; then
    _trsu_debounce="$TERMUX_TMP/.trsu-recover-last"
    _now=$(date +%s 2>/dev/null || echo 0)
    _last=0
    [ -f "$_trsu_debounce" ] && _last=$(cat "$_trsu_debounce" 2>/dev/null || echo 0)
    if [ "$((_now - _last))" -ge 600 ] 2>/dev/null; then
        echo "$_now" > "$_trsu_debounce" 2>/dev/null
        echo "[termux-root-su] root 代理未运行, 自动恢复中(经 MagiskSU 重放 service.sh)..."
        env -u LD_PRELOAD -u LD_LIBRARY_PATH /product/bin/su -c \
            'setsid nohup sh /data/adb/modules/termux-root-su/service.sh </dev/null >/dev/null 2>&1 &' \
            >/dev/null 2>&1
        echo "[termux-root-su] 恢复已触发, 约 5 秒后可用; 进度: cat /sdcard/Download/trsu-boot.log"
    fi
    unset _trsu_debounce _now _last
fi
unset _snip_marker
# ===== end termux-root-su =====
