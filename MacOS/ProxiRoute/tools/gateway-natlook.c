/*
 * gateway-natlook - the little end of the gateway spike.
 *
 * The packet filter sends the traffic of the other terminals to a port of
 * this machine, and the program on that port has to know where the traffic
 * was going before it was redirected. That is the original destination, and
 * the kernel is the only one that knows it.
 *
 * macOS does not ship <net/pfvar.h>, so the layouts that are in the field
 * are declared here. The size of the struct goes into the number of the
 * ioctl, so a layout that is not the one of this kernel is refused with
 * ENOTTY instead of being read wrong. All of them are tried, and the answer
 * is printed in every reading, because the byte order of the addresses and
 * of the ports is a convention that this program cannot know either.
 *
 * The program takes the connections, asks the kernel where they came from,
 * and then connects to that place and relays the bytes. The answer of the
 * kernel is written to the log, which is what the spike reads.
 *
 *   gateway-natlook <listen port> <fallback host> <fallback port> [source port base]
 *
 * The source port is bound on the outgoing connection: the packet filter
 * would otherwise redirect it again, and the program would talk to itself.
 * Every connection takes the next port of the range, so that many of them
 * can be open at the same time.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>

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

/* The same, without the file descriptor. */
struct pfioc_natlook_older {
    struct pf_addr saddr;
    struct pf_addr daddr;
    uint16_t sport;
    uint16_t dport;
    uint16_t proto;
    uint16_t direction;
};
#define DIOCNATLOOK_OLDER _IOWR('D', 23, struct pfioc_natlook_older)

/* The newer layout: FreeBSD and OpenBSD after 5.0. */
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

/* The kernel writes its own struct back into the buffer, and its size is
 * not the one of the struct that was asked for. Every probe therefore goes
 * into one buffer that is big enough for all of them. */
union natlook_buffer {
    struct pfioc_natlook_old   old;
    struct pfioc_natlook_older older;
    struct pfioc_natlook_new   newer;
    char raw[64];
};

/* How many connections may be open at the same time. */
#define SOURCE_PORTS 100

/* ------------------------------------------------------------------ output */

static void log_line(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vfprintf(stdout, fmt, args);
    va_end(args);
    fputc('\n', stdout);
    fflush(stdout);
}

/* The other way around, so that both readings of a number can be shown. */
static uint32_t swap32(uint32_t v) {
    return ((v & 0x000000ffu) << 24) | ((v & 0x0000ff00u) << 8) |
           ((v & 0x00ff0000u) >> 8) | ((v & 0xff000000u) >> 24);
}

/* An address in both readings. */
static void fmt_addr(uint32_t v, char *host, char *swapped) {
    struct in_addr a;
    a.s_addr = v;
    if (inet_ntop(AF_INET, &a, host, INET_ADDRSTRLEN) == NULL) {
        snprintf(host, INET_ADDRSTRLEN, "?");
    }
    a.s_addr = swap32(v);
    if (inet_ntop(AF_INET, &a, swapped, INET_ADDRSTRLEN) == NULL) {
        snprintf(swapped, INET_ADDRSTRLEN, "?");
    }
}

/* A port in both readings. */
static void fmt_port(uint16_t v, char *out, size_t len) {
    snprintf(out, len, "%u/%u", (unsigned)ntohs(v), (unsigned)v);
}

/* ------------------------------------------------------------------ sockets */

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

/* ------------------------------------------------------------------ looking */

/* What the kernel answered. */
struct answer {
    int      found;
    char     layout[16];
    uint32_t addr;
    uint16_t port;
};

/* The order the two ends of the socket are given to the kernel. */
#define ORDER_PEER_FIRST 0
#define ORDER_LOCAL_FIRST 1

static const char *order_name(int order) {
    return order == ORDER_PEER_FIRST ? "peer_first" : "local_first";
}

/* Prints one line per answer of the kernel. Every number is shown in both
 * readings, because the byte order is a convention this program cannot know. */
