/*
 * magisk-proxy v3.6 — relay-based proxy for proot environments.
 *
 * Uses a simple frame protocol instead of SCM_RIGHTS.
 * Frame: uint32 length, data[length].  length=0 means "end of relay".
 * After end-of-relay frame: uint32 exit_code (raw, outside framing).
 *
 * v3.6: concurrent connections. The old accept loop was serial — one
 *   stuck session (e.g. an interactive shell whose pty master never
 *   yields EIO) blocked every later su client forever. Each connection
 *   now runs in its own forked handler; the listener never blocks.
 *   Also: the relay loop checks waitpid(child, WNOHANG) on every poll
 *   return, so a session whose shell exited but whose pty master does
 *   not produce EIO (background jobs holding the slave open) still gets
 *   released instead of hanging the handler forever.
 *
 * v3.5: interactive sessions (cmd_len == 0) give the child a real pty via
 *   forkpty. With plain pipes the shell runs non-interactively: no prompt,
 *   no echo, and Ctrl+C (0x03) is just a byte to a pipe-reading sh — the
 *   session looks dead and cannot be interrupted. With a pty the tty
 *   driver provides prompt/echo and turns Ctrl+C into SIGINT to the shell.
 *
 * v3.3: TCP loopback transport. Usage: magisk-proxy <port> [unused] [log-path]
 *   A numeric <port> listens on 127.0.0.1:<port>. proot hijacks AF_UNIX
 *   socket paths (virtual bind mounts + proot-* temp files), making unix
 *   sockets unreachable from inside the container; TCP loopback has no
 *   path translation and works through proot.
 *   Non-numeric <port> keeps the legacy unix socket mode.
 *
 * Protocol:
 *   1. Client → proxy:  uint32 cmd_len, char cmd[cmd_len]
 *   2. Proxy → client:  uint32 child_pid
 *   3. Proxy → client:  frames (uint32 len + data[len]) for stdout+stderr
 *   4. Client → proxy:  raw stdin bytes (no framing needed)
 *   5. When child exits: proxy sends uint32 0 (end marker) + uint32 exit_code
 *   6. Connection closed
 *
 * Stdin is raw (no framing) because the proxy just pipes it to the child.
 * Stdout/stderr uses frames so the client can distinguish data from exit_code.
 */

#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <signal.h>
#include <time.h>
#include <stdarg.h>
#include <poll.h>
#include <pty.h>

#define RELAY_BUF_SIZE 4096

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

/* Send a frame: uint32 length + data. Returns 0 on success. */
static int send_frame(int fd, const void *data, uint32_t len) {
    if (write(fd, &len, 4) != 4) return -1;
    if (len > 0) {
        size_t sent = 0;
        while (sent < len) {
            ssize_t w = write(fd, (const char *)data + sent, len - sent);
            if (w <= 0) return -1;
            sent += w;
        }
    }
    return 0;
}

/* Reap finished connection handlers (parent only). */
static void on_sigchld(int sig) {
    (void)sig;
    while (waitpid(-1, NULL, WNOHANG) > 0) { }
}

/* Handle one client connection. Runs in a forked handler process.
 * Returns the shell exit code (informational only). */
