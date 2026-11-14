#!/system/bin/sh
# termux-root-su v3.11 boot-completed.sh
# Second-chance supervisor: run service.sh once CE storage is actually
# unlocked, then verify a ROOT proxy is listening.
#
# Why this exists (the reboot bug, 2026-11-05):
#   On this ROM Magisk fires service.sh in late_start LONG BEFORE the user
#   unlocks the device. service.sh waits for Termux CE data, times out
#   (120s was too short), exits 1 — so su was never deployed and no proxy
#   was ever started. Then boot-completed.sh ran and, because the watchdog
#   *script file* still existed from the previous boot, it concluded
#   "watchdog will restart it" and exited 0. The watchdog process does not
#   survive reboots; only its script file does. Net effect: every reboot
#   left su dead, and rebooting again changed nothing.
#
# v3.8 contract:
#   - Wait for CE unlock up to 15 min (cheap polling, no work while locked).
#   - Run service.sh (idempotent) instead of guessing about process state.
#   - Verify by identity (`su -c 'id -u'` == 0), never by file existence.
#   - Log to BOTH /data/local/tmp (host) and /sdcard/Download (readable by
#     the proot container without root) so failures are diagnosable from
#     inside the container.

MODDIR="${0%/*}"
LOG="/data/local/tmp/termux-root-su.log"
SDLOG="/sdcard/Download/trsu-boot.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [boot-completed] $*" >> "$LOG" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') [boot-completed] $*" >> "$SDLOG" 2>/dev/null
}

log "=== boot-completed v3.11 start ==="

# --- Wait for CE unlock (Termux data becomes readable only after unlock) ---
TERMUX_DATA=""
for i in $(seq 1 180); do
    for d in /data/data/com.termux /data/user/0/com.termux; do
        [ -d "$d/files/usr/bin" ] && TERMUX_DATA="$d" && break
    done
    [ -n "$TERMUX_DATA" ] && break
    [ $((i % 20)) -eq 0 ] && log "CE still locked ($((i * 5))s elapsed)"
    sleep 5
done
if [ -z "$TERMUX_DATA" ]; then
    log "FATAL: CE still locked after 15min; nothing to do this boot"
    exit 0
fi

TERMUX_TMP="$TERMUX_DATA/files/usr/tmp"
SU_BIN="$TERMUX_TMP/su"
PORT_FILE="$TERMUX_TMP/magisk-proxy.port"
log "CE unlocked, Termux=$TERMUX_DATA"

# --- Already healthy? Verify by identity, not by file presence ---
verify_root() {
    [ -x "$SU_BIN" ] || return 1
    OUT=$(timeout 8 "$SU_BIN" -c 'id -u' 2>/dev/null)
    [ "$OUT" = "0" ]
}

if verify_root; then
    log "root proxy already healthy (transport=$(cat "$PORT_FILE" 2>/dev/null))"
    exit 0
fi

log "no working root proxy; running service.sh"
if [ -f "$MODDIR/service.sh" ]; then
    # Bound the replay: service.sh waits up to 240s for CE unlock plus proxy
    # startup. An unbounded call here would hold boot-completed open forever
    # if it wedged, and the watchdog would then never be spawned by anyone.
    timeout 420 sh "$MODDIR/service.sh" >> "$LOG" 2>/dev/null
else
    log "FATAL: $MODDIR/service.sh missing — module not installed"
    exit 1
fi

# --- Verify (service.sh started a proxy + watchdog; give it a moment) ---
ok=0
for i in 1 2 3 4 5 6; do
    sleep 5
    verify_root && { ok=1; break; }
done
if [ "$ok" = 1 ]; then
    log "OK: root proxy serving su (transport=$(cat "$PORT_FILE" 2>/dev/null))"
else
    log "FAILED: su still not returning uid 0 after service.sh"
    tail -5 "$TERMUX_TMP/magisk-proxy.log" >> "$LOG" 2>/dev/null
    tail -5 "$TERMUX_TMP/magisk-proxy.log" >> "$SDLOG" 2>/dev/null
fi
log "=== boot-completed done ==="
