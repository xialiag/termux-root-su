#!/system/bin/sh
# termux-root-su v3.4 service.sh
# TCP loopback transport: proxy listens on 127.0.0.1:48000+ (port written to
# magisk-proxy.port), su clients inside proot connect over loopback.
# proot hijacks AF_UNIX socket paths, so unix sockets are NOT used anymore.
# v3.4: binaries built with musl (static glibc triggers SIGSYS on seccomp
# policies without rseq); deploy su into proot rootfs; watchdog keeps the
# proxy alive after crashes.
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
cp "$MODDIR/su" "$TERMUX_TMP/su" && chmod 755 "$TERMUX_TMP/su"

# --- Clean up legacy su-relay (removed in v3.3; TCP needs no socket patching) ---
pkill -f "su-relay" 2>/dev/null
rm -f "$TERMUX_TMP/su-relay" "$TERMUX_TMP/magisk-proxy.sock"

# --- Deploy custom su into proot container ---
# Our su uses the relay protocol (no SCM_RIGHTS), works through proot.
for dest in "$TERMUX_DATA/files/usr/bin/su" \
            "$TERMUX_DATA/files/usr/local/bin/su"; do
    mkdir -p "$(dirname "$dest")"
    cp "$TERMUX_TMP/su" "$dest" && chmod 755 "$dest"
    log "deployed su -> $dest"
done

# --- Deploy su into proot container rootfs (container PATH is rootfs /usr/local/bin) ---
for rootfs in "$TERMUX_DATA/files/usr/var/lib/proot-distro/containers"/*/rootfs; do
    [ -d "$rootfs/usr/local/bin" ] || continue
    cp "$TERMUX_TMP/su" "$rootfs/usr/local/bin/su" && chmod 755 "$rootfs/usr/local/bin/su"
    log "deployed su -> $rootfs/usr/local/bin/su"
done

# --- Start magisk-proxy (TCP loopback; proot hijacks unix sockets) ---
PORT_FILE="$TERMUX_TMP/magisk-proxy.port"
PROXY_LOG="$TERMUX_TMP/magisk-proxy.log"

pkill -x magisk-proxy 2>/dev/null
sleep 0.3
rm -f "$PORT_FILE" "$PROXY_LOG"

PORT=""
for i in $(seq 0 19); do
    try_port=$((48000 + i))
    "$TERMUX_TMP/magisk-proxy" "$try_port" "$REAL_SOCK" "$PROXY_LOG" &
    sleep 0.5
    if grep -q "tcp=127.0.0.1:$try_port" "$PROXY_LOG" 2>/dev/null; then
        PORT="$try_port"
        break
    fi
    pkill -x magisk-proxy 2>/dev/null
    sleep 0.3
done
if [ -z "$PORT" ]; then
    log "FATAL: proxy could not bind any port (48000-48019)"; exit 1
fi
echo "$PORT" > "$PORT_FILE"
chmod 644 "$PORT_FILE"
# Also drop the port file into every container rootfs /tmp — that path IS
# visible inside proot, so su inside the container hits the right port
# directly instead of relying on the port scan fallback.
for rootfs in "$TERMUX_DATA/files/usr/var/lib/proot-distro/containers"/*/rootfs; do
    [ -d "$rootfs/tmp" ] || continue
    cp "$PORT_FILE" "$rootfs/tmp/magisk-proxy.port" 2>/dev/null
    chmod 644 "$rootfs/tmp/magisk-proxy.port" 2>/dev/null
    log "port file -> $rootfs/tmp/magisk-proxy.port"
done
log "proxy listening on 127.0.0.1:$PORT (port file: $PORT_FILE)"

# --- Start watchdog: restart proxy if it dies ---
WD="$TERMUX_TMP/magisk-proxy-watchdog.sh"
cat > "$WD" <<'WDEOF'
#!/system/bin/sh
# termux-root-su watchdog — restart magisk-proxy when the port stops listening.
# Detects liveness via /proc/net/tcp (works even when the proxy runs in a
# SELinux domain whose /proc/<pid> is not readable by this process).
PORT_FILE=/data/data/com.termux/files/usr/tmp/magisk-proxy.port
PROXY_LOG=/data/data/com.termux/files/usr/tmp/magisk-proxy.log
REAL_SOCK=/debug_ramdisk/.magisk/device/socket
[ -S /sbin/.magisk/device/socket ] && REAL_SOCK=/sbin/.magisk/device/socket
while :; do
    ALIVE=0
    for p in 48000 48001 48002 48003 48004 48005 48006 48007 48008 48009 \
             48010 48011 48012 48013 48014 48015 48016 48017 48018 48019; do
        HEX=$(printf '%04X' "$p")
        if grep -q ":$HEX " /proc/net/tcp 2>/dev/null; then
            ALIVE=1
            break
        fi
    done
    if [ "$ALIVE" = 0 ]; then
        PORT=$(cat "$PORT_FILE" 2>/dev/null)
        [ -z "$PORT" ] && PORT=48000
        /data/data/com.termux/files/usr/tmp/magisk-proxy "$PORT" "$REAL_SOCK" "$PROXY_LOG" &
    fi
    sleep 15
done
WDEOF
chmod 755 "$WD"
nohup "$WD" >/dev/null 2>&1 &
log "watchdog started (pid $!)"

log "=== service.sh done ==="
