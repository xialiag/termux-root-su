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
# v3.12: watchdog has a deployment self-check (binary vs transport marker) and a
# probe-streak circuit breaker; see the watchdog heredoc for the 2026-11-14
# incident where a version mismatch caused a 1515-iteration kill/restart loop.
# v3.9: pkill/pgrep/killall are broken on this ROM (missed kills on
# magisk-domain procs; Termux killall prefix-matches the watchdog comm
# "magisk-proxy-wa" and dragged watchdog+proxy down together on 2026-11-06).
# All process cleanup now uses kill_pat/kill_comm_eq: /proc/PID/comm scan +
# kill -9 (comm never blocks; cmdline's open() does). Watchdog also tolerates
# transient empty root-probes (doze).
# Portable: auto-discovers all paths. Runs as root by Magisk at boot.

MODDIR="${0%/*}"
case "$MODDIR" in /*) ;; *) MODDIR="$(cd "$MODDIR" 2>/dev/null && pwd || echo "$MODDIR")" ;; esac
LOG="/data/local/tmp/termux-root-su.log"
SDLOG="/sdcard/Download/trsu-boot.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [service] $*" >> "$LOG" 2>/dev/null
    # /sdcard is FUSE-backed and only visible once CE is unlocked; writes
    # silently fail before that, which is expected.
    echo "$(date '+%Y-%m-%d %H:%M:%S') [service] $*" >> "$SDLOG" 2>/dev/null
}
log "=== service.sh v3.12 starting ==="
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
# v3.12: the proxy is spawned with the REAL magiskd socket when it exists.
# Handing it "" (as an earlier watchdog did) made a TCP-mode proxy argv[3]
# empty, which is harmless, but a shell word-split of "$REAL_SOCK" with
# spaces would silently shift argv; pass it as a proper argument instead.
start_proxy() {   # $1 = argv[1]: "@<name>" (abstract) or numeric port
    if command -v setsid >/dev/null 2>&1; then
        setsid "$TERMUX_TMP/magisk-proxy" "$1" "$REAL_SOCK" "$PROXY_LOG" "${TERMUX_UID:-0}" &
    else
        "$TERMUX_TMP/magisk-proxy" "$1" "$REAL_SOCK" "$PROXY_LOG" "${TERMUX_UID:-0}" &
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

# --- Start watchdog: restart proxy if it dies, is not a root proxy, or the
# deployed binaries disagree with the transport recorded in PORT_FILE ---
#
# v3.12 FIX (2026-11-14 incident): a *version mismatch* between the deployed
# binaries and the recorded transport turned the watchdog into a kill/restart
# loop that ran 1515 times unnoticed. Root cause chain:
#   * service.sh v3.10 wrote "abstract:termux-root-su" into PORT_FILE and ran
#     the (old, v3.9) TCP-only binaries, which could never bind that name;
#   * the watchdog's liveness test was "is there a process called
#     magisk-proxy" + "does the probe `su -c 'id -u'` return 0";
#   * the probe was empty on every iteration (old TCP client vs abstract
#     marker), and an empty probe is *by design* treated as transient and
#     left alone — so nothing was killed, nothing was started, and su stayed
#     dead for 3 days while the log filled with restarts.
# Repaired invariants in this version:
#   1. LIVENESS without a probe: an abstract socket shows up in /proc/net/unix
#      and a TCP listener in /proc/net/tcp, so the watchdog can tell "nobody
#      is listening" from "listener is stale" without asking su.
#   2. TRANSPORT SELF-CHECK: compare the marker in PORT_FILE with what the
#      deployed proxy actually supports (string present in its .text). On a
#      mismatch, redeploy from the module directory and restart the proxy
#      instead of restarting the same broken pair forever.
#   3. PROBE STREAK CIRCUIT BREAKER: after N consecutive failed identity
#      probes the watchdog stops trying to "fix" the proxy blindly; it
#      re-checks the deployment (step 2), logs a FATAL line and, if the
#      module files are intact, replays service.sh once per boot.
#   4. Every decision is logged to /sdcard (readable inside proot), so a
#      silently wrong deployment can never again be invisible.
WD="$TERMUX_TMP/magisk-proxy-watchdog.sh"
cat > "$WD" <<'WDOUTER'
#!/system/bin/sh
# termux-root-su v3.12 watchdog — keep a ROOT magisk-proxy listening.
PORT_FILE=/data/data/com.termux/files/usr/tmp/magisk-proxy.port
PROXY_LOG=/data/data/com.termux/files/usr/tmp/magisk-proxy.log
SDLOG=/sdcard/Download/trsu-boot.log
SU_BIN=/data/data/com.termux/files/usr/tmp/su
PROXY_BIN=/data/data/com.termux/files/usr/tmp/magisk-proxy
MODDIR=__MODDIR__
# v3.12: proxy re-spawn must pass the same allowed-uid (Termux) so restarted
# instances keep SO_PEERCRED auth. __ALLOW_UID__ is substituted by service.sh.
ALLOW_UID=__ALLOW_UID__
PROBE_FAILS_MAX=4        # ~1 min of consecutive failed probes before declaring the deployment broken
sleep_between=15
probe_streak=0
service_replayed=0
last_marker_state=""

wlog() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*" >> "$PROXY_LOG" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*" >> "$SDLOG" 2>/dev/null
}

# kill by exact /proc/<pid>/comm (never cmdline: its open() blocks in the
# magisk domain and used to freeze this watchdog).
kill_comm_eq() {
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        { read -r _c < "$_d/comm"; } 2>/dev/null || continue
        [ "$_c" = "$1" ] && kill -9 "$_pid" 2>/dev/null
    done
}
kill_pat() {   # substring match on comm (truncated to 15 chars by the kernel)
    for _d in /proc/[0-9]*; do
        _pid="${_d#/proc/}"
        [ "$_pid" = "$$" ] && continue
        { read -r _c < "$_d/comm"; } 2>/dev/null || continue
        [ -z "$_c" ] && continue
        case "$_c" in *"$1"*) kill -9 "$_pid" 2>/dev/null ;; esac
    done
}

proxy_running() {
    for _d in /proc/[0-9]*; do
        { read -r _c < "$_d/comm"; } 2>/dev/null || continue
        [ "$_c" = "magisk-proxy" ] && return 0
    done
    return 1
}

# The transport the proxy is *supposed* to serve, derived from the marker
# service.sh wrote. Empty marker => unknown (pre-v3.8 deployments).
transport_of_marker() {
    _m=$(cat "$PORT_FILE" 2>/dev/null)
    case "$_m" in
        abstract:*) echo "abstract:${_m#abstract:}" ;;
        [0-9]*)     echo "tcp:$_m" ;;
        *)          echo "" ;;
    esac
}

# Is anything listening for our transport?
#   abstract: `--probe` bind()s the name; EADDRINUSE proves a listener exists.
#             This is the ONLY reliable oracle — Android denies /proc/net/unix
#             to non-root, and a table grep there reports "nobody listening"
#             while a proxy is already serving (duplicate spawns then all die
#             on EADDRINUSE).
#   tcp:      process-name check only: a :PORT row in /proc/net/tcp cannot be
#             attributed to our proxy, and killing an unknown holder would be
#             worse than a harmless duplicate attempt.
listening() {
    case "$1" in
        abstract:*)
            # A bind attempt is the only reliable oracle: Android routinely
            # denies /proc/net/unix to non-root, so table greps silently
            # report "nobody listening" and spawn duplicate proxies that then
            # die on EADDRINUSE. --probe exits 0 when the name is taken.
            "$PROXY_BIN" --probe "$1" >/dev/null 2>&1
            ;;
        tcp:*) proxy_running ;;
        *)     return 1 ;;
    esac
}

# Does the deployed proxy binary understand the transport we need? A v3.9
# TCP-only build has no abstract-socket code, so its .text lacks the marker
# string the server logs on bind. Absence => mismatch.
binary_supports() {
    [ -x "$PROXY_BIN" ] || return 1
    case "$1" in
        abstract:*) grep -qa "abstract=@" "$PROXY_BIN" 2>/dev/null ;;
        tcp:*)      grep -qa "tcp=127.0.0.1" "$PROXY_BIN" 2>/dev/null ;;
        *)          return 0 ;;   # unknown marker: do not second-guess
    esac
}

redeploy_from_module() {
    [ -x "$MODDIR/su" ] && [ -x "$MODDIR/magisk-proxy" ] || return 1
    cp "$MODDIR/magisk-proxy" "$PROXY_BIN" && chmod 755 "$PROXY_BIN" || return 1
    cp "$MODDIR/su" "$SU_BIN" && chmod 755 "$SU_BIN" || return 1
    # keep every copy the container can reach in lockstep with the module
    for _dst in /usr/bin/su /usr/local/bin/su; do
        [ -d "$(dirname "$_dst")" ] && cp "$MODDIR/su" "$_dst" 2>/dev/null && chmod 755 "$_dst" 2>/dev/null
    done
    wlog "redeployed binaries from $MODDIR"
    return 0
}

start_proxy() {
    # Keep argv[3] (the magiskd socket) truthful: the proxy does not need it to
    # serve, but logging a real path makes "socket not found" diagnoses honest.
    if command -v setsid >/dev/null 2>&1; then
        setsid "$PROXY_BIN" "$1" "$REAL_SOCK" "$PROXY_LOG" "$ALLOW_UID" &
    else
        "$PROXY_BIN" "$1" "$REAL_SOCK" "$PROXY_LOG" "$ALLOW_UID" &
    fi
}

# v3.12: resolve the magiskd socket once (proxy does not need it to serve;
# it is logged for honest diagnostics when restarted by the watchdog).
REAL_SOCK=""
if command -v magisk >/dev/null 2>&1; then
    _mt="$(magisk --path 2>/dev/null)"
    [ -n "$_mt" ] && REAL_SOCK="$_mt/.magisk/device/socket"
fi
if [ -z "$REAL_SOCK" ]; then
    for _d in /debug_ramdisk /sbin; do
        [ -d "$_d/.magisk" ] && REAL_SOCK="$_d/.magisk/device/socket" && break
    done
fi
[ -z "$REAL_SOCK" ] && REAL_SOCK=/debug_ramdisk/.magisk/device/socket

wlog "watchdog v3.12 loop entered (pid $$)"
while :; do
    TR=$(transport_of_marker)
    if [ -z "$TR" ]; then
        TR="abstract:termux-root-su"
        # Log once per marker state change, not every 15s: a persistent gap
        # (e.g. proxy never wrote the file) must not flood the boot log.
        if [ "$last_marker_state" != "missing" ]; then
            wlog "marker missing/unknown; assuming $TR"
            last_marker_state="missing"
        fi
    else
        last_marker_state="ok"
    fi

    # --- 1) deployment self-check (cheap; only when something looks wrong) ---
    NEED_RESTART=0
    if ! binary_supports "$TR"; then
        wlog "MISMATCH: deployed proxy does not support $TR (marker=$(cat "$PORT_FILE" 2>/dev/null)); redeploying"
        kill_comm_eq "magisk-proxy"
        sleep 1
        if redeploy_from_module; then
            NEED_RESTART=1
            probe_streak=0
        else
            wlog "FATAL: cannot redeploy from $MODDIR (module files missing/not executable)"
            service_replayed=1
        fi
    fi

    if [ "$NEED_RESTART" = 0 ] && ! listening "$TR"; then
        # Nobody is listening for the transport we recorded.
        if proxy_running; then
            wlog "proxy process alive but not listening on $TR; killing it"
            kill_comm_eq "magisk-proxy"
            sleep 1
        fi
        NEED_RESTART=1
    fi

    if [ "$NEED_RESTART" = 1 ]; then
        # The proxy argument is derived from the marker, so a wrong marker
        # would restart the same wrong thing forever; the deployment check
        # above has already validated support for this transport.
        case "$TR" in
            abstract:*) ARG="@${TR#abstract:}" ;;
            tcp:*)      ARG="${TR#tcp:}" ;;
        esac
        wlog "starting proxy with $ARG"
        start_proxy "$ARG"
        probe_streak=0
        sleep "$sleep_between"
        continue
    fi

    # --- 2) identity probe (is the listener actually serving root?) ---
    UID_OUT=$(timeout 5 "$SU_BIN" -c 'id -u' 2>/dev/null)
    if [ -z "$UID_OUT" ]; then
        sleep 2
        UID_OUT=$(timeout 8 "$SU_BIN" -c 'id -u' 2>/dev/null)
    fi

    if [ -n "$UID_OUT" ] && [ "$UID_OUT" != "0" ]; then
        wlog "proxy up but not root (id -u=$UID_OUT), killing fake (streak=$probe_streak)"
        kill_comm_eq "magisk-proxy"
        probe_streak=0
        sleep 1
        sleep "$sleep_between"
        continue
    fi

    if [ -z "$UID_OUT" ]; then
        probe_streak=$((probe_streak + 1))
        wlog "identity probe empty (streak=$probe_streak/$PROBE_FAILS_MAX, transport=$TR)"
        # A listening proxy that answers no probe is either busy (transient)
        # or built for another transport. Do NOT kill it on the first empty
        # result (doze froze the probe hourly on v3.8), but never let the
        # streak run forever: a persistent empty probe is the signature of
        # the version mismatch above.
        if [ "$probe_streak" -ge "$PROBE_FAILS_MAX" ]; then
            if [ "$service_replayed" = 0 ] && [ -x "$MODDIR/su" ] && [ -x "$MODDIR/magisk-proxy" ]; then
                # Strongest self-heal first: the module directory is the
                # authority for BOTH binaries and the transport. A replay runs
                # the real service.sh (same code path as boot), so marker,
                # deployment and listener cannot drift apart again. Watchdogs
                # are wiped by that same run — the replayed service.sh starts a
                # fresh watchdog, and this instance exits when that succeeds.
                wlog "streak limit reached; replaying service.sh (deployed binaries may not match $TR)"
                kill_comm_eq "magisk-proxy"
                kill_pat "magisk-proxy-wa"
                sh "$MODDIR/service.sh" >> "$SDLOG" 2>&1
                sleep 3
                _u=$(timeout 8 "$SU_BIN" -c 'id -u' 2>/dev/null)
                if [ "$_u" = "0" ]; then
                    wlog "replay recovered root (uid=0); exiting, service.sh owns the watchdog"
                    exit 0
                fi
                service_replayed=1
                probe_streak=0
                wlog "replay did not restore root (id -u=[$_u])"
            else
                # Nothing left to try automatically; make the failure loud
                # instead of looping. A periodic re-probe still runs so a
                # transient outage recovers on its own.
                wlog "FATAL: root proxy not answering after replay; su is BROKEN (transport=$TR, bin_supports=$(binary_supports "$TR" && echo yes || echo no))"
                last_marker_state=""   # re-announce a still-missing marker
                probe_streak=0
            fi
        fi
    else
        # healthy: uid 0
        [ "$probe_streak" != 0 ] && wlog "identity probe recovered (uid=0)"
        probe_streak=0
    fi
    sleep "$sleep_between"
done
WDOUTER
chmod 755 "$WD"
# Substitute the two placeholders (the heredoc is single-quoted on purpose).
sed -i "s|__ALLOW_UID__|${TERMUX_UID:-0}|; s|__MODDIR__|$MODDIR|" "$WD"

# v3.12: verify the substitution actually landed; an un-substituted heredoc
# would leave ALLOW_UID=__ALLOW_UID__ (atol fails -> allow_uid=0 -> the proxy
# rejects the Termux uid and su breaks with "Connection reset").
if grep -q "__ALLOW_UID__\|__MODDIR__" "$WD" 2>/dev/null; then
    log "FATAL: watchdog placeholder substitution failed (sed) — refusing to start it"
else
    # v3.9: kill stale watchdogs first. Multiple watchdogs war over the proxy
    # (each probes via su; a transient empty probe makes one kill the shared
    # proxy, the others race to respawn it -> 4 proxies squatting 48000-48003
    # and flapping su). Newest service.sh run must own the watchdog role alone.
    kill_pat "magisk-proxy-wa"
    sleep 1
    # toybox on some ROMs lacks setsid; fall back to plain nohup.
    # NOTE: $! is the setsid/nohup wrapper, NOT the detached watchdog — the
    # real pid must be read back from /proc (see below), otherwise the log
    # claims "watchdog started (pid N)" where N is an unrelated process.
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$WD" >/dev/null 2>&1 &
    else
        nohup "$WD" >/dev/null 2>&1 &
    fi
    # v3.12: report the pid that actually appeared (comm is truncated to
    # "magisk-proxy-wa" by the 15-char task-name limit), and scream if it
    # never did — "watchdog started" was previously logged unconditionally,
    # which masked exactly this failure on 2026-11-14.
    sleep 2
    WD_PID=""
    for _d in /proc/[0-9]*; do
        { read -r _c < "$_d/comm"; } 2>/dev/null || continue
        [ "$_c" = "magisk-proxy-wa" ] && WD_PID="${_d#/proc/}" && break
    done
    if [ -n "$WD_PID" ]; then
        log "watchdog started (pid $WD_PID)"
    else
        log "FATAL: watchdog did NOT start; su will not self-heal. Run tools/trsu-restart3.sh as host root"
    fi
fi

log "=== service.sh done ==="
