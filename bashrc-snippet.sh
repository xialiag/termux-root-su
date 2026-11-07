# ===== termux-root-su v3.9: proxy probe (no auto-spawn) =====
# v3.7: a proxy spawned INSIDE the container runs as the Termux uid —
# proot fakes getuid()==0 for the proxy itself, but every child it forks
# is the Termux uid, so su would return fake root. Worse, it squats the
# port and the host watchdog (which only checked /proc/net/tcp) would
# never replace it. So: probe only, never spawn. The host watchdog also
# verifies identity (id -u == 0) and kills fake proxies within 15s.
# v3.9: restart hint switched to trsu-restart3.sh — the old inline flow
# died because its own pkill/killall dragged the calling su shell down
# with it. restart3 self-detaches with setsid before killing anything.
if ! timeout 3 su -c 'true' >/dev/null 2>&1; then
    echo "[termux-root-su] root 代理未运行。在 Termux(宿主)里执行："
    echo "    env -u LD_PRELOAD /product/bin/su -c 'setsid sh /sdcard/Download/trsu-restart3.sh </dev/null >/dev/null 2>&1 &'"
    echo "  （必须带 env -u LD_PRELOAD：Termux 的 ld-preload 会让 Magisk 客户端"
    echo "    CANNOT LINK 直接死掉；裸 su 是本模块 TCP 客户端，代理挂了自己也连不上）"
    echo "  脚本自动后台脱离，几秒后跑完。把 /sdcard/Download/trsu-fix.log 给容器里的 agent 看。"
else
    # A proxy answers — the host watchdog replaces a fake (non-root) one
    # within 15s. Nothing to do here.
    :
fi
# ===== end termux-root-su =====