static void report(const char *layout, int order, int proto, int dir,
                   uint32_t saddr, uint16_t sport,
                   uint32_t daddr, uint16_t dport,
                   uint32_t rsaddr, uint16_t rsport,
                   uint32_t rdaddr, uint16_t rdport) {
    char s1[INET_ADDRSTRLEN], s2[INET_ADDRSTRLEN];
    char d1[INET_ADDRSTRLEN], d2[INET_ADDRSTRLEN];
    char rs1[INET_ADDRSTRLEN], rs2[INET_ADDRSTRLEN];
    char rd1[INET_ADDRSTRLEN], rd2[INET_ADDRSTRLEN];
    char sp[32], dp[32], rsp[32], rdp[32];

    fmt_addr(saddr, s1, s2);
    fmt_addr(daddr, d1, d2);
    fmt_addr(rsaddr, rs1, rs2);
    fmt_addr(rdaddr, rd1, rd2);
    fmt_port(sport, sp, sizeof(sp));
    fmt_port(dport, dp, sizeof(dp));
    fmt_port(rsport, rsp, sizeof(rsp));
    fmt_port(rdport, rdp, sizeof(rdp));

    log_line("NATLOOK ok layout=%s order=%s proto=%d dir=%s "
             "saddr=%s/%s sport=%s daddr=%s/%s dport=%s "
             "rsaddr=%s/%s rsport=%s rdaddr=%s/%s rdport=%s",
             layout, order_name(order), proto, dir == PF_IN ? "in" : "out",
             s1, s2, sp, d1, d2, dp, rs1, rs2, rsp, rd1, rd2, rdp);
}

/* The guess of the program: where the connection was going before it was
 * redirected. The old layout puts it where the destination was, the new one
 * has a field of its own for it. */
static void take_answer(struct answer *best, const char *layout,
                         uint32_t addr, uint16_t port) {
    if (best->found) return;
    best->found = 1;
    snprintf(best->layout, sizeof(best->layout), "%s", layout);
    best->addr = addr;
    best->port = port;
}

/* Tries one layout, with every way of telling the kernel about the socket.
 * Returns the number of answers. */
static int try_old(int fd, const struct sockaddr_in *peer,
                   const struct sockaddr_in *local, struct answer *best) {
    static const int protos[] = { 6, 2 };
    static const int dirs[] = { PF_IN, PF_OUT };
    int answers = 0;
    int last_errno = 0;

    for (int order = 0; order < 2; order++) {
        for (size_t p = 0; p < sizeof(protos) / sizeof(protos[0]); p++) {
            for (size_t d = 0; d < sizeof(dirs) / sizeof(dirs[0]); d++) {
                union natlook_buffer buf;
                memset(&buf, 0, sizeof(buf));
                struct pfioc_natlook_old *nl = &buf.old;
                if (order == ORDER_PEER_FIRST) {
                    nl->saddr.pfa.addr32 = peer->sin_addr.s_addr;
                    nl->daddr.pfa.addr32 = local->sin_addr.s_addr;
                    nl->sport = peer->sin_port;
                    nl->dport = local->sin_port;
                } else {
                    nl->saddr.pfa.addr32 = local->sin_addr.s_addr;
                    nl->daddr.pfa.addr32 = peer->sin_addr.s_addr;
                    nl->sport = local->sin_port;
                    nl->dport = peer->sin_port;
                }
                nl->proto = (uint16_t)protos[p];
                nl->direction = (uint16_t)dirs[d];
                nl->fd = fd;
                if (ioctl(fd, DIOCNATLOOK_OLD, &buf) != 0) {
                    last_errno = errno;
                    continue;
                }
                answers++;
                report("old", order, protos[p], dirs[d],
                       nl->saddr.pfa.addr32, nl->sport,
                       nl->daddr.pfa.addr32, nl->dport,
                       0, 0, 0, 0);
                take_answer(best, "old", nl->daddr.pfa.addr32, nl->dport);
            }
        }
    }
    if (answers == 0 && last_errno != 0) {
        log_line("NATLOOK layout=old was refused: %s (errno %d)",
                 strerror(last_errno), last_errno);
    }
    return answers;
}

