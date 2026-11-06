#include "pb_internal.h"

// SOCKS4 and SOCKS4a.
//
// SOCKS4 is older than SOCKS5 and much simpler: there is no method negotiation,
// only a user id in the request. SOCKS4a is the same, with the name of the host
// sent after the user id, for the case where the client cannot resolve it.
//
// Proxifier speaks it, so a proxy that only offers SOCKS4 could be used there
// and not here.
//
// Request:  VN(1)=4 CD(1)=1 DSTPORT(2) DSTIP(4) USERID(nul) [HOST(nul) for 4a]
// Reply:    VN(1) CD(1) DSTPORT(2) DSTIP(4), CD 90 = granted, 91 = rejected

#define SOCKS4_VERSION      0x04
#define SOCKS4_CMD_CONNECT  0x01
#define SOCKS4_REPLY_LEN    8
#define SOCKS4_GRANTED      90
#define SOCKS4_REJECTED     91

// Builds the request for a destination.
//  - an IPv4 address goes into DSTIP
//  - a name goes into SOCKS4a: DSTIP becomes 0.0.0.1 and the name follows the user id
//  - IPv6 cannot be asked for at all, SOCKS4 has no room for it
static int socks4_build_request(unsigned char *buf, int cap, const char *dest, UINT16 dest_port, const char *userid)
{
    int len = 0;
    int is_name = 0;

    if (dest == NULL || dest[0] == '\0') return -1;

    // an IPv4 literal goes in as it is, anything else is a name
    UINT32 ip = parse_ipv4(dest);
    if (ip != 0)
    {
        if (cap < 8 + 1) return -1;
        buf[0] = SOCKS4_VERSION;
        buf[1] = SOCKS4_CMD_CONNECT;
        buf[2] = (unsigned char)((dest_port >> 8) & 0xFF);
        buf[3] = (unsigned char)((dest_port >> 0) & 0xFF);
        buf[4] = (unsigned char)((ip >> 0) & 0xFF);
        buf[5] = (unsigned char)((ip >> 8) & 0xFF);
        buf[6] = (unsigned char)((ip >> 16) & 0xFF);
        buf[7] = (unsigned char)((ip >> 24) & 0xFF);
        len = 8;
    }
    else
    {
        // 0.0.0.1 says "a name follows"
        size_t hlen = strnlen_s(dest, 256);
        if (hlen == 0 || hlen > 255) return -1;
        is_name = 1;
        if (cap < 8 + 1 + (int)hlen + 1) return -1;
        buf[0] = SOCKS4_VERSION;
        buf[1] = SOCKS4_CMD_CONNECT;
        buf[2] = (unsigned char)((dest_port >> 8) & 0xFF);
        buf[3] = (unsigned char)((dest_port >> 0) & 0xFF);
        buf[4] = 0;
        buf[5] = 0;
        buf[6] = 0;
        buf[7] = 1;
        len = 8;
    }

    // the user id, an empty one is allowed
    size_t ulen = (userid != NULL) ? strnlen_s(userid, 256) : 0;
    if (ulen > 255) return -1;
    if (len + (int)ulen + 1 > cap) return -1;
    if (ulen > 0) memcpy(&buf[len], userid, ulen);
    len += (int)ulen;
    buf[len++] = 0;

    // the name of a socks4a request
    if (is_name)
    {
        size_t hlen = strnlen_s(dest, 256);
        if (len + (int)hlen + 1 > cap) return -1;
        memcpy(&buf[len], dest, hlen);
        len += (int)hlen;
        buf[len++] = 0;
    }

    return len;
}

// Reads the reply and reports whether the proxy granted the request.
static int socks4_read_reply(SOCKET s, int *code)
{
    unsigned char rep[SOCKS4_REPLY_LEN];
    if (recv_n(s, (char*)rep, SOCKS4_REPLY_LEN) != SOCKS4_REPLY_LEN) return -1;
    if (code) *code = rep[1];
    return (rep[1] == SOCKS4_GRANTED) ? 0 : -1;
}

// SOCKS4 CONNECT for an address.
int socks4_connect(SOCKET s, UINT32 dest_ip, UINT16 dest_port, const PROXY_CONFIG *cfg)
{
    char ds[32];
    snprintf(ds, sizeof(ds), "%u.%u.%u.%u", (dest_ip >> 0) & 0xFF, (dest_ip >> 8) & 0xFF,
             (dest_ip >> 16) & 0xFF, (dest_ip >> 24) & 0xFF);
    return socks4_connect_name(s, ds, dest_port, cfg);
}

// SOCKS4 CONNECT for a name (socks4a) or for an address given as text.
int socks4_connect_name(SOCKET s, const char *dest, UINT16 dest_port, const PROXY_CONFIG *cfg)
{
    unsigned char buf[SOCKS5_BUFFER_SIZE];
    const char *userid = (cfg != NULL) ? cfg->username : NULL;

    int len = socks4_build_request(buf, (int)sizeof(buf), dest, dest_port, userid);
    if (len < 0)
    {
        log_message("SOCKS4: cannot ask for %s:%u", dest ? dest : "?", (unsigned)dest_port);
        return -1;
    }

    if (send(s, (char*)buf, len, 0) != len)
    {
        log_message("SOCKS4: failed to send the CONNECT request");
        return -1;
    }

    int code = -1;
    if (socks4_read_reply(s, &code) != 0)
    {
        if (code == SOCKS4_REJECTED)
            log_message("SOCKS4: the proxy rejected the request for %s:%u", dest ? dest : "?", (unsigned)dest_port);
        else
            log_message("SOCKS4: no usable reply for %s:%u", dest ? dest : "?", (unsigned)dest_port);
        return -1;
    }

    return 0;
}
