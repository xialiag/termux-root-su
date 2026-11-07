#!/system/bin/sh
# termux-root-su v3.9 service.sh
# TCP loopback transport: proxy listens on 127.0.0.1:48000+ (port written to
# magisk-proxy.port), su clients inside proot connect over loopback.
# proot hijacks AF_UNIX socket paths, so unix sockets are NOT used anymore.
# v3.4: binaries built with musl (static glibc triggers SIGSYS on seccomp
# policies without rseq); deploy su into proot rootfs; watchdog keeps the
# proxy alive after crashes.
# v3.8: (1) dual-write boot log to /sdcard/Download/trsu-boot.log — the
# proot container binds /sdcard, so boot evidence is readable WITHOUT root;
# (2) CE-unlock wait raised 120s -> 240s (this ROM reaches late_start long
# before the user unlocks; 120s expired silently on 2026-11-05 boot and the
# su deploy + proxy start never ran); (3) FATAL paths also log to sdcard.
# v3.9: pkill/pgrep/killall are broken on this ROM (missed kills on
# magisk-domain procs; Termux killall prefix-matches the watchdog comm
# "magisk-proxy-wa" and dragged watchdog+proxy down together on 2026-11-06).
# All process cleanup now uses kill_pat: explicit /proc/PID/cmdline scan +
# kill -9. Watchdog also tolerates transient empty root-probes (doze).
# Portable: auto-discovers all paths. Runs as root by Magisk at boot.

MODDIR="${0%/*}"
LOG="/data/local/tmp/termux-root-su.log"
SDLOG="/sdcard/Download/trsu-boot.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [service] $*" >> "$LOG" 2>/dev/null
    # /sdcard is FUSE-backed and only visible once CE is unlocked; writes
    # silently fail before that, which is expected.
    echo "$(date '+%Y-%m-%d %H:%M:%S') [service] $*" >> "$SDLOG" 2>/dev/null
}
log "=== service.sh v3.9 starting ==="
# kill_pat <substr>: kill -9 every process whose cmdline contains <substr>
# (except ourselves). pkill/killall are NOT usable on this ROM:
#  - toybox `pkill -x magisk-proxy` returns rc=1 and kills NOTHING while
#    the targets are alive (zombie proxies squatted 48000-48003 for days);
#  - Termux `killall magisk-proxy` prefix-matches truncated comm and also
#    murders the watchdog (comm "magisk-proxy-wa"), bricking su entirely.
# WARNING: never pass these substrings in an `su -c` one-liner — the cmd
# lands in that shell's own cmdline and it kills itself mid-run. Always
# invoke via a script file.
# v3.10: shell redirection into /proc/<pid>/cmdline HANGS when the target is
# in the magisk domain (this shell is too): the kernel blocks the open(). A
# watchdog that calls kill_pat every 15s froze on the first magisk-domain
# target and died, leaving the proxy with nobody to restart it. Read through
# a killable timeout child instead, and skip anything that won't answer in 2s.
kill_pat() {
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        _c=$(timeout 2 sh -c 'tr "\0" " " < "$1" 2>/dev/null' _ "$_d/cmdline" 2>/dev/null)
        [ -z "$_c" ] && continue
        case "$_c" in
            *"$1"*) kill -9 "$_pid" 2>/dev/null ;;
        esac
    done
}

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

# --- Discover real magiskd socket (best-effort; proxy does NOT need it) ---
# v3.x proxy forks shell directly as root (no magiskd connection), so a
# missing/broken magiskd socket must not abort startup. Pre-v3.3 su-relay
# left a dead symlink here (socket -> magisk-proxy.sock, target removed);
# clean it so magisk clients can reconnect after a magiskd restart.
REAL_SOCK="$MAGISKTMP/.magisk/device/socket"
for i in $(seq 1 15); do
    [ -S "$REAL_SOCK" ] && break
    sleep 1
done
if [ -L "$REAL_SOCK" ] && [ ! -e "$REAL_SOCK" ]; then
    log "removing dead symlink at $REAL_SOCK (su-relay legacy)"
    rm -f "$REAL_SOCK"
fi
if [ -S "$REAL_SOCK" ]; then
    log "real socket: $REAL_SOCK"
