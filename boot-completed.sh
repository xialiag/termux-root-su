#!/system/bin/sh
# termux-root-su v3.4 boot-completed.sh
# Fallback: check if proxy is listening, restart if needed.
# Runs once after boot is fully complete.

MODDIR="${0%/*}"
LOG="/data/local/tmp/termux-root-su.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [boot-completed] $*" >> "$LOG"; }

# Wait for Termux CE unlock
TERMUX_DATA=""
for i in $(seq 1 30); do
    for d in /data/data/com.termux /data/user/0/com.termux; do
        [ -d "$d/files/usr/bin" ] && TERMUX_DATA="$d" && break
    done
    [ -n "$TERMUX_DATA" ] && break
    sleep 1
done
[ -z "$TERMUX_DATA" ] && exit 0

PORT_FILE="$TERMUX_DATA/files/usr/tmp/magisk-proxy.port"
PORT=$(cat "$PORT_FILE" 2>/dev/null)
if [ -n "$PORT" ]; then
    HEX=$(printf '%04X' "$PORT")
    if grep -q ":$HEX " /proc/net/tcp 2>/dev/null; then
        log "proxy already running on port $PORT"
        exit 0
    fi
fi

# Proxy dead — if the watchdog script is deployed it will restart it within 15s
if [ -x "$TERMUX_DATA/files/usr/tmp/magisk-proxy-watchdog.sh" ]; then
    log "proxy not listening, watchdog present (will restart); skipping service.sh"
    exit 0
fi

log "proxy not running, restarting service.sh"
exec "$MODDIR/service.sh"
