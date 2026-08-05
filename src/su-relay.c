/*
 * su-relay v2.2 — fixes proot's hijacking of magiskd unix socket.
 *
 * NOTE: 此文件是根据 su-relay.py 和 service.sh 调用逻辑重写的参考实现。
 * Magisk zip 中的 prebuilt/su-relay 是线上实际运行的版本。
 * 如需从源码构建，请使用 ./build.sh vX.X --build
 *
 * Usage: su-relay <proxy-sock> <scan-dir> [log-path]
 *
 * Problem:
 *   proot bind-mounts host paths into the container. When it encounters a
 *   unix socket (e.g. /debug_ramdisk/.magisk/device/socket), it creates a
 *   temp file on the host (proot-<pid>-XXXXXX) and bind-mounts that into
 *   the container. The temp file is not a socket, so connect() fails ENOENT.
 *
 * Solution:
 *   This daemon scans /proc/self/mountinfo for proot-* temp files that are
 *   mounted at .magisk/device/socket paths, then replaces them with a
 *   symlink to the proxy socket. The su client's connect() is then resolved
 *   by the kernel through the symlink to the real proxy socket.
 *
 * Why not relay (forward) connections?
 *   magiskd's check-client gate uses SO_PEERCRED to verify the connecting
 *   process's /proc/pid/exe matches the magisk binary (same dev+inode).
 *   A relay process would fail this check. With a symlink, the kernel
 *   resolves the path transparently — the peer IS the su client itself.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <stdarg.h>
#include <errno.h>
#include <sys/stat.h>

#define MOUNTINFO "/proc/self/mountinfo"
#define POLL_INTERVAL 2
#define MAX_LINE 4096
#define MAX_SOURCES 64

static const char *g_proxy_sock = NULL;
static const char *g_scan_dir = NULL;
static FILE *g_log = NULL;

static void log_msg(const char *fmt, ...) {
    if (!g_log) return;
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    fprintf(g_log, "%04d-%02d-%02d %02d:%02d:%02d [su-relay] ",
            tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday,
            tm->tm_hour, tm->tm_min, tm->tm_sec);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fprintf(g_log, "\n");
    fflush(g_log);
}

/*
 * Parse mountinfo and return proot temp file sources that are mounted
 * at .magisk/device/socket paths. Caller frees the returned array.
 * Returns count of sources found (0 if none).
 */
static int find_poisoned_sources(char sources[][MAX_LINE], int max) {
    FILE *f = fopen(MOUNTINFO, "r");
    if (!f) {
        log_msg("mountinfo read failed: %s", strerror(errno));
        return 0;
    }

    int count = 0;
    char line[MAX_LINE];

    while (fgets(line, sizeof(line), f) && count < max) {
        /* Parse mountinfo format:
         * 36 35 98:0 /mnt1 /mnt2 rw,noatime master:1 - ext3 /dev/root rw,errors=continue
         * Fields: mount_id parent_id major:minor root mount_point opt - fs_type source super_opts
         * We need mount_point (field 5) and source (field after "-")
         */
        char *saveptr = NULL;
        char *tok;
        int field = 0;
        char mount_point[MAX_LINE] = "";
        char source[MAX_LINE] = "";
        int dash_seen = 0;
        int field_after_dash = 0;

        tok = strtok_r(line, " \t\n", &saveptr);
        while (tok) {
            field++;
            if (field == 5) {
                snprintf(mount_point, sizeof(mount_point), "%s", tok);
            }
            if (dash_seen) {
                field_after_dash++;
                if (field_after_dash == 2) {
                    snprintf(source, sizeof(source), "%s", tok);
                    break;
                }
            }
            if (field > 5 && strcmp(tok, "-") == 0) {
                dash_seen = 1;
            }
            tok = strtok_r(NULL, " \t\n", &saveptr);
        }

        /* Check: mount_point ends with .magisk/device/socket
         * AND source starts with proot temp dir prefix */
        if (!mount_point[0] || !source[0]) continue;
        if (!strstr(mount_point, ".magisk/device/socket")) continue;
        if (strncmp(source, "/data/data/com.termux/files/usr/tmp/proot-", 43) != 0 &&
            strncmp(source, "/data/user/0/com.termux/files/usr/tmp/proot-", 45) != 0) {
            /* Also check g_scan_dir prefix if set */
            if (g_scan_dir) {
                char prefix[MAX_LINE];
                snprintf(prefix, sizeof(prefix), "%s/proot-", g_scan_dir);
                if (strncmp(source, prefix, strlen(prefix)) != 0) continue;
            } else {
                continue;
            }
        }

        snprintf(sources[count], MAX_LINE, "%s", source);
        count++;
    }

    fclose(f);
    return count;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <proxy-sock> <scan-dir> [log-path]\n", argv[0]);
        return 1;
    }

    g_proxy_sock = argv[1];
    g_scan_dir = argv[2];

    if (argc > 3) {
        g_log = fopen(argv[3], "a");
        if (!g_log) g_log = stderr;
    } else {
        g_log = stderr;
    }

    log_msg("su-relay started (pid %d) proxy=%s scan=%s",
            getpid(), g_proxy_sock, g_scan_dir);

    char sources[MAX_SOURCES][MAX_LINE];
    char fixed[MAX_LINE] = "";

    for (;;) {
        int n = find_poisoned_sources(sources, MAX_SOURCES);
        if (n == 0) {
            sleep(POLL_INTERVAL);
            continue;
        }

        /* Process first source (typically only one per proot instance) */
        if (strcmp(sources[0], fixed) != 0) {
            /* Remove stale file (placeholder / old socket / old symlink) */
            unlink(sources[0]);

            if (symlink(g_proxy_sock, sources[0]) == 0) {
                snprintf(fixed, sizeof(fixed), "%s", sources[0]);
                log_msg("symlink %s -> %s", sources[0], g_proxy_sock);
            } else {
                log_msg("symlink %s failed: %s", sources[0], strerror(errno));
            }
        }

        sleep(POLL_INTERVAL);
    }

    return 0;
}
