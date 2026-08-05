#!/system/bin/sh
# termux-root-su v2.1 service.sh
# Portable: auto-discovers all paths. Runs as root by Magisk at boot.

MODDIR="${0%/*}"
LOG="/data/local/tmp/termux-root-su.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [service] $*" >> "$LOG"; }
log "=== service.sh starting ==="

# --- Discover MAGISKTMP ---
MAGISKTMP=""
if command -v magisk >/dev/null 2>&1; then
    MAGISKTMP="$(magisk --path 2>/dev/null)"
fi
if [ -z "$MAGISKTMP" ]; then
    for d in /debug_ramdisk /sbin; do
        [ -d "$d/.magisk" ] && MAGISKTMP="$d" && break
    done
fi
if [ -z "$MAGISKTMP" ]; then
    log "FATAL: cannot find MAGISKTMP"; exit 1
fi
log "MAGISKTMP=$MAGISKTMP"

# --- Discover real magiskd socket ---
REAL_SOCK="$MAGISKTMP/.magisk/device/socket"
for i in $(seq 1 15); do
    [ -S "$REAL_SOCK" ] && break
    sleep 1
done
if [ ! -S "$REAL_SOCK" ]; then
    log "FATAL: real socket not found at $REAL_SOCK"; exit 1
fi
log "real socket: $REAL_SOCK"

# --- Discover Termux data dir (wait for CE unlock) ---
TERMUX_DATA=""
for i in $(seq 1 120); do
    for d in /data/data/com.termux /data/user/0/com.termux; do
        [ -d "$d/files/usr/bin" ] && TERMUX_DATA="$d" && break
    done
    [ -n "$TERMUX_DATA" ] && break
    sleep 1
done
if [ -z "$TERMUX_DATA" ]; then
    log "FATAL: Termux not found after 120s"; exit 1
fi
TERMUX_TMP="$TERMUX_DATA/files/usr/tmp"
log "Termux: $TERMUX_DATA"

# --- Wait for Termux tmp dir ---
for i in $(seq 1 30); do
    [ -d "$TERMUX_TMP" ] && break
    sleep 1
done
mkdir -p "$TERMUX_TMP" 2>/dev/null

# --- Deploy binaries ---
cp "$MODDIR/magisk-proxy" "$TERMUX_TMP/magisk-proxy" && chmod 755 "$TERMUX_TMP/magisk-proxy"
cp "$MODDIR/su-relay" "$TERMUX_TMP/su-relay" && chmod 755 "$TERMUX_TMP/su-relay"

# --- Bind su into proot container ---
MAGISK_SU=""
for p in "$MAGISKTMP/magisk/su" "$MAGISKTMP/su" /system/bin/su /system/xbin/su; do
    [ -f "$p" ] && MAGISK_SU="$p" && break
done
if [ -n "$MAGISK_SU" ]; then
    log "Magisk su: $MAGISK_SU"
    dest="$TERMUX_DATA/files/usr/local/bin/su"
    mkdir -p "$(dirname "$dest")"
    mount --bind "$MAGISK_SU" "$dest" 2>/dev/null || {
        cp "$MAGISK_SU" "$dest" && chmod 755 "$dest"
    }
fi

# --- Start magisk-proxy ---
PROXY_SOCK="$TERMUX_TMP/magisk-proxy.sock"
PROXY_LOG="$TERMUX_TMP/magisk-proxy.log"

pkill -f "magisk-proxy.*magisk-proxy.sock" 2>/dev/null
sleep 0.3
rm -f "$PROXY_SOCK"

"$TERMUX_TMP/magisk-proxy" "$PROXY_SOCK" "$REAL_SOCK" "$PROXY_LOG" &
sleep 1

for i in $(seq 1 10); do
    [ -S "$PROXY_SOCK" ] && break
    sleep 0.5
done
if [ ! -S "$PROXY_SOCK" ]; then
    log "FATAL: proxy socket not created"; exit 1
fi
chmod 666 "$PROXY_SOCK"
log "proxy socket ready: $PROXY_SOCK"

# --- Start su-relay (host-side, scans tmp dir for proot-* sockets) ---
RELAY_LOG="$TERMUX_TMP/su-relay.log"
pkill -f "su-relay.*magisk-proxy.sock" 2>/dev/null
nohup "$TERMUX_TMP/su-relay" "$PROXY_SOCK" "$TERMUX_TMP" "$RELAY_LOG" \
    >> "$RELAY_LOG" 2>&1 &
log "su-relay started (pid $!)"

log "=== service.sh done ==="
