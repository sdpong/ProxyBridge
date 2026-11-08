/*
 * gateway-natlook - the little end of the gateway spike.
 *
 * The packet filter sends the traffic of the other terminals to a port of
 * this machine, and the program on that port has to know where the traffic
 * was going before it was redirected. That is the original destination, and
 * the kernel is the only one that knows it.
 *
 * macOS does not ship <net/pfvar.h>, so the two layouts that are in the
 * field are declared here. The size of the struct goes into the number of
 * the ioctl, so a layout that is not the one of this kernel is refused with
 * ENOTTY instead of being read wrong. Both are tried, and the answer is
 * printed in every reading, because the byte order of the ports is a
 * convention that this program cannot know either.
 *
 * The program takes one connection, asks the kernel where it came from, and
 * then connects to that place and relays the bytes. The answer of the kernel
 * is written to the log, which is what the spike reads.
 *
 *   gateway-natlook <listen port> <fallback host> <fallback port> [source port]
 *
 * The source port is bound on the outgoing connection: the packet filter
 * would otherwise redirect it again, and the program would talk to itself.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* The address of the packet filter. */
struct pf_addr {
    union {
        uint32_t addr32;
        uint8_t  addr8[4];
        uint8_t  addr16[16];
    } pfa;
};

/* The older layout: what macOS inherited from OpenBSD before 5.0. */
struct pfioc_natlook_old {
    struct pf_addr saddr;
    struct pf_addr daddr;
    uint16_t sport;
    uint16_t dport;
    uint16_t proto;
    uint16_t direction;
    int      fd;
};
#define DIOCNATLOOK_OLD _IOWR('D', 23, struct pfioc_natlook_old)

/* The newer layout: FreeBSD after 5.0. */
struct pfioc_natlook_new {
    struct pf_addr saddr;
    struct pf_addr daddr;
    struct pf_addr rsaddr;
    struct pf_addr rdaddr;
    uint16_t sport;
    uint16_t dport;
    uint16_t rsport;
    uint16_t rdport;
    uint16_t af;
    uint8_t  proto;
    uint8_t  direction;
};
#define DIOCNATLOOK_NEW _IOWR('D', 23, struct pfioc_natlook_new)

#define PF_IN  1
#define PF_OUT 2

static void log_line(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vfprintf(stdout, fmt, args);
    va_end(args);
    fputc('\n', stdout);
    fflush(stdout);
}

/* The address and the port of the other side of a socket. */
static void peer_of(int fd, struct sockaddr_in *out) {
    socklen_t len = sizeof(*out);
    memset(out, 0, sizeof(*out));
    if (getpeername(fd, (struct sockaddr *)out, &len) != 0) {
        out->sin_family = AF_INET;
        out->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        out->sin_port = 0;
    }
}

static void local_of(int fd, struct sockaddr_in *out) {
    socklen_t len = sizeof(*out);
    memset(out, 0, sizeof(*out));
    if (getsockname(fd, (struct sockaddr *)out, &len) != 0) {
        out->sin_family = AF_INET;
        out->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        out->sin_port = 0;
    }
}

/* Fills the struct with what the kernel needs to find the state:
 * the two ends of the socket. */
static void fill_old(struct pfioc_natlook_old *nl, int fd,
                     const struct sockaddr_in *peer, const struct sockaddr_in *local) {
    memset(nl, 0, sizeof(*nl));
    nl->saddr.pfa.addr32 = peer->sin_addr.s_addr;
    nl->daddr.pfa.addr32 = local->sin_addr.s_addr;
    nl->sport = peer->sin_port;
    nl->dport = local->sin_port;
    nl->proto = 2;            /* PF_INET */
    nl->direction = PF_IN;
    nl->fd = fd;
}

static void fill_new(struct pfioc_natlook_new *nl, int fd,
                     const struct sockaddr_in *peer, const struct sockaddr_in *local) {
    memset(nl, 0, sizeof(*nl));
    nl->saddr.pfa.addr32 = peer->sin_addr.s_addr;
    nl->daddr.pfa.addr32 = local->sin_addr.s_addr;
    nl->sport = peer->sin_port;
    nl->dport = local->sin_port;
    nl->af = AF_INET;
    nl->proto = 2;            /* IPPROTO_TCP */
    nl->direction = PF_IN;
    (void)fd;
}

/* Prints an address in every reading, because the byte order of the ports
 * is a convention this program cannot know. */
static void print_addr(const char *tag, uint32_t addr, uint16_t port) {
    struct in_addr a;
    char buf[INET_ADDRSTRLEN];
    a.s_addr = addr;
    if (inet_ntop(AF_INET, &a, buf, sizeof(buf)) == NULL) {
        snprintf(buf, sizeof(buf), "?");
    }
    log_line("%s addr=%s port_host=%u port_net=%u", tag, buf,
             (unsigned)ntohs(port), (unsigned)port);
}

/* Asks the kernel where the connection was going before it was redirected.
 * Returns 1 when one of the two layouts answered. */