static void handle_connection(int cfd) {
    /* This is a per-connection process: reset SIGCHLD so our own
     * waitpid() for the shell child is never reaped by the parent's
     * handler logic (which we inherited at fork). */
    signal(SIGCHLD, SIG_DFL);

    /* === Read cmd_len + cmd === */
    uint32_t cmd_len;
    if (xxread(cfd, &cmd_len, 4) < 0) {
        log_msg("failed to read cmd_len");
        close(cfd);
        _exit(0);
    }

    char *cmd = NULL;
    if (cmd_len > 0 && cmd_len < 65536) {
        cmd = malloc(cmd_len + 1);
        if (!cmd || xxread(cfd, cmd, cmd_len) < 0) {
            log_msg("failed to read cmd (len=%u)", cmd_len);
            free(cmd);
            close(cfd);
            _exit(0);
        }
        cmd[cmd_len] = '\0';
    } else if (cmd_len >= 65536) {
        log_msg("cmd_len too large: %u", cmd_len);
        close(cfd);
        _exit(0);
    }

    int interactive = (cmd_len == 0);
    log_msg("cmd=[%s] interactive=%d", cmd ? cmd : "", interactive);

    int master = -1;
    int stdin_pipe[2], stdout_pipe[2], stderr_pipe[2];
    pid_t child;

    if (interactive) {
        /* === Interactive session: real pty for the child ===
         * With pipes the shell runs non-interactively (no prompt, no
         * echo; Ctrl+C is a raw byte a pipe-reading sh ignores) — the
         * session looks dead and cannot be interrupted. forkpty gives
         * the shell a controlling terminal so prompt/echo/ISIG work. */
        struct winsize ws;
        memset(&ws, 0, sizeof(ws));
        ws.ws_row = 24;
        ws.ws_col = 80;
        child = forkpty(&master, NULL, NULL, &ws);
        if (child < 0) {
            log_msg("forkpty() failed: %s", strerror(errno));
            free(cmd); close(cfd);
            _exit(1);
        }
        if (child == 0) {
            /* stdin/stdout/stderr already on the pty slave */
            if (cmd && cmd[0]) {
                execl("/system/bin/sh", "sh", "-c", cmd, (char *)NULL);
            } else {
                execl("/system/bin/sh", "sh", (char *)NULL);
            }
            execl("/bin/sh", "sh", "-c", cmd ? cmd : "", (char *)NULL);
            _exit(127);
        }
    } else {
        /* === Non-interactive: pipes for child I/O === */
        if (pipe(stdin_pipe) < 0 || pipe(stdout_pipe) < 0 || pipe(stderr_pipe) < 0) {
            log_msg("pipe() failed: %s", strerror(errno));
            free(cmd); close(cfd);
            _exit(1);
        }

        child = fork();
        if (child < 0) {
            log_msg("fork() failed: %s", strerror(errno));
            free(cmd); close(cfd);
            _exit(1);
        }

        if (child == 0) {
            close(stdin_pipe[1]);
            close(stdout_pipe[0]);
            close(stderr_pipe[0]);

            dup2(stdin_pipe[0], STDIN_FILENO);
            dup2(stdout_pipe[1], STDOUT_FILENO);
            dup2(stderr_pipe[1], STDERR_FILENO);
            close(stdin_pipe[0]);
            close(stdout_pipe[1]);
            close(stderr_pipe[1]);

            if (cmd && cmd[0]) {
                execl("/system/bin/sh", "sh", "-c", cmd, (char *)NULL);
            } else {
                execl("/system/bin/sh", "sh", (char *)NULL);
            }
            execl("/bin/sh", "sh", "-c", cmd ? cmd : "", (char *)NULL);
            _exit(127);
        }

        /* --- Parent (handler) --- */
        close(stdin_pipe[0]);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);
    }

    /* === Send child_pid === */
    uint32_t child_pid = (uint32_t)child;
    if (write(cfd, &child_pid, 4) != 4) {
        log_msg("failed to send child_pid");
        kill(child, SIGTERM);
        if (interactive) {
            close(master);
        } else {
            close(stdin_pipe[1]); close(stdout_pipe[0]); close(stderr_pipe[0]);
        }
        close(cfd); free(cmd);
        _exit(1);
    }

    /* === Relay loop ===
     * stdin: raw bytes from client → child (pipe or pty master)
     * stdout/stderr: framed data from child → client
     * Interactive: one stream (pty master); non-interactive: two pipes.
     */
    struct pollfd fds[3];
    fds[0].fd = cfd;            fds[0].events = POLLIN;
    if (interactive) {
        fds[1].fd = master;     fds[1].events = POLLIN;
        fds[2].fd = -1;         fds[2].events = 0;
    } else {
        fds[1].fd = stdout_pipe[0]; fds[1].events = POLLIN;
        fds[2].fd = stderr_pipe[0]; fds[2].events = POLLIN;
    }

    int stdin_closed = 0;
    int stdout_closed = 0, stderr_closed = 0;
    int client_gone = 0;
    int idle_timeouts = 0;
    int exit_code = 1;
    int child_waited = 0;

    while (interactive ? !stdout_closed : !(stdout_closed && stderr_closed)) {
        int nfds = interactive ? 2 : 3;
        int ret = poll(fds, nfds, 5000);
        if (ret < 0) {
            if (errno == EINTR) continue;
            log_msg("poll: %s", strerror(errno));
            break;
        }

        /* The shell exited but its pty master may never yield EIO (e.g.
         * background jobs kept the slave open). Detect the exit directly
         * so the connection is released instead of hanging forever. */
        {
            int st;
            pid_t r = waitpid(child, &st, WNOHANG);
            if (r == child) {
                child_waited = 1;
                exit_code = WIFEXITED(st) ? WEXITSTATUS(st) : 1;
                break;
            }
        }

        if (ret == 0) {
            /* No activity. If the client already disconnected (stdin
             * EOF/error) but the child keeps running with no output
             * (e.g. `su -c 'sleep 30'`), kill it after a silence budget
             * so this connection never lingers. */
            if (stdin_closed) {
                /* Interactive: shell got VEOF and should exit; 10s is
                 * plenty — kill a stuck shell. Non-interactive: a
                 * client that closed stdin (pipe input) may still be
                 * waiting for output, so give it 60s before killing —
                 * this only guards against a dead client lingering
                 * (send_frame EPIPE already handles the common case
                 * where the child produces output). */
                int limit = interactive ? 2 : 12;
                if (++idle_timeouts >= limit) {
                    log_msg("client gone, killing idle child %d", child);
                    kill(child, SIGTERM);
                    break;
                }
            }
            continue;
        }

        /* Client → child stdin (raw, no framing) */
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            char buf[RELAY_BUF_SIZE];
            ssize_t n = read(cfd, buf, sizeof(buf));
            if (n < 0) {
                client_gone = 1;
                if (!stdin_closed) {
                    if (interactive) {
                        /* pty shell won't see EOF — kill it */
                        kill(child, SIGTERM);
                    } else {
                        close(stdin_pipe[1]);
                    }
                    stdin_closed = 1;
                }
                fds[0].fd = -1; fds[0].events = 0;
            } else if (n == 0) {
                /* Client done writing (shutdown SHUT_WR) */
                if (!stdin_closed) {
                    if (interactive) {
                        /* send VEOF to the pty (^D) so the shell exits
                         * cleanly and the master yields EIO */
                        char eof = 0x04;
                        ssize_t w = write(master, &eof, 1);
                        (void)w;
                    } else {
                        close(stdin_pipe[1]);
                    }
                    stdin_closed = 1;
                }
                fds[0].fd = -1; fds[0].events = 0;
            } else if (!stdin_closed) {
                if (interactive) {
                    ssize_t w = write(master, buf, n);
                    if (w < 0 && errno == EIO) {
                        /* pty master already gone — child exited */
                        stdout_closed = 1;
                        fds[1].fd = -1;
                    }
                } else {
                    ssize_t w = write(stdin_pipe[1], buf, n);
                    if (w < 0 && errno == EPIPE) {
                        close(stdin_pipe[1]); stdin_closed = 1;
                    }
                }
            }
        }

        /* Child stdout → client (framed) */
        if (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            char buf[RELAY_BUF_SIZE];
            ssize_t n = interactive
                ? read(master, buf, sizeof(buf))
                : read(stdout_pipe[0], buf, sizeof(buf));
            if (n <= 0) {
                stdout_closed = 1;
                fds[1].fd = -1; fds[1].events = 0;
            } else if (!client_gone) {
                if (send_frame(cfd, buf, (uint32_t)n) < 0) {
                    /* Client is gone (write failed). The child may keep
                     * running (e.g. sleep) — kill it so this connection
                     * never lingers. */
                    client_gone = 1;
                    kill(child, SIGTERM);
                    break;
                }
            }
        }

        /* Child stderr → client (framed, non-interactive only) */
        if (!interactive && (fds[2].revents & (POLLIN | POLLHUP | POLLERR))) {
            char buf[RELAY_BUF_SIZE];
            ssize_t n = read(stderr_pipe[0], buf, sizeof(buf));
            if (n <= 0) {
                stderr_closed = 1;
                fds[2].fd = -1; fds[2].events = 0;
            } else if (!client_gone) {
                if (send_frame(cfd, buf, (uint32_t)n) < 0) {
                    client_gone = 1;
                    kill(child, SIGTERM);
                    break;
                }
            }
        }
    }

    if (!stdin_closed) {
        if (interactive) close(master);
        else close(stdin_pipe[1]);
    }
    if (!stdout_closed) {
        if (interactive) close(master);
        else close(stdout_pipe[0]);
    }
    if (!stderr_closed && !interactive) close(stderr_pipe[0]);

    /* === Wait for child and get exit code === */
    if (!child_waited) {
        int status;
        waitpid(child, &status, 0);
        exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    }
    log_msg("child %d exited with code %d", child, exit_code);

    if (!client_gone) {
        /* Send end-of-relay frame (length=0) + exit_code */
        uint32_t zero = 0;
        ssize_t w1 = write(cfd, &zero, 4);
        ssize_t w2 = write(cfd, &exit_code, 4);
        if (w1 < 0 || w2 < 0)
            log_msg("failed to send exit_code frame");
    }

    close(cfd);
    free(cmd);
    _exit(0);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <proxy-sock> [unused] [log-path]\n", argv[0]);
        return 1;
    }

    const char *sock_path = argv[1];
    const char *log_path = argc > 3 ? argv[3] : NULL;

    if (log_path) {
        g_log = fopen(log_path, "a");
        if (!g_log) g_log = stderr;
    } else {
        g_log = stderr;
    }

    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, on_sigchld);

    /* v3.3: TCP loopback mode — argv[1] as numeric port = 127.0.0.1:port.
     * proot hijacks unix socket paths (virtual bind + proot-* temp files),
     * which makes unix sockets unreachable from inside the container.
     * TCP loopback has no path translation, so it works through proot.
     * A non-numeric argv[1] falls back to legacy unix socket mode. */
    char *end = NULL;
    long port = strtol(sock_path, &end, 10);
    int is_tcp = (sock_path[0] != '\0' && end != NULL && *end == '\0');

    int srv;
    if (is_tcp) {
        srv = socket(AF_INET, SOCK_STREAM, 0);
        if (srv < 0) { log_msg("socket() failed: %s", strerror(errno)); return 1; }
        int one = 1;
        setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in addr = { .sin_family = AF_INET };
        addr.sin_port = htons((uint16_t)port);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            log_msg("bind(127.0.0.1:%ld) failed: %s", port, strerror(errno));
            return 1;
        }
        listen(srv, 10);
        log_msg("magisk-proxy v3.6 started (pid %d, uid %d) tcp=127.0.0.1:%ld",
                getpid(), getuid(), port);
    } else {
        srv = socket(AF_UNIX, SOCK_STREAM, 0);
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
        log_msg("magisk-proxy v3.6 started (pid %d, uid %d) sock=%s",
                getpid(), getuid(), sock_path);
    }

    /* === Accept loop: each connection gets its own handler process ===
     * Serial processing would let one stuck session (interactive shell
     * whose pty master never EIOs) block every later su client forever.
     */
    for (;;) {
        int cfd = accept(srv, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            log_msg("accept: %s", strerror(errno));
            continue;
        }

        pid_t h = fork();
        if (h < 0) {
            log_msg("fork handler failed: %s", strerror(errno));
            close(cfd);
            continue;
        }
        if (h == 0) {
            /* Handler process: never touch the listener again. */
            close(srv);
            handle_connection(cfd);
            _exit(0); /* unreachable */
        }
        close(cfd);
    }

    return 0;
}
