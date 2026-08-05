/*
 * magisk-proxy v2.2 — spawns shells directly, bypasses magiskd check-client.
 *
 * Usage: magisk-proxy <proxy-sock> <real-sock> [log-path]
 *   (real-sock arg kept for CLI compat with service.sh, unused)
 *
 * Protocol (Magisk su client → daemon):
 *   int32  uid          (target uid, e.g. 0)
 *   int32  access       (0xffffffff = interactive/-1)
 *   uint8  mode         (0)
 *   uint8  login        (0)
 *   uint8  keepenv      (0)
 *   int32  shell_len
 *   char[] shell_path   (e.g. "/system/bin/sh")
 *   int32  cmd_len
 *   char[] cmd_data     (e.g. "id" for su -c 'id')
 *   int32  0            (terminator)
 *
 * Daemon → client:
 *   3× SCM_RIGHTS  (stdin pipe write-end, stdout pipe read-end, stderr pipe read-end)
 *   int32 child_pid
 *   [I/O through the 3 fds]
 *   int32 exit_code   (after child exits)
 */

#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/uio.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <stdarg.h>
#include <fcntl.h>

static FILE *g_log = NULL;

static void log_ts(FILE *f) {
    time_t t = time(NULL);
    struct tm *tm = localtime(&t);
    fprintf(f, "%04d-%02d-%02d %02d:%02d:%02d",
            tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday,
            tm->tm_hour, tm->tm_min, tm->tm_sec);
}

static void log_msg(const char *fmt, ...) {
    if (!g_log) return;
    va_list ap;
    va_start(ap, fmt);
    log_ts(g_log);
    fprintf(g_log, " [proxy] ");
    vfprintf(g_log, fmt, ap);
    fprintf(g_log, "\n");
    fflush(g_log);
    va_end(ap);
}

/* Send a single fd via SCM_RIGHTS */
static int send_fd(int sock, int fd_to_send) {
    char cmsgbuf[CMSG_SPACE(sizeof(int))];
    struct iovec iov = { .iov_base = "F", .iov_len = 1 };
    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = cmsgbuf,
        .msg_controllen = sizeof(cmsgbuf),
    };
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    *(int *)CMSG_DATA(cmsg) = fd_to_send;
    return sendmsg(sock, &msg, 0);
}

/* Read exactly n bytes. Returns 0 on success, -1 on error/EOF. */
static int xxread(int fd, void *buf, size_t n) {
    size_t done = 0;
    while (done < n) {
        ssize_t r = read(fd, (char *)buf + done, n - done);
        if (r <= 0) return -1;
        done += r;
    }
    return 0;
}

