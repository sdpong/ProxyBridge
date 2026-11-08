/*
 * gateway-natlook - the little end of the gateway spike.
 *
 * The packet filter sends the traffic of the other terminals to a port of
 * this machine, and the program on that port has to know where the traffic
 * was going before it was redirected. That is the original destination, and
 * the kernel is the only one that knows it.
 *
 * macOS does not ship <net/pfvar.h>, so the layouts of the struct that are
 * in the field are declared here: three of them, with a file descriptor,
 * without one, and the newer one with a field for the reply.
 *
 * What the first run of this test taught us is that the error of the ioctl
 * does not tell the layout apart: with no state to find, the kernel
 * answered ENXIO for all of them. So the program does not guess, it tries:
 *
 *   - every layout (three of them);
 *   - which end of the socket is given first (two);
 *   - the byte order of the ports (two: the order of the network and the
 *     order of the machine - the state table keeps the ports of the
 *     machine, and nobody writes down what the ioctl wants);
 *   - the number that goes into the protocol field (two);
 *   - the direction (two);
 *   - the destination the lookup is made with: the address the socket is
 *     bound to, or the place the traffic was going before (two).
 *
 * That is a hundred and something ioctls for one connection, and they cost
 * nothing. The answer of the kernel is printed in every reading, because
 * the byte order of what it says is a convention this program cannot know
 * either.
 *
 * The program takes the connections, asks the kernel where they came from,
 * and then connects to that place and relays the bytes. The answer of the
 * kernel is written to the log, which is what the spike reads.
 *
 *   gateway-natlook <listen port> <fallback host> <fallback port>
 *                   [source port base] [known original host] [known original port]
 *
 * The source port is bound on the outgoing connection: the packet filter
 * would otherwise redirect it again, and the program would talk to itself.
 * Every connection takes the next port of the range, so that many of them
 * can be open at the same time.
 *
 * The known original host and port are only for the test: the test knows
 * where it sent the connection, so one more way of looking the state up
 * can be tried with it.
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


/* The layout of macOS, taken from the source of the kernel itself
 * (XNU, bsd/net/pfvar.h). It is not the layout of OpenBSD:
 *
 *   - the address of the filter is 128 bits wide on macOS, not 32;
 *   - the ports are in a union that also carries a call id and an spi;
 *   - there is a field for the variant of the protocol, which Apple added.
 *
 * The size of the struct goes into the number of the ioctl, so a layout
 * that is not the one of this kernel is a different ioctl, and the kernel
 * does not know it. */
struct pf_addr_apple {
    union {
        struct in_addr  v4addr;
        struct in6_addr v6addr;
        uint8_t  addr8[16];
        uint16_t addr16[8];
        uint32_t addr32[4];
    } pfa;
};

union pf_state_xport {
    uint16_t port;
    uint16_t call_id;
    uint32_t spi;
};

struct pfioc_natlook_apple {
    struct pf_addr_apple saddr;
    struct pf_addr_apple daddr;
    struct pf_addr_apple rsaddr;
    struct pf_addr_apple rdaddr;
    union pf_state_xport sxport;
    union pf_state_xport dxport;
    union pf_state_xport rsxport;
    union pf_state_xport rdxport;
    sa_family_t af;
    uint8_t  proto;
    uint8_t  proto_variant;
    uint8_t  direction;
};
#define DIOCNATLOOK_APPLE _IOWR('D', 23, struct pfioc_natlook_apple)

/* The size the kernel expects. It is 84 bytes: the family of an address is
 * one byte on macOS, and the struct is padded to four. */
typedef char pf_natlook_size_check[(sizeof(struct pfioc_natlook_apple) == 84) ? 1 : -1];

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

/* The layouts the program tries. */
#define LAYOUT_OLD    0
#define LAYOUT_OLDER  1
#define LAYOUT_NEW    2
#define LAYOUT_APPLE  3
#define LAYOUT_COUNT  4

/* The device of the packet filter. Only root may open it, and the ioctl
 * of the kernel is sent on it - not on the socket. */
static int pf_device = -1;

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

/* One way of asking the kernel. */
struct probe_input {
    int order;        /* ORDER_PEER_FIRST, ORDER_LOCAL_FIRST */
    int ports;        /* PORT_NET, PORT_HOST */
    int addrs;        /* ADDR_NET, ADDR_HOST */
    int proto;        /* 6 or 2 */
    int dir;          /* PF_IN, PF_OUT */
    int use_original; /* the destination is the place the traffic was going */
};

