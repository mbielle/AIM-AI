#include "AIMManagedLocalEndpoint.h"
#include <arpa/inet.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>

int aim_process_owns_loopback_listener(int32_t pid, uint16_t port) {
    if (pid <= 0 || port == 0) return 0;
    int capacity = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (capacity <= 0 || capacity > 2 * 1024 * 1024) return 0;
    struct proc_fdinfo *fds = malloc((size_t)capacity);
    if (fds == NULL) return 0;
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, capacity);
    if (bytes <= 0 || bytes > capacity) { free(fds); return 0; }
    int found = 0;
    for (size_t index = 0; index < (size_t)bytes / sizeof(*fds); index++) {
        if (fds[index].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo socket;
        memset(&socket, 0, sizeof(socket));
        if (proc_pidfdinfo(pid, fds[index].proc_fd, PROC_PIDFDSOCKETINFO, &socket, sizeof(socket)) != sizeof(socket)) continue;
        if (socket.psi.soi_kind != SOCKINFO_TCP || socket.psi.soi_family != AF_INET) continue;
        const struct tcp_sockinfo *tcp = &socket.psi.soi_proto.pri_tcp;
        const struct in_sockinfo *internet = &tcp->tcpsi_ini;
        if (tcp->tcpsi_state == TSI_S_LISTEN && (internet->insi_vflag & INI_IPV4)
            && ntohs((uint16_t)internet->insi_lport) == port
            && internet->insi_laddr.ina_46.i46a_addr4.s_addr == htonl(INADDR_LOOPBACK)) {
            found = 1;
            break;
        }
    }
    free(fds);
    return found;
}
