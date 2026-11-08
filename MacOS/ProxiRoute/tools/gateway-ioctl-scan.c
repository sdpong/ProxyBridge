/*
 * gateway-ioctl-scan - the little probe of the packet filter's ioctls.
 *
 * The program that takes the redirected connection asks the kernel where
 * the connection was going before it was redirected, with an ioctl that is
 * numbered the way OpenBSD numbers it. On this machine that ioctl answers
 * ENXIO for every layout and every way of asking, which is the same answer
 * an ioctl that does not exist gives. So the number may simply be wrong:
 * Apple's packet filter is its own fork and nothing says it kept the
 * numbers of OpenBSD.
 *
 * This program finds out. It takes a socket and asks every ioctl of a
 * group, with every size that could be the right one, and writes down
 * what the kernel said. An ioctl that the kernel does not know answers the
 * same way every time; one that it knows answers differently.
 *
 * It needs no root: the ioctl is sent on a socket, and the kernel answers
 * before it looks at what the caller may do.
 *
 *   gateway-ioctl-scan [group] [first number] [last number]
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <netinet/in.h>

/* The sizes that are in the field for the ioctl of the packet filter. */
static const unsigned sizes[] = { 16, 20, 24, 28, 32 };

struct probe {
    unsigned char bytes[64];
};

int main(int argc, char **argv) {
    unsigned char group = 'D';
    int first = 0;
    int last = 63;

    if (argc > 1) group = (unsigned char)argv[1][0];
    if (argc > 2) first = atoi(argv[2]);
    if (argc > 3) last = atoi(argv[3]);

    /* a socket to ask on. it does not have to be connected: the kernel
     * answers the ioctl before it looks at the socket */
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket");
        return 1;
    }

    printf("group '%c' numbers %d to %d\n", group, first, last);

    /* what an ioctl that does not exist answers */
    errno = 0;
    struct probe junk;
    memset(&junk, 0, sizeof(junk));
    unsigned char bogus = (unsigned char)(group == 'Z' ? 'Y' : 'Z');
    int baseline = ioctl(fd, _IOWR(bogus, 200, junk), &junk);
    int baseline_errno = baseline == 0 ? 0 : errno;
    printf("an ioctl that does not exist: %s (errno %d)\n",
           baseline == 0 ? "answered" : strerror(baseline_errno), baseline_errno);

    for (int number = first; number <= last; number++) {
        for (size_t s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++) {
            struct probe buffer;
            memset(&buffer, 0, sizeof(buffer));
            /* the ioctl number carries the size of the struct, so every
             * size is a different number of its own */
            unsigned long cmd = _IOWR(group, number, buffer);
            errno = 0;
            int rc = ioctl(fd, cmd, &buffer);
            int code = rc == 0 ? 0 : errno;
            if (code != baseline_errno) {
                printf("number %d size %u: %s (errno %d)\n", number, sizes[s],
                       rc == 0 ? "answered" : strerror(code), code);
                fflush(stdout);
            }
        }
    }

    printf("done\n");
    close(fd);
    return 0;
}
