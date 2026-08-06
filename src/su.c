/*
 * su v3.4 — custom su client for relay-based magisk-proxy.
 *
 * Uses frame protocol: uint32 length + data[length].
 * length=0 means end-of-relay, followed by uint32 exit_code.
 * Stdin is sent raw (no framing).
 *
 * v3.3: connects over TCP loopback (127.0.0.1:<port>) instead of a unix
 * socket path — proot hijacks AF_UNIX socket paths (virtual bind mounts +
 * proot-* temp files), which made the old unix socket unreachable and
 * caused hangs with no output.
 *
 * v3.4: port discovery hardened. Inside proot the host path
 * /data/data/com.termux/files/usr/tmp is usually NOT visible, so the port
 * file is only a hint. Candidates (hint first, then 48000-48019) are each
 * given a 1s handshake timeout; stale listeners that accept but never
 * answer are skipped instead of hanging. service.sh also drops the port
 * file into each container rootfs /tmp (visible inside proot).
 *
 * Usage:
 *   su              — interactive root shell
 *   su -c "command" — run command as root
 */

#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <termios.h>
#include <poll.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>

#define RELAY_BUF_SIZE 4096
/* Port file is written by service.sh. Inside proot containers the host path
 * /data/data/com.termux/files/usr/tmp is usually NOT visible, so we treat the
 * port file only as a hint and scan the whole 48000-48019 range as fallback. */
#define PORT_FILE  "/data/data/com.termux/files/usr/tmp/magisk-proxy.port"
#define PORT_FILE_ALT "/tmp/magisk-proxy.port"
#define DEFAULT_PORT 48000
#define PORT_SCAN_END 48020  /* exclusive */

static int xxread(int fd, void *buf, size_t n) {
    size_t done = 0;
    while (done < n) {
        ssize_t r = read(fd, (char *)buf + done, n - done);
        if (r <= 0) return -1;
        done += r;
    }
    return 0;
}

