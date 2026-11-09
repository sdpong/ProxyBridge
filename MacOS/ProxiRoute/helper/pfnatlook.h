/*
 * pfnatlook.h - the one ioctl that the gateway mode needs from the kernel.
 *
 * The kernel keeps the place a connection was going before it was redirected,
 * but macOS does not ship the header that says where that place is written.
 * The layout of the struct is declared here, taken from the source of the
 * kernel itself (XNU, bsd/net/pfvar.h), and it is checked at compile time:
 * the size of the struct goes into the number of the ioctl, so a layout that
 * is not the one of this kernel is a different ioctl and the kernel does not
 * know it.
 *
 * The whole ioctl is done here, in C, because Swift cannot pass a pointer to
 * Darwin's ioctl: the one Swift knows takes a number and not an address.
 */

#ifndef PROXIROUTE_PFNATLOOK_H
#define PROXIROUTE_PFNATLOOK_H

#include <stdint.h>

/*
 * The answer of the kernel: where the connection was going before it was
 * redirected.
 *
 * The addresses are in the order of the network, and so are the ports. The
 * zero address with the zero port means "the kernel did not say", which is
 * different from "it said 0.0.0.0:0".
 */
struct proxiroute_natlook_result {
    uint32_t address;
    uint16_t port;
};

/*
 * Where was this connection going?
 *
 * The four numbers are the four of the connection: the address and the port
 * the client opened the connection from, and the address and the port it was
 * going to. The answer is the place the connection was going before the
 * filter redirected it.
 *
 * The device of the filter is opened here, and the ioctl is sent on it - not
 * on the socket: the kernel looks the state up by the four numbers, so the
 * socket is not needed.
 *
 * Returns 0 when the kernel answered, and -1 when it did not. When it did
 * not, errno says why: ENOENT is that there is no such state, E2BIG is that
 * there is more than one and the kernel will not choose, and EINVAL is that
 * the four numbers are not a connection at all.
 *
 * The caller must be root: the device of the filter is for root alone.
 */
int proxiroute_natlook(uint32_t client_address, uint16_t client_port,
                       uint32_t destination_address, uint16_t destination_port,
                       int protocol_number,
                       struct proxiroute_natlook_result *result);

#endif /* PROXIROUTE_PFNATLOOK_H */