/* What the kernel wrote back. */
struct probe_result {
    uint32_t saddr;
    uint32_t daddr;
    uint32_t rsaddr;
    uint32_t rdaddr;
    uint16_t sport;
    uint16_t dport;
    uint16_t rsport;
    uint16_t rdport;
};

#define ORDER_PEER_FIRST 0
#define ORDER_LOCAL_FIRST 1
#define PORT_NET 0
#define PORT_HOST 1
#define ADDR_NET 0
#define ADDR_HOST 1

static const char *layout_name(int layout) {
    switch (layout) {
    case LAYOUT_OLD: return "old";
    case LAYOUT_OLDER: return "older";
    case LAYOUT_NEW: return "new";
    default: return "apple";
    }
}

/* The port in the byte order that is asked for. */
static uint16_t port_in(uint16_t network_port, int order) {
    return order == PORT_NET ? network_port : (uint16_t)ntohs(network_port);
}

/* The address in the byte order that is asked for.
 *
 * The addresses of the state table are the addresses of the network, but
 * the ioctl may want the other reading, and even 127.0.0.1 is two
 * different numbers in the two of them. */
static uint32_t addr_in(uint32_t network_addr, int order) {
    return order == ADDR_NET ? network_addr : swap32(network_addr);
}

/* The layout of macOS, asked on the device of the packet filter.
 *
 * The kernel reverses the lookup: the source and the destination of the
 * connection are given the way the socket sees them, and the kernel looks
 * for the state of the way back. When the direction is PF_OUT the answer
 * is the gateway of the state, which is the place the traffic was going
 * before it was redirected. */
static int probe_apple(const struct sockaddr_in *peer,
                       const struct sockaddr_in *local, const struct sockaddr_in *original,
                       const struct probe_input *in, struct probe_result *out) {
    if (pf_device < 0) return 0;

    struct sockaddr_in src, dst;
    if (in->order == ORDER_PEER_FIRST) {
        src = *peer;
        dst = *local;
    } else {
        src = *local;
        dst = *peer;
    }
    if (in->use_original && original != NULL) {
        dst = *original;
    }

    struct pfioc_natlook_apple nl;
    memset(&nl, 0, sizeof(nl));
    /* the address of the filter is 128 bits wide; the address of an ipv4
     * goes into the first four bytes of it, in the order of the network */
    memcpy(&nl.saddr.pfa.v4addr, &src.sin_addr, sizeof(struct in_addr));
    memcpy(&nl.daddr.pfa.v4addr, &dst.sin_addr, sizeof(struct in_addr));
    nl.sxport.port = port_in(src.sin_port, in->ports);
    nl.dxport.port = port_in(dst.sin_port, in->ports);
    nl.af = AF_INET;
    nl.proto = (uint8_t)in->proto;
    nl.proto_variant = 0;
    nl.direction = (uint8_t)in->dir;

    if (ioctl(pf_device, DIOCNATLOOK_APPLE, &nl) != 0) return 0;

    memset(out, 0, sizeof(*out));
    memcpy(&out->saddr, &nl.saddr.pfa.v4addr, sizeof(struct in_addr));
    memcpy(&out->daddr, &nl.daddr.pfa.v4addr, sizeof(struct in_addr));
    memcpy(&out->rsaddr, &nl.rsaddr.pfa.v4addr, sizeof(struct in_addr));
    memcpy(&out->rdaddr, &nl.rdaddr.pfa.v4addr, sizeof(struct in_addr));
    out->sport = nl.sxport.port;
    out->dport = nl.dxport.port;
    out->rsport = nl.rsxport.port;
    out->rdport = nl.rdxport.port;
    return 1;
}

/* Fills one of the layouts and asks the kernel.
 * Returns 1 when the kernel answered. */