int main(int argc, char *argv[]) {
    char *cmd = NULL;
    int interactive = 1;

    /* Parse arguments */
    if (argc >= 3 && strcmp(argv[1], "-c") == 0) {
        cmd = argv[2];
        interactive = 0;
    } else if (argc >= 2 && argv[1][0] != '-') {
        cmd = argv[1];
        interactive = 0;
    }

    signal(SIGPIPE, SIG_IGN);

    /* Read port from port files (hint only; the container may not see the
     * host path, so we scan the whole range as fallback) */
    int hint_port = 0;
    const char *port_files[] = { PORT_FILE, PORT_FILE_ALT, NULL };
    for (int i = 0; port_files[i]; i++) {
        FILE *pf = fopen(port_files[i], "r");
        if (!pf) continue;
        char buf[16] = "";
        if (fgets(buf, sizeof(buf), pf)) {
            int p = atoi(buf);
            if (p >= DEFAULT_PORT && p < 65536) { hint_port = p; break; }
        }
        fclose(pf);
    }

    /* Connect to proxy over TCP loopback (no proot path translation).
     * Try hint first, then scan DEFAULT_PORT..PORT_SCAN_END-1.
     * Each candidate gets a short handshake timeout (normal proxy responds
     * within ms); dead listeners (stale processes that accept but never
     * answer) are skipped quickly instead of hanging 5s per port. */
    uint32_t cmd_len = cmd ? (uint32_t)strlen(cmd) : 0;
    uint32_t child_pid = 0;
    int sock = -1;
    int ports[PORT_SCAN_END - DEFAULT_PORT];
    int nports = 0;
    if (hint_port >= DEFAULT_PORT && hint_port < PORT_SCAN_END)
        ports[nports++] = hint_port;
    for (int p = DEFAULT_PORT; p < PORT_SCAN_END; p++)
        if (p != hint_port) ports[nports++] = p;

    for (int i = 0; i < nports && sock < 0; i++) {
        int p = ports[i];
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) break;
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)p);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        /* Non-blocking connect with a short timeout: a stale listener that
         * swallows SYNs (kernel retries can hang a blocking connect for
         * tens of seconds) must not stall the scan. */
        int fl = fcntl(s, F_GETFL, 0);
        fcntl(s, F_SETFL, fl | O_NONBLOCK);
        int cr = connect(s, (struct sockaddr *)&addr, sizeof(addr));
        if (cr != 0 && errno != EINPROGRESS) {
            close(s);
            continue;
        }
        struct pollfd cfd2 = { .fd = s, .events = POLLOUT };
        int cpret = poll(&cfd2, 1, 1000); /* 1s per candidate */
        if (cpret <= 0) {
            close(s);
            continue;
        }
        int soerr = 0;
        socklen_t slen = sizeof(soerr);
        getsockopt(s, SOL_SOCKET, SO_ERROR, &soerr, &slen);
        if (soerr != 0) {
            close(s);
            continue;
        }
        fcntl(s, F_SETFL, fl); /* back to blocking for the relay */
        /* Send cmd_len + cmd */
        if (write(s, &cmd_len, 4) != 4 ||
            (cmd_len > 0 && write(s, cmd, cmd_len) != (ssize_t)cmd_len)) {
            close(s);
            continue;
        }
        /* Read child_pid (short timeout; skip dead listeners) */
        struct pollfd pfd = { .fd = s, .events = POLLIN };
        int pret = poll(&pfd, 1, 1000); /* 1s per candidate */
        if (pret <= 0 || xxread(s, &child_pid, 4) < 0) {
            close(s);
            continue;
        }
        sock = s;
    }

    if (sock < 0) {
        fprintf(stderr,
                "Cannot connect to daemon (127.0.0.1:%d-%d): %s (os error %d)\n"
                "    The proxy may not be running. Check:\n"
                "    cat /data/data/com.termux/files/usr/tmp/magisk-proxy.log\n"
                "    cat /data/data/com.termux/files/usr/tmp/magisk-proxy.port\n",
                DEFAULT_PORT, PORT_SCAN_END - 1, strerror(errno), errno);
        return 1;
    }

    /* Set terminal to raw mode for interactive sessions */
    struct termios old_termios;
    int raw_mode = 0;
    if (interactive && isatty(STDIN_FILENO)) {
        if (tcgetattr(STDIN_FILENO, &old_termios) == 0) {
            struct termios raw = old_termios;
            cfmakeraw(&raw);
            raw.c_cc[VMIN] = 1;
            raw.c_cc[VTIME] = 0;
            tcsetattr(STDIN_FILENO, TCSANOW, &raw);
            raw_mode = 1;
        }
    }

    /* === Relay loop ===
     * stdin → proxy (raw, no framing)
     * proxy → stdout (framed: uint32 len + data; len=0 = end marker)
     */
    struct pollfd fds[2];
    fds[0].fd = STDIN_FILENO; fds[0].events = POLLIN;
    fds[1].fd = sock;          fds[1].events = POLLIN;

    uint32_t exit_code = 1;

    for (;;) {
        int ret = poll(fds, 2, -1);
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }

        /* stdin → proxy (raw) */
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            char buf[RELAY_BUF_SIZE];
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
            if (n <= 0) {
                /* stdin EOF — half-close so the proxy's child sees EOF
                 * on its stdin and can exit (e.g. `echo x | su -c cat`) */
                shutdown(sock, SHUT_WR);
                fds[0].fd = -1;
                fds[0].events = 0;
            } else {
                ssize_t w = write(sock, buf, n);
                if (w < 0) break;
            }
        }

        /* proxy → stdout (framed) */
        if (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            /* Read frame header: uint32 length */
            uint32_t frame_len;
            if (xxread(sock, &frame_len, 4) < 0) break;

            if (frame_len == 0) {
                /* End-of-relay marker — read exit_code */
                xxread(sock, &exit_code, 4);
                break;
            }

            /* Read frame data and write to stdout */
            uint32_t remaining = frame_len;
            while (remaining > 0) {
                char buf[RELAY_BUF_SIZE];
                uint32_t to_read = remaining < sizeof(buf) ? remaining : (uint32_t)sizeof(buf);
                ssize_t n = read(sock, buf, to_read);
                if (n <= 0) goto done;
                ssize_t wr = write(STDOUT_FILENO, buf, n);
                (void)wr;
                remaining -= (uint32_t)n;
            }
        }
    }

done:
    /* Restore terminal */
    if (raw_mode) {
        tcsetattr(STDIN_FILENO, TCSANOW, &old_termios);
    }

    close(sock);
    return (int)exit_code;
}