static int try_older(int fd, const struct sockaddr_in *peer,
                     const struct sockaddr_in *local, struct answer *best) {
    static const int protos[] = { 6, 2 };
    static const int dirs[] = { PF_IN, PF_OUT };
    int answers = 0;
    int last_errno = 0;

    for (int order = 0; order < 2; order++) {
        for (size_t p = 0; p < sizeof(protos) / sizeof(protos[0]); p++) {
            for (size_t d = 0; d < sizeof(dirs) / sizeof(dirs[0]); d++) {
                union natlook_buffer buf;
                memset(&buf, 0, sizeof(buf));
                struct pfioc_natlook_older *nl = &buf.older;
                if (order == ORDER_PEER_FIRST) {
                    nl->saddr.pfa.addr32 = peer->sin_addr.s_addr;
                    nl->daddr.pfa.addr32 = local->sin_addr.s_addr;
                    nl->sport = peer->sin_port;
                    nl->dport = local->sin_port;
                } else {
                    nl->saddr.pfa.addr32 = local->sin_addr.s_addr;
                    nl->daddr.pfa.addr32 = peer->sin_addr.s_addr;
                    nl->sport = local->sin_port;
                    nl->dport = peer->sin_port;
                }
                nl->proto = (uint16_t)protos[p];
                nl->direction = (uint16_t)dirs[d];
                if (ioctl(fd, DIOCNATLOOK_OLDER, &buf) != 0) {
                    last_errno = errno;
                    continue;
                }
                answers++;
                report("older", order, protos[p], dirs[d],
                       nl->saddr.pfa.addr32, nl->sport,
                       nl->daddr.pfa.addr32, nl->dport,
                       0, 0, 0, 0);
                take_answer(best, "older", nl->daddr.pfa.addr32, nl->dport);
            }
        }
    }
    if (answers == 0 && last_errno != 0) {
        log_line("NATLOOK layout=older was refused: %s (errno %d)",
                 strerror(last_errno), last_errno);
    }
    return answers;
}

static int try_new(int fd, const struct sockaddr_in *peer,
                   const struct sockaddr_in *local, struct answer *best) {
    static const int protos[] = { 6, 2 };
    static const int dirs[] = { PF_IN, PF_OUT };
    int answers = 0;
    int last_errno = 0;

    for (int order = 0; order < 2; order++) {
        for (size_t p = 0; p < sizeof(protos) / sizeof(protos[0]); p++) {
            for (size_t d = 0; d < sizeof(dirs) / sizeof(dirs[0]); d++) {
                union natlook_buffer buf;
                memset(&buf, 0, sizeof(buf));
                struct pfioc_natlook_new *nl = &buf.newer;
                if (order == ORDER_PEER_FIRST) {
                    nl->saddr.pfa.addr32 = peer->sin_addr.s_addr;
                    nl->daddr.pfa.addr32 = local->sin_addr.s_addr;
                    nl->sport = peer->sin_port;
                    nl->dport = local->sin_port;
                } else {
                    nl->saddr.pfa.addr32 = local->sin_addr.s_addr;
                    nl->daddr.pfa.addr32 = peer->sin_addr.s_addr;
                    nl->sport = local->sin_port;
                    nl->dport = peer->sin_port;
                }
                nl->af = AF_INET;
                nl->proto = (uint8_t)protos[p];
                nl->direction = (uint8_t)dirs[d];
                if (ioctl(fd, DIOCNATLOOK_NEW, &buf) != 0) {
                    last_errno = errno;
                    continue;
                }
                answers++;
                report("new", order, protos[p], dirs[d],
                       nl->saddr.pfa.addr32, nl->sport,
                       nl->daddr.pfa.addr32, nl->dport,
                       nl->rsaddr.pfa.addr32, nl->rsport,
                       nl->rdaddr.pfa.addr32, nl->rdport);
                take_answer(best, "new", nl->rdaddr.pfa.addr32, nl->rdport);
            }
        }
    }
    if (answers == 0 && last_errno != 0) {
        log_line("NATLOOK layout=new was refused: %s (errno %d)",
                 strerror(last_errno), last_errno);
    }
    return answers;
}

/* ------------------------------------------------------------------ relaying */

/* Connects to a place and says whether it worked. The connection is given
 * five seconds, so that a wrong reading of the answer does not hang the
 * whole test. */
static int connect_to(uint32_t addr, uint16_t port, int source_port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        log_line("socket failed: %s", strerror(errno));
        return -1;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
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

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, (struct sockaddr *)&target, sizeof(target));
    if (rc != 0 && errno == EINPROGRESS) {
        fd_set write_set;
        struct timeval tv;
        FD_ZERO(&write_set);
        FD_SET(fd, &write_set);
        tv.tv_sec = 5;
        tv.tv_usec = 0;
        rc = select(fd + 1, NULL, &write_set, NULL, &tv);
        if (rc > 0) {
            int err = 0;
            socklen_t len = sizeof(err);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) {
                rc = 0;
            } else {
                errno = err;
                rc = -1;
            }
        } else if (rc == 0) {
            errno = ETIMEDOUT;
            rc = -1;
        }
    }
    if (rc != 0) {
        log_line("connect failed: %s (errno %d)", strerror(errno), errno);
        close(fd);
        return -1;
    }
    fcntl(fd, F_SETFL, flags);
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