else
    log "WARN: magiskd socket not found at $REAL_SOCK (continuing; proxy works without it)"
fi

# --- Discover Termux data dir (wait for CE unlock) ---
# v3.8: 240s, not 120s. On this ROM Magisk reaches late_start well before
# the user unlocks the device; 120s expired with the screen still locked,
# service.sh exited 1 silently, and neither su deployment nor the proxy
# start ever ran (observed 2026-11-05 boot). The wait is interrupted by
# the unlock itself, so a long ceiling costs nothing when CE is already
# unlocked. Log progress every 30s to sdcard so the failure is visible.
TERMUX_DATA=""
for i in $(seq 1 240); do
    for d in /data/data/com.termux /data/user/0/com.termux; do
        [ -d "$d/files/usr/bin" ] && TERMUX_DATA="$d" && break
    done
    [ -n "$TERMUX_DATA" ] && break
    [ $((i % 30)) -eq 0 ] && log "still waiting for CE unlock (${i}s)"
    sleep 1
done
if [ -z "$TERMUX_DATA" ]; then
    log "FATAL: Termux not found after 240s (CE still locked?)"; exit 1
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
# unlink first: overwriting a RUNNING binary in place fails ETXTBSY.
rm -f "$TERMUX_TMP/magisk-proxy" "$TERMUX_TMP/su" 2>/dev/null
cp "$MODDIR/magisk-proxy" "$TERMUX_TMP/magisk-proxy" && chmod 755 "$TERMUX_TMP/magisk-proxy"
cp "$MODDIR/su" "$TERMUX_TMP/su" && chmod 755 "$TERMUX_TMP/su"

# --- Clean up legacy su-relay (removed in v3.3; TCP needs no socket patching) ---
kill_pat "su-relay"

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

