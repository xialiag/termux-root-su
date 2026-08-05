#!/system/bin/sh
# termux-root-su v2.1 boot-completed.sh
# Fallback: check if proxy is running, restart if needed.
# Runs once after boot is fully complete.

MODDIR="${0%/*}"
LOG="/data/local/tmp/termux-root-su.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [boot-completed] $*" >> "$LOG"; }

# Check if proxy is already running (CE may still be locking)
TERMUX_DATA=""
for i in $(seq 1 30); do
    for d in /data/data/com.termux /data/user/0/com.termux; do
        [ -d "$d/files/usr/bin" ] && TERMUX_DATA="$d" && break
    done
    [ -n "$TERMUX_DATA" ] && break
    sleep 1
done
[ -z "$TERMUX_DATA" ] && exit 0

PROXY_SOCK="$TERMUX_DATA/files/usr/tmp/magisk-proxy.sock"
if [ -S "$PROXY_SOCK" ]; then
    # Proxy socket exists, check if someone's listening
    # (service.sh already started everything)
    log "proxy socket exists, checking relay..."
    
    # Check if su-relay is running
    if ! pgrep -f "su-relay" >/dev/null 2>&1; then
        log "su-relay not running, restarting service.sh"
        exec "$MODDIR/service.sh"
    fi
    
    log "all good"
    exit 0
fi

# Proxy not running, restart everything
log "proxy not running, restarting service.sh"
exec "$MODDIR/service.sh"