/* ------------------------------------------------------------------ one flow */

/* One connection: where was it going, and then the bytes. */
static void handle_one(int client, const char *fallback_host, int fallback_port,
                       int source_port, int listen_port) {
    struct sockaddr_in peer, local;
    peer_of(client, &peer);
    local_of(client, &local);
    log_line("accepted from %s:%u to %s:%u",
             inet_ntoa(peer.sin_addr), (unsigned)ntohs(peer.sin_port),
             inet_ntoa(local.sin_addr), (unsigned)ntohs(local.sin_port));

    struct answer best;
    memset(&best, 0, sizeof(best));
    int answers = try_old(client, &peer, &local, &best);
    answers += try_older(client, &peer, &local, &best);
    answers += try_new(client, &peer, &local, &best);

    if (answers > 0) {
        char a1[INET_ADDRSTRLEN], a2[INET_ADDRSTRLEN];
        fmt_addr(best.addr, a1, a2);
        log_line("NATLOOK best layout=%s addr=%s addr_swap=%s port_host=%u port_net=%u",
                 best.layout, a1, a2,
                 (unsigned)ntohs(best.port), (unsigned)best.port);
    } else {
        log_line("NATLOOK best layout=none addr=0.0.0.0 addr_swap=0.0.0.0 port_host=0 port_net=0");
    }

    /* Where to go: what the kernel said, or the place the caller named.
     * The answer is only used when it is not the place the traffic was
     * redirected to, because that would be talking to itself.
     *
     * The kernel may keep the byte order it was given, or it may answer in
     * the order of the machine. Both readings are tried, and the one that
     * connects is the one that was right. */
    uint32_t addrs[2];
    uint16_t ports[2];
    int candidates = 0;

    if (best.found) {
        int is_redirect = (best.addr == local.sin_addr.s_addr) &&
                          (best.port == local.sin_port ||
                           best.port == (uint16_t)ntohs(local.sin_port));
        if (!is_redirect) {
            addrs[0] = best.addr;
            addrs[1] = swap32(best.addr);
            ports[0] = best.port;
            ports[1] = htons(best.port);
            candidates = 2;
        }
    }

    int upstream = -1;
    if (candidates > 0) {
        log_line("going to the original destination");
        for (int i = 0; i < candidates && upstream < 0; i++) {
            for (int j = 0; j < candidates && upstream < 0; j++) {
                upstream = connect_to(addrs[i], ports[j], source_port);
            }
        }
    } else {
        struct in_addr a;
        if (inet_pton(AF_INET, fallback_host, &a) != 1) {
            log_line("the fallback address %s is not an address", fallback_host);
            return;
        }
        log_line("going to the fallback %s:%d", fallback_host, fallback_port);
        upstream = connect_to(a.s_addr, htons((uint16_t)fallback_port), source_port);
    }
    if (upstream < 0) {
        log_line("no way out of this connection");
        return;
    }
    (void)listen_port;
    relay(client, upstream);
    close(upstream);
    log_line("one connection is over");
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <listen port> <fallback host> <fallback port> [source port base]\n", argv[0]);
        return 2;
    }
    int listen_port = atoi(argv[1]);
    const char *fallback_host = argv[2];
    int fallback_port = atoi(argv[3]);
    int source_base = (argc > 4) ? atoi(argv[4]) : 0;

    /* The children are taken care of by the system, so that many
     * connections at the same time do not fill the machine with zombies. */
    signal(SIGCHLD, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);

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
    if (listen(listener, 64) != 0) { perror("listen"); return 1; }
    log_line("listening on 127.0.0.1:%d", listen_port);

    /* Every connection is handled on its own: the machines of the network
     * are many, and one of them must not stop the others. */
    int index = 0;
    for (;;) {
        int client = accept(listener, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            break;
        }
        int source_port = source_base > 0
            ? source_base + (index++ % SOURCE_PORTS)
            : 0;
        pid_t pid = fork();
        if (pid == 0) {
            close(listener);
            handle_one(client, fallback_host, fallback_port, source_port, listen_port);
            close(client);
            _exit(0);
        }
        close(client);
        if (pid < 0) {
            log_line("fork failed: %s", strerror(errno));
        }
    }
    close(listener);
    log_line("done");
    return 0;
}