static int probe(int fd, int layout, const struct sockaddr_in *peer,
                 const struct sockaddr_in *local, const struct sockaddr_in *original,
                 const struct probe_input *in, struct probe_result *out) {
    /* the ends of the socket, in the order the lookup is made with */
    struct sockaddr_in src, dst;
    if (in->order == ORDER_PEER_FIRST) {
        src = *peer;
        dst = *local;
    } else {
        src = *local;
        dst = *peer;
    }
    /* the destination may be the place the traffic was going before */
    if (in->use_original && original != NULL) {
        dst = *original;
    }

    memset(out, 0, sizeof(*out));

    if (layout == LAYOUT_APPLE) {
        return probe_apple(peer, local, original, in, out);
    }

    if (layout == LAYOUT_NEW) {
        union natlook_buffer buf;
        memset(&buf, 0, sizeof(buf));
        struct pfioc_natlook_new *nl = &buf.newer;
        nl->saddr.pfa.addr32 = addr_in(src.sin_addr.s_addr, in->addrs);
        nl->daddr.pfa.addr32 = addr_in(dst.sin_addr.s_addr, in->addrs);
        nl->sport = port_in(src.sin_port, in->ports);
        nl->dport = port_in(dst.sin_port, in->ports);
        nl->af = AF_INET;
        nl->proto = (uint8_t)in->proto;
        nl->direction = (uint8_t)in->dir;
        if (ioctl(fd, DIOCNATLOOK_NEW, &buf) != 0) return 0;
        out->saddr = nl->saddr.pfa.addr32;
        out->daddr = nl->daddr.pfa.addr32;
        out->rsaddr = nl->rsaddr.pfa.addr32;
        out->rdaddr = nl->rdaddr.pfa.addr32;
        out->sport = nl->sport;
        out->dport = nl->dport;
        out->rsport = nl->rsport;
        out->rdport = nl->rdport;
        return 1;
    }

    if (layout == LAYOUT_OLD) {
        union natlook_buffer buf;
        memset(&buf, 0, sizeof(buf));
        struct pfioc_natlook_old *nl = &buf.old;
        nl->saddr.pfa.addr32 = addr_in(src.sin_addr.s_addr, in->addrs);
        nl->daddr.pfa.addr32 = addr_in(dst.sin_addr.s_addr, in->addrs);
        nl->sport = port_in(src.sin_port, in->ports);
        nl->dport = port_in(dst.sin_port, in->ports);
        nl->proto = (uint16_t)in->proto;
        nl->direction = (uint16_t)in->dir;
        nl->fd = fd;
        if (ioctl(fd, DIOCNATLOOK_OLD, &buf) != 0) return 0;
        out->saddr = nl->saddr.pfa.addr32;
        out->daddr = nl->daddr.pfa.addr32;
        out->sport = nl->sport;
        out->dport = nl->dport;
        return 1;
    }

    union natlook_buffer buf;
    memset(&buf, 0, sizeof(buf));
    struct pfioc_natlook_older *nl = &buf.older;
    nl->saddr.pfa.addr32 = addr_in(src.sin_addr.s_addr, in->addrs);
    nl->daddr.pfa.addr32 = addr_in(dst.sin_addr.s_addr, in->addrs);
    nl->sport = port_in(src.sin_port, in->ports);
    nl->dport = port_in(dst.sin_port, in->ports);
    nl->proto = (uint16_t)in->proto;
    nl->direction = (uint16_t)in->dir;
    if (ioctl(fd, DIOCNATLOOK_OLDER, &buf) != 0) return 0;
    out->saddr = nl->saddr.pfa.addr32;
    out->daddr = nl->daddr.pfa.addr32;
    out->sport = nl->sport;
    out->dport = nl->dport;
    return 1;
}

/* Prints one line per answer of the kernel. Every number is shown in both
 * readings, because the byte order is a convention this program cannot know. */
static void report(const struct probe_input *in, int layout,
                   const struct probe_result *r) {
    char s1[INET_ADDRSTRLEN], s2[INET_ADDRSTRLEN];
    char d1[INET_ADDRSTRLEN], d2[INET_ADDRSTRLEN];
    char rs1[INET_ADDRSTRLEN], rs2[INET_ADDRSTRLEN];
    char rd1[INET_ADDRSTRLEN], rd2[INET_ADDRSTRLEN];
    char sp[32], dp[32], rsp[32], rdp[32];

    fmt_addr(r->saddr, s1, s2);
    fmt_addr(r->daddr, d1, d2);
    fmt_addr(r->rsaddr, rs1, rs2);
    fmt_addr(r->rdaddr, rd1, rd2);
    fmt_port(r->sport, sp, sizeof(sp));
    fmt_port(r->dport, dp, sizeof(dp));
    fmt_port(r->rsport, rsp, sizeof(rsp));
    fmt_port(r->rdport, rdp, sizeof(rdp));

    log_line("NATLOOK ok layout=%s order=%s ports=%s addrs=%s proto=%d dir=%s dst=%s "
             "saddr=%s/%s sport=%s daddr=%s/%s dport=%s "
             "rsaddr=%s/%s rsport=%s rdaddr=%s/%s rdport=%s",
             layout_name(layout),
             in->order == ORDER_PEER_FIRST ? "peer_first" : "local_first",
             in->ports == PORT_NET ? "net" : "host",
             in->addrs == ADDR_NET ? "net" : "host",
             in->proto,
             in->dir == PF_IN ? "in" : "out",
             in->use_original ? "original" : "local",
             s1, s2, sp, d1, d2, dp, rs1, rs2, rsp, rd1, rd2, rdp);
}

