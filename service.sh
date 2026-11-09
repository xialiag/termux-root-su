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
# All process cleanup now uses kill_pat/kill_comm_eq: /proc/PID/comm scan +
# kill -9 (comm never blocks; cmdline's open() does). Watchdog also tolerates
# transient empty root-probes (doze).
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
log "=== service.sh v3.10 starting ==="
# kill_pat <comm-substr>: kill -9 processes whose /proc/<pid>/comm contains
# <comm-substr>. pkill/killall are NOT usable on this ROM (toybox pkill -x
# kills nothing; Termux killall prefix-matches the watchdog comm and dragged
# watchdog+proxy down together on 2026-11-06).
#
# v3.10: read /proc/<pid>/comm, NEVER /proc/<pid>/cmdline. Reading cmdline
# with a shell `< file` redirection BLOCKS the open() when the target is in
# the magisk domain (this shell is too) — that froze the watchdog every 15s
# and left the proxy dead. comm is a fixed 15-char task name, always readable,
# never blocks, and needs no per-pid child/spawn (the earlier `timeout 2 sh
# -c tr` workaround "worked" but cost 2s per unreadable pid -> minutes).
# Matching is on the 15-char comm, so pass comm prefixes:
#   proxy   -> "magisk-proxy"    (comm == "magisk-proxy")
#   watchdog-> "magisk-proxy-wa" (comm truncated from magisk-proxy-watchdog.sh)
kill_pat() {
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        { read -r _comm < "$_d/comm"; } 2>/dev/null || continue
        [ -z "$_comm" ] && continue
        case "$_comm" in
            *"$1"*) kill -9 "$_pid" 2>/dev/null ;;
        esac
    done
}
# Exact-comm variant: needed to distinguish the proxy (comm "magisk-proxy")
# from the watchdog (comm "magisk-proxy-wa", which CONTAINS "magisk-proxy").
# A substring kill of "magisk-proxy" would murder the watchdog.
kill_comm_eq() {
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        { read -r _comm < "$_d/comm"; } 2>/dev/null || continue
        [ "$_comm" = "$1" ] && kill -9 "$_pid" 2>/dev/null
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
    # KernelSU (no Magisk tmpfs): the proxy forks shells directly and never
    # talks to magiskd, so a placeholder keeps the best-effort socket probe
    # harmless instead of aborting the whole service.
    MAGISKTMP="/data/adb/ksu"
    log "no Magisk tmpfs; KernelSU fallback MAGISKTMP=$MAGISKTMP"
fi
log "MAGISKTMP=$MAGISKTMP"

# --- Discover real magiskd socket (best-effort; proxy does NOT need it) ---
# v3.x proxy forks shell directly as root (no magiskd connection), so a
# missing/broken magiskd socket must not abort startup. Pre-v3.3 su-relay
# left a dead symlink here (socket -> magisk-proxy.sock, target removed);
# clean it so magisk clients can reconnect after a magiskd restart.
REAL_SOCK="$MAGISKTMP/.magisk/device/socket"
if [ -d "$MAGISKTMP/.magisk" ]; then
    for i in $(seq 1 15); do
        [ -S "$REAL_SOCK" ] && break
        sleep 1
    done
else
    log "no Magisk tmpfs; skipping magiskd socket wait"
fi
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
SNIP_MARK="termux-root-su v3.10: proxy probe"
for rootfs in "$TERMUX_DATA/files/usr/var/lib/proot-distro/containers"/*/rootfs; do
    [ -f "$rootfs/root/.bashrc" ] || continue
    if grep -q "# ===== termux-root-su v3" "$rootfs/root/.bashrc" 2>/dev/null; then
        # Only delete start..end when BOTH markers exist. sed range-delete
        # with a missing end marker wipes everything to EOF, destroying the
        # rest of the user's .bashrc; in that (corrupt) case drop only the
        # stray start/section marker lines.
        if grep -q "# ===== end termux-root-su =====" "$rootfs/root/.bashrc" 2>/dev/null; then
            sed -i '/# ===== termux-root-su v3/,/# ===== end termux-root-su =====/d' \
                "$rootfs/root/.bashrc" 2>/dev/null
        else
            sed -i '/# ===== termux-root-su v3/d' "$rootfs/root/.bashrc" 2>/dev/null
        fi
        log "stripped old bashrc snippet -> $rootfs/root/.bashrc"
    fi
    printf '\n' >> "$rootfs/root/.bashrc"
    cat "$MODDIR/bashrc-snippet.sh" >> "$rootfs/root/.bashrc"
    log "deployed bashrc snippet ($SNIP_MARK) -> $rootfs/root/.bashrc"
done

# --- Start magisk-proxy ---
# v3.10 SECURITY: primary transport is an abstract-namespace unix socket
# (@termux-root-su) so the proxy can authenticate callers via SO_PEERCRED and
# reject every app except Termux (uid) / root. proot does NOT hijack abstract
# names, so this is reachable inside the container. TCP loopback remains only
# as a fallback for ROMs where abstract sockets misbehave — it has no auth.
PORT_FILE="$TERMUX_TMP/magisk-proxy.port"
PROXY_LOG="$TERMUX_TMP/magisk-proxy.log"
ABS_NAME="termux-root-su"

# Termux uid = owner of the app data dir; the only non-root uid allowed in.
TERMUX_UID=$(stat -c %u "$TERMUX_DATA" 2>/dev/null)
[ -z "$TERMUX_UID" ] && TERMUX_UID=$(ls -nd "$TERMUX_DATA" 2>/dev/null | awk '{print $3}')
log "Termux uid: ${TERMUX_UID:-unknown}"

# Exact comm match: kills the proxy (comm "magisk-proxy") but NOT the
# watchdog (comm "magisk-proxy-wa", which contains "magisk-proxy").
kill_comm_eq "magisk-proxy"
sleep 0.3
rm -f "$PORT_FILE" "$PROXY_LOG"

log "=== starting magisk-proxy ==="
start_proxy() {   # $1 = argv[1]: "@<name>" (abstract) or numeric port
    _raw="$TERMUX_TMP/magisk-proxy $1 $REAL_SOCK $PROXY_LOG ${TERMUX_UID:-0}"
    if command -v setsid >/dev/null 2>&1; then
        setsid $_raw &
    else
        $_raw &
    fi
}

# --- 1) abstract unix socket (authenticated) ---
start_proxy "@$ABS_NAME"
j=0
while [ $j -lt 8 ]; do
    j=$((j + 1)); sleep 0.25
    grep -q "abstract=@$ABS_NAME" "$PROXY_LOG" 2>/dev/null && break
done
if grep -q "abstract=@$ABS_NAME" "$PROXY_LOG" 2>/dev/null; then
    MODE="abstract"
    PORT=""
    log "proxy listening on abstract @$ABS_NAME (auth: uid 0 / ${TERMUX_UID:-?})"
else
    # --- 2) TCP fallback (no peer auth; only if abstract bind failed) ---
    log "WARN: abstract socket failed, falling back to TCP loopback (NO AUTH)"
    kill_comm_eq "magisk-proxy"; sleep 0.3; rm -f "$PROXY_LOG"
    MODE="tcp"; PORT=""
    for i in $(seq 0 19); do
        try_port=$((48000 + i))
        start_proxy "$try_port"
        j=0
        while [ $j -lt 6 ]; do
            j=$((j + 1)); sleep 0.5
            grep -q "tcp=127.0.0.1:$try_port" "$PROXY_LOG" 2>/dev/null && break
        done
        if grep -q "tcp=127.0.0.1:$try_port" "$PROXY_LOG" 2>/dev/null; then
            PORT="$try_port"
            break
        fi
        kill_comm_eq "magisk-proxy"
        sleep 0.3
    done
    if [ -z "$PORT" ]; then
        log "FATAL: proxy could not bind abstract or any TCP port (48000-48019)"; exit 1
    fi
fi

if [ "$MODE" = "tcp" ]; then
    echo "$PORT" > "$PORT_FILE"
    chmod 644 "$PORT_FILE"
    log "proxy listening on 127.0.0.1:$PORT (port file: $PORT_FILE)"
else
    # No port to record; keep a marker so tools can tell abstract mode.
    printf 'abstract:%s\n' "$ABS_NAME" > "$PORT_FILE"
    chmod 644 "$PORT_FILE"
fi
# Also drop the port file into every container rootfs /tmp — that path IS
# visible inside proot, so su inside the container hits the right port
# directly instead of relying on the port scan fallback.
for rootfs in "$TERMUX_DATA/files/usr/var/lib/proot-distro/containers"/*/rootfs; do
    [ -d "$rootfs/tmp" ] || continue
    cp "$PORT_FILE" "$rootfs/tmp/magisk-proxy.port" 2>/dev/null
    chmod 644 "$rootfs/tmp/magisk-proxy.port" 2>/dev/null
    log "port file -> $rootfs/tmp/magisk-proxy.port"
done

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
# v3.10: proxy re-spawn must pass the same allowed-uid (Termux) so restarted
# instances keep SO_PEERCRED auth. __ALLOW_UID__ is substituted by service.sh.
ALLOW_UID=__ALLOW_UID__
# v3.10: detect MAGISKTMP like service.sh instead of hard-coding /debug_ramdisk;
# some ROMs expose it only under /sbin, and a wrong path made restarts log a
# confusing "socket not found" (proxy does not need it, but keep it truthful).
REAL_SOCK=""
if command -v magisk >/dev/null 2>&1; then
    MT="$(magisk --path 2>/dev/null)"
    [ -n "$MT" ] && REAL_SOCK="$MT/.magisk/device/socket"
fi
if [ -z "$REAL_SOCK" ]; then
    for _d in /debug_ramdisk /sbin; do
        [ -d "$_d/.magisk" ] && REAL_SOCK="$_d/.magisk/device/socket" && break
    done
fi
[ -z "$REAL_SOCK" ] && REAL_SOCK=/debug_ramdisk/.magisk/device/socket
wlog() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*" >> "$PROXY_LOG" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*" >> "$SDLOG" 2>/dev/null
}
wlog "watchdog loop entered (pid $$)"
# inline kill helpers: pkill is unreliable on this ROM; read /proc/<pid>/comm
# (a 15-char task name that never blocks) and skip ourselves.
# v3.10: NEVER read /proc/<pid>/cmdline — its open() blocks for magisk-domain
# targets and froze this very watchdog every 15s, leaving su dead. comm is safe.
kill_pat() {          # substring match on comm
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        { read -r _c < "$_d/comm"; } 2>/dev/null || continue
        [ -z "$_c" ] && continue
        case "$_c" in *"$1"*) kill -9 "$_pid" 2>/dev/null ;; esac
    done
}
kill_comm_eq() {      # exact comm match (proxy "magisk-proxy" vs watchdog "magisk-proxy-wa")
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        { read -r _c < "$_d/comm"; } 2>/dev/null || continue
        [ "$_c" = "$1" ] && kill -9 "$_pid" 2>/dev/null
    done
}
while :; do
    # v3.10: liveness = "is there a proxy process AND does su reach root".
    # We no longer probe /proc/net/tcp because the primary transport is an
    # abstract unix socket (no TCP table entry). A proxy in the magisk domain
    # has unreadable /proc, so we count it via comm (never blocks).
    ALIVE=0
    for _d in /proc/[0-9]*; do
        { read -r _c < "$_d/comm"; } 2>/dev/null || continue
        [ "$_c" = "magisk-proxy" ] && { ALIVE=1; break; }
    done
    if [ "$ALIVE" = 1 ]; then
        UID_OUT=$(timeout 5 "$SU_BIN" -c 'id -u' 2>/dev/null)
        # Empty = transient (doze froze the probe). Retry once; if still
        # empty, LEAVE THE PROXY ALONE — only a confirmed non-zero uid
        # proves a fake (container-spawned) proxy.
        if [ -z "$UID_OUT" ]; then
            sleep 2
            UID_OUT=$(timeout 8 "$SU_BIN" -c 'id -u' 2>/dev/null)
        fi
        if [ -n "$UID_OUT" ] && [ "$UID_OUT" != "0" ]; then
            wlog "proxy up but not root (id -u=$UID_OUT), killing fake"
            kill_comm_eq "magisk-proxy"
            sleep 1
            ALIVE=0
        fi
    fi
    if [ "$ALIVE" = 0 ]; then
        # Restart using the recorded transport (abstract by default).
        MARK=$(cat "$PORT_FILE" 2>/dev/null)
        case "$MARK" in
            abstract:*) ARG="@${MARK#abstract:}" ;;
            [0-9]*)     ARG="$MARK" ;;   # legacy TCP fallback
            *)          ARG="@termux-root-su" ;;
        esac
        wlog "proxy down, restarting on $ARG"
        if command -v setsid >/dev/null 2>&1; then
            setsid "$PROXY_BIN" "$ARG" "$REAL_SOCK" "$PROXY_LOG" "$ALLOW_UID" &
        else
            "$PROXY_BIN" "$ARG" "$REAL_SOCK" "$PROXY_LOG" "$ALLOW_UID" &
        fi
    fi
    sleep 15
done
WDEOF
chmod 755 "$WD"
# Substitute the allowed-uid placeholder now that we know it (heredoc is
# single-quoted, so it was written literally).
sed -i "s/__ALLOW_UID__/${TERMUX_UID:-0}/" "$WD"
# v3.9: kill stale watchdogs first. Multiple watchdogs war over the proxy
# (each probes via su; a transient empty probe makes one kill the shared
# proxy, the others race to respawn it -> 4 proxies squatting 48000-48003
# and flapping su). Newest service.sh run must own the watchdog role alone.
kill_pat "magisk-proxy-wa"
sleep 1
# toybox on some ROMs lacks setsid; fall back to plain nohup.
if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$WD" >/dev/null 2>&1 &
else
    nohup "$WD" >/dev/null 2>&1 &
fi
log "watchdog started (pid $!)"

log "=== service.sh done ==="
