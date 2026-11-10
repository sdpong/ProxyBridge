/*
 * pfnatlook.c - the one ioctl that the gateway mode needs from the kernel.
 *
 * What the kernel does with the ioctl, in the words of its own source
 * (XNU, bsd/net/pf_ioctl.c):
 *
 *   - the direction has to be PF_OUT. The lookup in the other direction
 *     gives back what was asked for and nothing else, so it is of no use.
 *   - the key of the lookup is built from the four numbers that are given:
 *     the address and the port of the client, and the address and the port
 *     the connection was going to.
 *   - when a state is found, the answer is the gateway of that state, which
 *     is the place the traffic was going before it was redirected.
 *
 * All three of those were confirmed by the test of the gateway mode on this
 * machine: the answer came back with the port the traffic was going to
 * before the filter touched it.
 *
 * The same ioctl says where a datagram was going. The kernel keeps the states
 * of tcp and of udp apart, so the protocol is one of the numbers that go in,
 * and a state of udp is only found when the variant of the protocol is the
 * one the filter gives to its own rules. That was measured on this machine as
 * well: the lookup of a datagram finds its state with the variant at one and
 * finds nothing with it at zero.
 */

#include "pfnatlook.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stddef.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <unistd.h>

/* The address of the packet filter, as macOS has it.
 *
 * It is not the address of OpenBSD: on macOS the address is 128 bits wide,
 * the ports are in a union that also carries a call id and an spi, and there
 * is a field for the variant of the protocol, which Apple added.
 */
struct pf_addr {
    union {
        struct in_addr  v4addr;
        struct in6_addr v6addr;
        uint8_t  addr8[16];
        uint16_t addr16[8];
        uint32_t addr32[4];
    } pfa;
};

/* The port of a state, in a union with the other things a port can be. */
union pf_state_xport {
    uint16_t port;
    uint16_t call_id;
    uint32_t spi;
};

/* The struct of the ioctl, as macOS has it. */
struct pfioc_natlook {
    struct pf_addr saddr;
    struct pf_addr daddr;
    struct pf_addr rsaddr;
    struct pf_addr rdaddr;
    union pf_state_xport sxport;
    union pf_state_xport dxport;
    union pf_state_xport rsxport;
    union pf_state_xport rdxport;
    sa_family_t af;
    uint8_t  proto;
    uint8_t  proto_variant;
    uint8_t  direction;
};

/*
 * The number of the ioctl.
 *
 * The size of the struct goes into it, so the kernel knows which layout is
 * being asked for. It is 84 bytes: the family of an address is one byte on
 * macOS, and the struct is padded to four.
 */
#define DIOCNATLOOK_APPLE _IOWR('D', 23, struct pfioc_natlook)

/* The check that the layout is the one of this kernel. */
typedef char proxiroute_natlook_size_check[
    (sizeof(struct pfioc_natlook) == 84) ? 1 : -1];

/* The two directions of the lookup. */
#define PROXIROUTE_PF_IN  1
#define PROXIROUTE_PF_OUT 2

/*
 * The device, opened for the length of one lookup.
 *
 * The device of the filter is opened per lookup and closed again: the
 * helper answers one question at a time, and a device that is opened and
 * closed is a device that cannot be left behind in a strange state.
 */
static int open_filter_device(void) {
    int fd = open("/dev/pf", O_RDWR);
    if (fd < 0) {
        return -1;
    }
    return fd;
}

/*
 * Where was this connection going?
 */
int proxiroute_natlook(uint32_t client_address, uint16_t client_port,
                       uint32_t destination_address, uint16_t destination_port,
                       int protocol_number, int protocol_variant,
                       struct proxiroute_natlook_result *result) {
    if (result == NULL) {
        errno = EINVAL;
        return -1;
    }

    result->address = 0;
    result->port = 0;

    int fd = open_filter_device();
    if (fd < 0) {
        return -1;
    }

    struct pfioc_natlook request;
    memset(&request, 0, sizeof(request));

    /* the address of the filter is 128 bits wide, and the address of an
     * ipv4 goes into the first four bytes of it, in the order of the network */
    memcpy(&request.saddr.pfa.v4addr, &client_address, sizeof(uint32_t));
    memcpy(&request.daddr.pfa.v4addr, &destination_address, sizeof(uint32_t));

    /* the ports are in the order of the network, the same order the answer
     * comes back in */
    request.sxport.port = client_port;
    request.dxport.port = destination_port;

    request.af = AF_INET;
    request.proto = (uint8_t)protocol_number;
    /* the variant of the protocol: the kernel compares it when it looks a
     * state of udp up, and it does not look at it for tcp */
    request.proto_variant = (uint8_t)protocol_variant;
    /* the direction has to be PF_OUT: the lookup in the other direction
     * gives back what was asked for */
    request.direction = (uint8_t)PROXIROUTE_PF_OUT;

    int rc = ioctl(fd, DIOCNATLOOK_APPLE, &request);
    int saved_errno = errno;
    close(fd);

    if (rc != 0) {
        errno = saved_errno;
        return -1;
    }

    /* the answer is the gateway of the state: the place the traffic was
     * going before it was redirected */
    memcpy(&result->address, &request.rdaddr.pfa.v4addr, sizeof(uint32_t));
    result->port = request.rdxport.port;

    return 0;
}