/* Asks the kernel in every way there is, and keeps the first answer.
 * Returns the number of answers. */
static int ask(int fd, const struct sockaddr_in *peer, const struct sockaddr_in *local,
               const struct sockaddr_in *original, struct answer *best) {
    static const int protos[] = { 6, 2 };
    static const int dirs[] = { PF_IN, PF_OUT };
    int answers = 0;
    int errnos[LAYOUT_COUNT] = { 0, 0, 0 };

    for (int layout = 0; layout < LAYOUT_COUNT; layout++) {
        for (int order = 0; order < 2; order++) {
            for (int ports = 0; ports < 2; ports++) {
                for (int addrs = 0; addrs < 2; addrs++) {
                    for (size_t p = 0; p < sizeof(protos) / sizeof(protos[0]); p++) {
                        for (size_t d = 0; d < sizeof(dirs) / sizeof(dirs[0]); d++) {
                            for (int original_dst = 0; original_dst < 2; original_dst++) {
                            struct probe_input in;
                            in.order = order;
                            in.ports = ports;
                            in.addrs = addrs;
                            in.proto = protos[p];
                            in.dir = dirs[d];
                            in.use_original = original_dst && original != NULL;
                            struct probe_result r;
                            if (!probe(fd, layout, peer, local, original, &in, &r)) {
                                errnos[layout] = errno;
                                continue;
                            }
                            answers++;
                            report(&in, layout, &r);
                            if (!best->found) {
                                best->found = 1;
                                snprintf(best->layout, sizeof(best->layout), "%s",
                                         layout_name(layout));
                                /* the place the traffic was going before it
                                 * was redirected is the gateway of the state,
                                 * and the kernel puts it in the reply
                                 * address when the direction is PF_OUT */
                                if (layout == LAYOUT_NEW || layout == LAYOUT_APPLE) {
                                    best->addr = r.rdaddr;
                                    best->port = r.rdport;
                                } else {
                                    best->addr = r.daddr;
                                    best->port = r.dport;
                                }
                            }
                            }
                        }
                    }
                }
            }
        }
        if (answers == 0 && errnos[layout] != 0) {
            log_line("NATLOOK layout=%s was refused in every way: %s (errno %d)",
                     layout_name(layout), strerror(errnos[layout]), errnos[layout]);
        }
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
                       int source_port, const struct sockaddr_in *original) {
    struct sockaddr_in peer, local;
    peer_of(client, &peer);
    local_of(client, &local);
    log_line("accepted from %s:%u to %s:%u",
             inet_ntoa(peer.sin_addr), (unsigned)ntohs(peer.sin_port),
             inet_ntoa(local.sin_addr), (unsigned)ntohs(local.sin_port));

    struct answer best;
    memset(&best, 0, sizeof(best));
    int answers = ask(client, &peer, &local, original, &best);

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
    relay(client, upstream);
    close(upstream);
    log_line("one connection is over");
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <listen port> <fallback host> <fallback port> "
                        "[source port base] [known original host] [known original port]\n", argv[0]);
        return 2;
    }
    int listen_port = atoi(argv[1]);
    const char *fallback_host = argv[2];
    int fallback_port = atoi(argv[3]);
    int source_base = (argc > 4) ? atoi(argv[4]) : 0;

    /* the place the traffic was going before, when the caller knows it */
    struct sockaddr_in original;
    memset(&original, 0, sizeof(original));
    const struct sockaddr_in *original_ptr = NULL;
    if (argc > 6) {
        struct in_addr a;
        if (inet_pton(AF_INET, argv[5], &a) == 1) {
            original.sin_family = AF_INET;
            original.sin_addr = a;
            original.sin_port = htons((uint16_t)atoi(argv[6]));
            original_ptr = &original;
            log_line("the place the traffic was going is known: %s:%d", argv[5], atoi(argv[6]));
        }
    }

    /* The device of the packet filter. The ioctl that asks where a
     * connection was going is sent on it, and only root may open it. */
    pf_device = open("/dev/pf", O_RDWR);
    if (pf_device < 0) {
        log_line("/dev/pf could not be opened (%s): the original destination"
                 " cannot be read without the root", strerror(errno));
    } else {
        log_line("/dev/pf is open, the kernel can be asked");
    }

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
            handle_one(client, fallback_host, fallback_port, source_port, original_ptr);
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