/* Read a length-prefixed string. Caller must free(*out). Returns 0 on success. */
static int read_lp_str(int fd, char **out) {
    int32_t len;
    if (xxread(fd, &len, 4) < 0) return -1;
    if (len < 0 || len > 65536) return -1;
    char *s = malloc(len + 1);
    if (!s) return -1;
    if (len > 0 && xxread(fd, s, len) < 0) { free(s); return -1; }
    s[len] = '\0';
    *out = s;
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <proxy-sock> <real-sock> [log-path]\n", argv[0]);
        return 1;
    }

    const char *sock_path = argv[1];
    /* argv[2] = real-sock (ignored — we don't relay to magiskd) */
    const char *log_path = argc > 3 ? argv[3] : NULL;

    if (log_path) {
        g_log = fopen(log_path, "a");
        if (!g_log) g_log = stderr;
    } else {
        g_log = stderr;
    }

    /* Create listening socket */
    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    if (srv < 0) { log_msg("socket() failed: %s", strerror(errno)); return 1; }

    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);
    unlink(sock_path);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        log_msg("bind(%s) failed: %s", sock_path, strerror(errno));
        return 1;
    }
    listen(srv, 10);
    chmod(sock_path, 0666);

    log_msg("magisk-proxy started (pid %d, uid %d) sock=%s", getpid(), getuid(), sock_path);

    for (;;) {
        int cfd = accept(srv, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            log_msg("accept: %s", strerror(errno));
            continue;
        }

        /* === Read su_request === */
        int32_t uid, access;
        uint8_t mode, login, keepenv;
        char *shell = NULL;
        char *cmd = NULL;
        int32_t terminator = -1;

        if (xxread(cfd, &uid, 4) < 0 ||
            xxread(cfd, &access, 4) < 0 ||
            xxread(cfd, &mode, 1) < 0 ||
            xxread(cfd, &login, 1) < 0 ||
            xxread(cfd, &keepenv, 1) < 0 ||
            read_lp_str(cfd, &shell) < 0 ||
            read_lp_str(cfd, &cmd) < 0 ||
            xxread(cfd, &terminator, 4) < 0) {
            log_msg("failed to read su_request");
            free(shell); free(cmd);
            close(cfd);
            continue;
        }

        log_msg("uid=%d access=%d shell=[%s] cmd=[%s]", uid, access, shell, cmd);

        /* Default shell if empty */
        if (!shell[0]) { free(shell); shell = strdup("/system/bin/sh"); }

        /* === Create pipes for shell I/O === */
        int stdin_pipe[2], stdout_pipe[2], stderr_pipe[2];
        if (pipe(stdin_pipe) < 0 || pipe(stdout_pipe) < 0 || pipe(stderr_pipe) < 0) {
            log_msg("pipe() failed: %s", strerror(errno));
            free(shell); free(cmd); close(cfd);
            continue;
        }

        /* === Fork shell === */
        pid_t child = fork();
        if (child < 0) {
            log_msg("fork() failed: %s", strerror(errno));
            free(shell); free(cmd); close(cfd);
            continue;
        }

        if (child == 0) {
            /* --- Child process --- */
            close(stdin_pipe[1]);   /* close write end of stdin */
            close(stdout_pipe[0]);  /* close read end of stdout */
            close(stderr_pipe[0]);  /* close read end of stderr */
            close(srv);
            close(cfd);

            dup2(stdin_pipe[0], STDIN_FILENO);
            dup2(stdout_pipe[1], STDOUT_FILENO);
            dup2(stderr_pipe[1], STDERR_FILENO);
            close(stdin_pipe[0]);
            close(stdout_pipe[1]);
            close(stderr_pipe[1]);

            /* Drop to requested uid if running as root */
            if (uid >= 0 && (uid_t)uid != getuid() && getuid() == 0) {
                /* Set groups first (required before setuid) */
                if (uid != 0) {
                    (void)setgroups(0, NULL);
                }
                (void)setgid((gid_t)uid);
                (void)setuid((uid_t)uid);
            }

            /* Build argv for exec:
             * If cmd is non-empty: exec shell -c cmd
             * If cmd is empty:     exec shell (interactive)
             */
            if (cmd && cmd[0]) {
                execl(shell, shell, "-c", cmd, (char *)NULL);
            } else {
                execl(shell, shell, (char *)NULL);
            }
            /* Fallback */
            execl("/system/bin/sh", "sh", "-c", cmd ? cmd : "", (char *)NULL);
            _exit(127);
        }

        /* --- Parent process --- */
        close(stdin_pipe[0]);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);

        /* Send 3 fds to client via SCM_RIGHTS:
         *   fd 0: stdin  (write end — client writes → shell reads)
         *   fd 1: stdout (read end  — shell writes → client reads)
         *   fd 2: stderr (read end  — shell writes → client reads)
         */
        int fds_to_send[3] = { stdin_pipe[1], stdout_pipe[0], stderr_pipe[0] };
        for (int i = 0; i < 3; i++) {
            if (send_fd(cfd, fds_to_send[i]) < 0) {
                log_msg("send_fd[%d] failed: %s", i, strerror(errno));
            }
        }

        /* Send child pid */
        (void)write(cfd, &child, sizeof(child));

        /* Close our copies of the pipe fds (client has them now) */
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);

        /* Wait for child and send exit code */
        int status;
        waitpid(child, &status, 0);
        int exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        (void)write(cfd, &exit_code, sizeof(exit_code));

        log_msg("child %d exited with code %d", child, exit_code);

        free(shell);
        free(cmd);
        close(cfd);
    }

    return 0;
}