static int natlook(int fd, uint32_t *out_addr, uint16_t *out_port, char *which, size_t which_len) {
    struct sockaddr_in peer, local;
    peer_of(fd, &peer);
    local_of(fd, &local);

    struct pfioc_natlook_old old;
    fill_old(&old, fd, &peer, &local);
    if (ioctl(fd, DIOCNATLOOK_OLD, &old) == 0) {
        *out_addr = old.daddr.pfa.addr32;
        *out_port = old.dport;
        snprintf(which, which_len, "old");
        return 1;
    }
    log_line("natlook old refused: %s (errno %d)", strerror(errno), errno);

    struct pfioc_natlook_new newer;
    fill_new(&newer, fd, &peer, &local);
    if (ioctl(fd, DIOCNATLOOK_NEW, &newer) == 0) {
        *out_addr = newer.daddr.pfa.addr32;
        *out_port = newer.dport;
        snprintf(which, which_len, "new");
        return 1;
    }
    log_line("natlook new refused: %s (errno %d)", strerror(errno), errno);
    return 0;
}

/* Connects to a place and says whether it worked. */
static int connect_to(uint32_t addr, uint16_t port, int source_port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        log_line("socket failed: %s", strerror(errno));
        return -1;
    }
    if (source_port > 0) {
        /* the source port is the way out of the redirect: the rule that
         * redirects the traffic of the clients must not touch it */
        struct sockaddr_in local;
        memset(&local, 0, sizeof(local));
        local.sin_family = AF_INET;
        local.sin_addr.s_addr = htonl(INADDR_ANY);
        local.sin_port = htons((uint16_t)source_port);
        if (bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0) {
            log_line("bind of the source port %d failed: %s", source_port, strerror(errno));
            close(fd);
            return -1;
        }
    }
    struct sockaddr_in target;
    memset(&target, 0, sizeof(target));
    target.sin_family = AF_INET;
    target.sin_addr.s_addr = addr;
    target.sin_port = port;
    if (connect(fd, (struct sockaddr *)&target, sizeof(target)) != 0) {
        log_line("connect failed: %s", strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

/* Moves the bytes both ways until one side stops. */
static void relay(int a, int b) {
    fd_set read_set;
    int open_a = 1, open_b = 1;
    while (open_a || open_b) {
        FD_ZERO(&read_set);
        if (open_a) FD_SET(a, &read_set);
        if (open_b) FD_SET(b, &read_set);
        int maxfd = (a > b ? a : b) + 1;
        if (select(maxfd, &read_set, NULL, NULL, NULL) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (open_a && FD_ISSET(a, &read_set)) {
            char buf[65536];
            ssize_t n = recv(a, buf, sizeof(buf), 0);
            if (n <= 0 || send(b, buf, (size_t)n, 0) < 0) { open_a = 0; shutdown(b, SHUT_WR); }
        }
        if (open_b && FD_ISSET(b, &read_set)) {
            char buf[65536];
            ssize_t n = recv(b, buf, sizeof(buf), 0);
            if (n <= 0 || send(a, buf, (size_t)n, 0) < 0) { open_b = 0; shutdown(a, SHUT_WR); }
        }
    }
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <listen port> <fallback host> <fallback port> [source port]\n", argv[0]);
        return 2;
    }
    int listen_port = atoi(argv[1]);
    const char *fallback_host = argv[2];
    int fallback_port = atoi(argv[3]);
    int source_port = (argc > 4) ? atoi(argv[4]) : 0;

    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) { perror("socket"); return 1; }
    int one = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)listen_port);
    if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) != 0) { perror("bind"); return 1; }
    if (listen(listener, 8) != 0) { perror("listen"); return 1; }
    log_line("listening on 127.0.0.1:%d", listen_port);

    int client = accept(listener, NULL, NULL);
    if (client < 0) { perror("accept"); return 1; }
    struct sockaddr_in peer;
    peer_of(client, &peer);
    log_line("accepted from %s:%u", inet_ntoa(peer.sin_addr), (unsigned)ntohs(peer.sin_port));

    uint32_t orig_addr = 0;
    uint16_t orig_port = 0;
    char which[16] = "none";
    int known = natlook(client, &orig_addr, &orig_port, which, sizeof(which));
    if (known) {
        log_line("NATLOOK layout=%s", which);
        print_addr("NATLOOK", orig_addr, orig_port);
    } else {
        log_line("NATLOOK failed");
    }

    /* where to go: what the kernel said, or the place the caller named */
    uint32_t go_addr = orig_addr;
    uint16_t go_port = orig_port;
    if (!known) {
        struct in_addr a;
        if (inet_pton(AF_INET, fallback_host, &a) != 1) {
            log_line("the fallback address %s is not an address", fallback_host);
            close(client);
            return 1;
        }
        go_addr = a.s_addr;
        go_port = htons((uint16_t)fallback_port);
        log_line("going to the fallback %s:%d", fallback_host, fallback_port);
    } else {
        log_line("going to the original destination");
    }

    int upstream = connect_to(go_addr, go_port, source_port);
    if (upstream < 0) {
        close(client);
        return 1;
    }
    relay(client, upstream);
    close(upstream);
    close(client);
    log_line("done");
    return 0;
}
