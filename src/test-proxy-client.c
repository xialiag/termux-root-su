/*
 * Test client: connects to the proxy, sends a su_request for "id", receives fds.
 */
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/uio.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>

static int recv_fd(int sock) {
    char cmsgbuf[CMSG_SPACE(sizeof(int))];
    struct iovec iov = { .iov_base = malloc(1), .iov_len = 1 };
    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = cmsgbuf,
        .msg_controllen = sizeof(cmsgbuf),
    };
    if (recvmsg(sock, &msg, 0) < 0) { perror("recvmsg"); return -1; }
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (cmsg && cmsg->cmsg_type == SCM_RIGHTS) {
        return *(int *)CMSG_DATA(cmsg);
    }
    return -1;
}

static void write_lp_str(int fd, const char *s) {
    int32_t len = strlen(s);
    write(fd, &len, 4);
    write(fd, s, len);
}

int main(int argc, char *argv[]) {
    const char *sock = argc > 1 ? argv[1] : "/tmp/test-proxy.sock";
    const char *cmd = argc > 2 ? argv[2] : "id";
    
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strncpy(addr.sun_path, sock, sizeof(addr.sun_path) - 1);
    
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect"); return 1;
    }
    fprintf(stderr, "Connected\n");
    
    /* Send su_request */
    int32_t uid = 0, access = -1;
    uint8_t mode = 0, login = 0, keepenv = 0;
    
    write(fd, &uid, 4);
    write(fd, &access, 4);
    write(fd, &mode, 1);
    write(fd, &login, 1);
    write(fd, &keepenv, 1);
    write_lp_str(fd, "/system/bin/sh");
    write_lp_str(fd, cmd);
    int32_t term = 0;
    write(fd, &term, 4);
    fprintf(stderr, "Sent request: cmd=[%s]\n", cmd);
    
    /* Receive 3 fds */
    int stdin_fd = recv_fd(fd);
    int stdout_fd = recv_fd(fd);
    int stderr_fd = recv_fd(fd);
    fprintf(stderr, "Received fds: stdin=%d stdout=%d stderr=%d\n",
            stdin_fd, stdout_fd, stderr_fd);
    
    /* Receive child pid */
    pid_t child_pid;
    read(fd, &child_pid, sizeof(child_pid));
    fprintf(stderr, "Child pid: %d\n", child_pid);
    
    /* Read from stdout until EOF */
    char buf[4096];
    ssize_t n;
    while ((n = read(stdout_fd, buf, sizeof(buf))) > 0) {
        write(STDOUT_FILENO, buf, n);
    }
    fprintf(stderr, "\nstdout EOF\n");
    
    /* Receive exit code */
    int exit_code;
    read(fd, &exit_code, sizeof(exit_code));
    fprintf(stderr, "Exit code: %d\n", exit_code);
    
    close(fd);
    return exit_code;
}