# --- Deploy bashrc probe snippet (probe only, NO container-side spawn) ---
# A container-spawned proxy runs as the Termux uid (fake root) and squats
# the port; the host watchdog verifies identity and kills it. The snippet
# just probes and tells the user where to restart the proxy.
# v3.8: replace any existing block (marker-delimited) instead of skipping,
# so the hint text upgrades across versions without stacking duplicates.
SNIP_MARK="termux-root-su v3.9: proxy probe"
for rootfs in "$TERMUX_DATA/files/usr/var/lib/proot-distro/containers"/*/rootfs; do
    [ -f "$rootfs/root/.bashrc" ] || continue
    if grep -q "# ===== termux-root-su v3" "$rootfs/root/.bashrc" 2>/dev/null; then
        sed -i '/# ===== termux-root-su v3/,/# ===== end termux-root-su =====/d' \
            "$rootfs/root/.bashrc" 2>/dev/null
        log "stripped old bashrc snippet -> $rootfs/root/.bashrc"
    fi
    printf '\n' >> "$rootfs/root/.bashrc"
    cat "$MODDIR/bashrc-snippet.sh" >> "$rootfs/root/.bashrc"
    log "deployed bashrc snippet ($SNIP_MARK) -> $rootfs/root/.bashrc"
done

# --- Start magisk-proxy (TCP loopback; proot hijacks unix sockets) ---
PORT_FILE="$TERMUX_TMP/magisk-proxy.port"
PROXY_LOG="$TERMUX_TMP/magisk-proxy.log"

# Trailing space: matches proxy cmdlines ("...magisk-proxy <port> ...") but
# NOT the watchdog ("...magisk-proxy-watchdog.sh").
kill_pat "magisk-proxy "
sleep 0.3
rm -f "$PORT_FILE" "$PROXY_LOG"

log "=== starting magisk-proxy ==="
PORT=""
for i in $(seq 0 19); do
    try_port=$((48000 + i))
    "$TERMUX_TMP/magisk-proxy" "$try_port" "$REAL_SOCK" "$PROXY_LOG" &
    j=0
    while [ $j -lt 6 ]; do
        j=$((j + 1)); sleep 0.5
        grep -q "tcp=127.0.0.1:$try_port" "$PROXY_LOG" 2>/dev/null && break
    done
    if grep -q "tcp=127.0.0.1:$try_port" "$PROXY_LOG" 2>/dev/null; then
        PORT="$try_port"
        break
    fi
    kill_pat "magisk-proxy "
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

# --- Start watchdog: restart proxy if it dies or is not a root proxy ---
WD="$TERMUX_TMP/magisk-proxy-watchdog.sh"
cat > "$WD" <<'WDEOF'
#!/system/bin/sh
# termux-root-su v3.8 watchdog — keep a ROOT magisk-proxy listening.
# Liveness via /proc/net/tcp (a proxy in the magisk SELinux domain has an
# unreadable /proc/<pid>, so pgrep/ps cannot see it). Identity via
# `su -c 'id -u'` == 0: a proxy spawned inside the proot container listens
# fine but forks children as the Termux uid (fake root), so an open port
# alone is NOT proof of a working root proxy.
# v3.8: dual-writes to /sdcard/Download/trsu-boot.log so the container can
# read supervisor evidence without root.
PORT_FILE=/data/data/com.termux/files/usr/tmp/magisk-proxy.port
PROXY_LOG=/data/data/com.termux/files/usr/tmp/magisk-proxy.log
SDLOG=/sdcard/Download/trsu-boot.log
SU_BIN=/data/data/com.termux/files/usr/tmp/su
PROXY_BIN=/data/data/com.termux/files/usr/tmp/magisk-proxy
REAL_SOCK=/debug_ramdisk/.magisk/device/socket
[ -S /sbin/.magisk/device/socket ] && REAL_SOCK=/sbin/.magisk/device/socket
wlog() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*" >> "$PROXY_LOG" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*" >> "$SDLOG" 2>/dev/null
}
wlog "watchdog loop entered (pid $$)"
# inline kill_pat: pkill cannot kill the magisk-domain zombies and would
# also match this watchdog's own cmdline; scan /proc and skip $$.
# v3.10: `< file` on a magisk-domain /proc/<pid>/cmdline blocks the open(); use
# a killable timeout child or the watchdog itself hangs forever.
kill_pat() {
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        _c=$(timeout 2 sh -c 'tr "\0" " " < "$1" 2>/dev/null' _ "$_d/cmdline" 2>/dev/null)
        [ -z "$_c" ] && continue
        case "$_c" in *"$1"*) kill -9 "$_pid" 2>/dev/null ;; esac
    done
}
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
    if [ "$ALIVE" = 1 ]; then
        UID_OUT=$(timeout 5 "$SU_BIN" -c 'id -u' 2>/dev/null)
        # Empty output = transient (device doze froze the probe, proxy busy).
        # Retry once; if still empty, LEAVE THE PROXY ALONE — only a
        # confirmed non-zero uid proves a fake (container-spawned) proxy.
        # v3.8 bug: empty was killed-on-sight, so nightly doze killed the
        # real root proxy once an hour.
        if [ -z "$UID_OUT" ]; then
            sleep 2
            UID_OUT=$(timeout 8 "$SU_BIN" -c 'id -u' 2>/dev/null)
        fi
        if [ -n "$UID_OUT" ] && [ "$UID_OUT" != "0" ]; then
            wlog "port open but not root (id -u=$UID_OUT), killing fake"
            kill_pat "magisk-proxy "
            sleep 1
            ALIVE=0
        fi
    fi
    if [ "$ALIVE" = 0 ]; then
        PORT=$(cat "$PORT_FILE" 2>/dev/null)
        [ -z "$PORT" ] && PORT=48000
        wlog "proxy down, restarting on $PORT"
        "$PROXY_BIN" "$PORT" "$REAL_SOCK" "$PROXY_LOG" &
    fi
    sleep 15
done
WDEOF
chmod 755 "$WD"
# v3.9: kill stale watchdogs first. Multiple watchdogs war over the proxy
# (each probes via su; a transient empty probe makes one kill the shared
# proxy, the others race to respawn it -> 4 proxies squatting 48000-48003
# and flapping su). Newest service.sh run must own the watchdog role alone.
kill_pat "magisk-proxy-watchdog.sh"
sleep 1
# toybox on some ROMs lacks setsid; fall back to plain nohup.
if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$WD" >/dev/null 2>&1 &
else
    nohup "$WD" >/dev/null 2>&1 &
fi
log "watchdog started (pid $!)"

log "=== service.sh done ==="
