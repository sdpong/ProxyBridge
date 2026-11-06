// test_dnspolicy.c - the DNS policy layer: the three resolution modes, the exclusion
// list, the resolver choice, the leak protection switch, the query builder and the
// answer parser.
//
// The cases are the same ones the macOS logic tests run, so the two platforms cannot
// drift apart. What cannot be shared is the platform difference itself: on macOS the
// system extension answers the application's query, on Windows the application always
// asks its own resolver first. That difference is written down in docs/FORK-NOTES.md.
#include "pb_internal.h"
#include "pbtest.h"

static PB_DNS_POLICY MakePolicy(UINT32 mode, BOOL leak, const char* const* excluded, int nEx,
                                const char* const* resolvers, int nRes)
{
    PB_DNS_POLICY p;
    ZeroMemory(&p, sizeof(p));
    p.mode = mode;
    p.leak_protection = leak;
    p.auto_detect_upstream = TRUE;
    p.excluded_count = nEx;
    for (int i = 0; i < nEx; i++) strncpy_s(p.excluded[i], sizeof(p.excluded[i]), excluded[i], _TRUNCATE);
    p.resolver_count = nRes;
    for (int i = 0; i < nRes; i++) strncpy_s(p.resolvers[i], sizeof(p.resolvers[i]), resolvers[i], _TRUNCATE);
    return p;
}

int main(void)
{
    dns_policy_init();

    // ── the default policy ─────────────────────────────────────────────────────
    {
        PB_DNS_POLICY p;
        dns_policy_get(&p);
        CHECK(p.mode == PB_DNS_MODE_SYSTEM);
        CHECK(!dns_policy_is_excluded("example.com"));
        CHECK(dns_policy_addressing("example.com") == PB_DNS_ADDR_DEFAULT);
    }

    // ── what the proxy server is told, per mode ────────────────────────────────
    {
        PB_DNS_POLICY p = MakePolicy(PB_DNS_MODE_SYSTEM, FALSE, NULL, 0, NULL, 0);
        CHECK(dns_policy_set(&p));
        CHECK(dns_policy_addressing("example.com") == PB_DNS_ADDR_DEFAULT);

        p = MakePolicy(PB_DNS_MODE_LOCAL, FALSE, NULL, 0, NULL, 0);
        CHECK(dns_policy_set(&p));
        CHECK(dns_policy_addressing("example.com") == PB_DNS_ADDR_ADDRESS);

        p = MakePolicy(PB_DNS_MODE_REMOTE, FALSE, NULL, 0, NULL, 0);
        CHECK(dns_policy_set(&p));
        CHECK(dns_policy_addressing("example.com") == PB_DNS_ADDR_HOSTNAME);
    }

    // ── the exclusion list ─────────────────────────────────────────────────────
    {
        const char* excl[] = { "example.com", "*.internal.corp" };
        PB_DNS_POLICY p = MakePolicy(PB_DNS_MODE_SYSTEM, FALSE, excl, 2, NULL, 0);
        CHECK(dns_policy_set(&p));
        CHECK(dns_policy_is_excluded("example.com"));
        CHECK(dns_policy_is_excluded("EXAMPLE.COM"));            // the list is not case sensitive
        CHECK(dns_policy_is_excluded("example.com."));           // a trailing dot does not hide the name
        CHECK(!dns_policy_is_excluded("other.test"));
        CHECK(dns_policy_is_excluded("host.internal.corp"));    // a wildcard in the list works
        CHECK(dns_policy_addressing("example.com") == PB_DNS_ADDR_ADDRESS);
    }

    // a wildcard covers the names below it, but not the name itself
    {
        const char* excl[] = { "*.example.com" };
        PB_DNS_POLICY p = MakePolicy(PB_DNS_MODE_SYSTEM, FALSE, excl, 1, NULL, 0);
        CHECK(dns_policy_set(&p));
        CHECK(dns_policy_is_excluded("www.example.com"));
        CHECK(dns_policy_is_excluded("a.b.example.com"));
        CHECK(!dns_policy_is_excluded("example.com"));
        CHECK(!dns_policy_is_excluded("example.org"));
        CHECK(!dns_policy_is_excluded("notexample.com"));
    }

    // a bare name covers only itself
    {
        const char* excl[] = { "example.com" };
        PB_DNS_POLICY p = MakePolicy(PB_DNS_MODE_SYSTEM, FALSE, excl, 1, NULL, 0);
        CHECK(dns_policy_set(&p));
        CHECK(dns_policy_is_excluded("example.com"));
        CHECK(!dns_policy_is_excluded("www.example.com"));
    }

    // the star covers everything
    {
        const char* excl[] = { "*" };
        PB_DNS_POLICY p = MakePolicy(PB_DNS_MODE_SYSTEM, FALSE, excl, 1, NULL, 0);
        CHECK(dns_policy_set(&p));
        CHECK(dns_policy_is_excluded("example.com"));
        CHECK(dns_policy_is_excluded("a.b.c.test"));
    }

    // an empty pattern excludes nothing
    {
        const char* excl[] = { "", "   " };
        PB_DNS_POLICY p = MakePolicy(PB_DNS_MODE_SYSTEM, FALSE, excl, 2, NULL, 0);
        CHECK(dns_policy_set(&p));
        CHECK(!dns_policy_is_excluded("example.com"));
    }

    // an excluded name wins over leak protection
    {
        const char* excl[] = { "example.com" };
        PB_DNS_POLICY p = MakePolicy(PB_DNS_MODE_REMOTE, TRUE, excl, 1, NULL, 0);
        CHECK(dns_policy_set(&p));
        CHECK(dns_policy_is_excluded("example.com"));
        CHECK(dns_policy_addressing("example.com") == PB_DNS_ADDR_ADDRESS);
    }

    // ── leak protection ────────────────────────────────────────────────────────
    {
        PB_DNS_POLICY p = MakePolicy(PB_DNS_MODE_LOCAL, TRUE, NULL, 0, NULL, 0);
        CHECK(dns_policy_set(&p));
        CHECK(dns_policy_addressing("example.com") == PB_DNS_ADDR_HOSTNAME);
        p = MakePolicy(PB_DNS_MODE_SYSTEM, TRUE, NULL, 0, NULL, 0);
        CHECK(dns_policy_set(&p));
        CHECK(dns_policy_addressing("example.com") == PB_DNS_ADDR_HOSTNAME);
    }

    // a name that is not known cannot be anything but an address
    {
        PB_DNS_POLICY p = MakePolicy(PB_DNS_MODE_REMOTE, FALSE, NULL, 0, NULL, 0);
        CHECK(dns_policy_set(&p));
        CHECK(dns_policy_addressing(NULL) == PB_DNS_ADDR_ADDRESS);
        CHECK(dns_policy_addressing("") == PB_DNS_ADDR_ADDRESS);
    }

    // ── the resolvers ──────────────────────────────────────────────────────────
    {
        char host[256];
        UINT16 port = 0;
        CHECK(dns_policy_normalize_resolver("1.1.1.1", host, sizeof(host), &port));
        CHECK(strcmp(host, "1.1.1.1") == 0 && port == 53);
        CHECK(dns_policy_normalize_resolver(" 8.8.8.8:5353 ", host, sizeof(host), &port));
        CHECK(strcmp(host, "8.8.8.8") == 0 && port == 5353);
        CHECK(!dns_policy_normalize_resolver("  ", host, sizeof(host), &port));
        CHECK(!dns_policy_normalize_resolver("1.1.1.1:abc", host, sizeof(host), &port));
        CHECK(!dns_policy_normalize_resolver("1.1.1.1:0", host, sizeof(host), &port));
        CHECK(!dns_policy_normalize_resolver("1.1.1.1:70000", host, sizeof(host), &port));
        // an ipv6 literal has colons of its own, so it is not split
        CHECK(dns_policy_normalize_resolver("fe80::1", host, sizeof(host), &port));
        CHECK(strcmp(host, "fe80::1") == 0 && port == 53);
    }

    // the configured resolver comes first, the system's is the fallback
    {
        const char* res[] = { "1.1.1.1", "8.8.8.8" };
        PB_DNS_POLICY p = MakePolicy(PB_DNS_MODE_LOCAL, FALSE, NULL, 0, res, 2);
        CHECK(dns_policy_set(&p));
        char host[256];
        UINT16 port = 0;
        CHECK(dns_policy_preferred_resolver(host, sizeof(host), &port));
        CHECK(strcmp(host, "1.1.1.1") == 0 && port == 53);
    }

    // ── the query builder ──────────────────────────────────────────────────────
    {
        UINT8 q[512];
        int n = dns_policy_build_query("example.com", q, sizeof(q));
        CHECK(n == 29);
        CHECK(q[0] != 0 || q[1] != 0);                          // some id
        CHECK(q[2] == 0x01);                                    // recursion desired
        CHECK(q[5] == 0x01);                                    // one question
        CHECK(q[7] == 0x00);                                    // no answers yet
        CHECK(q[12] == 7 && memcmp(q + 13, "example", 7) == 0);
        CHECK(q[20] == 3 && memcmp(q + 21, "com", 3) == 0);
        CHECK(q[24] == 0);                                      // the end of the name
        CHECK(q[25] == 0 && q[26] == 0x01);                     // QTYPE = A
        CHECK(q[27] == 0 && q[28] == 0x01);                     // QCLASS = IN

        // a name that cannot be asked for is refused before anything is sent
        CHECK(dns_policy_build_query("", q, sizeof(q)) == -1);
        CHECK(dns_policy_build_query("example.com.", q, sizeof(q)) == -1);
        CHECK(dns_policy_build_query("a..b", q, sizeof(q)) == -1);
        CHECK(dns_policy_build_query(NULL, q, sizeof(q)) == -1);
        char longname[300]; memset(longname, 'a', sizeof(longname) - 1); longname[sizeof(longname) - 1] = 0;
        CHECK(dns_policy_build_query(longname, q, sizeof(q)) == -1);
    }

    // ── the answer parser ──────────────────────────────────────────────────────
    {
        // a well formed answer: the question and one A record with a name pointer
        const UINT8 answer[] = {
            0x12, 0x34,             // id
            0x81, 0x80,             // response, no error
            0x00, 0x01,             // one question
            0x00, 0x01,             // one answer
            0x00, 0x00, 0x00, 0x00, // no authority or additional records
            0x07, 'e','x','a','m','p','l','e',
            0x03, 'c','o','m',
            0x00,
            0x00, 0x01,             // QTYPE = A
            0x00, 0x01,             // QCLASS = IN
            0xC0, 0x0C,             // the answer name points at the question
            0x00, 0x01,             // TYPE = A
            0x00, 0x01,             // CLASS = IN
            0x00, 0x00, 0x00, 0x3C, // TTL
            0x00, 0x04,             // RDLENGTH
            0x5D, 0xB8, 0xD8, 0x22  // 93.184.216.34
        };
        UINT32 ip = 0;
        CHECK(dns_policy_parse_answer(answer, (int)sizeof(answer), &ip));
        CHECK(ip == 0x22D8B85Du);          // network byte order, like every other address here

        // a question is not an answer
        UINT8 query[64];
        int qlen = dns_policy_build_query("example.com", query, sizeof(query));
        CHECK(qlen > 0);
        CHECK(!dns_policy_parse_answer(query, qlen, &ip));

        // NXDOMAIN carries no address
        UINT8 nx[64];
        memcpy(nx, answer, sizeof(answer));
        nx[2] = 0x81; nx[3] = 0x83;        // RCODE = NXDOMAIN
        CHECK(!dns_policy_parse_answer(nx, (int)sizeof(nx), &ip));

        // a truncated answer must not be read past its end
        CHECK(!dns_policy_parse_answer(answer, 20, &ip));
        CHECK(!dns_policy_parse_answer(answer, 0, &ip));
        CHECK(!dns_policy_parse_answer(NULL, 10, &ip));
    }

    // ── the pattern matcher on its own ─────────────────────────────────────────
    {
        CHECK(dns_policy_matches("example.com", "example.com"));
        CHECK(dns_policy_matches("EXAMPLE.com", "example.COM"));
        CHECK(dns_policy_matches("*.example.com", "a.example.com"));
        CHECK(!dns_policy_matches("*.example.com", "example.com"));
        CHECK(!dns_policy_matches("", "example.com"));
        CHECK(!dns_policy_matches(NULL, "example.com"));
        CHECK(dns_policy_matches("*", "anything.at.all"));
    }

    // ── the exported API ───────────────────────────────────────────────────────
    {
        DnsPolicy wire;
        ZeroMemory(&wire, sizeof(wire));
        wire.mode = PB_DNS_MODE_REMOTE;
        wire.leakProtection = 1;
        wire.autoDetectUpstream = 0;
        wire.excludedCount = 2;
        wire.resolverCount = 1;
        strncpy_s(wire.excluded[0], sizeof(wire.excluded[0]), "a.test", _TRUNCATE);
        strncpy_s(wire.excluded[1], sizeof(wire.excluded[1]), "*.b.test", _TRUNCATE);
        strncpy_s(wire.resolvers[0], sizeof(wire.resolvers[0]), "9.9.9.9", _TRUNCATE);
        CHECK(ProxyBridge_SetDNSPolicy(&wire));

        DnsPolicy back;
        ZeroMemory(&back, sizeof(back));
        CHECK(ProxyBridge_GetDNSPolicy(&back));
        CHECK(back.mode == PB_DNS_MODE_REMOTE);
        CHECK(back.leakProtection == 1);
        CHECK(back.autoDetectUpstream == 0);
        CHECK(back.excludedCount == 2);
        CHECK(back.resolverCount == 1);
        CHECK(strcmp(back.excluded[0], "a.test") == 0);
        CHECK(strcmp(back.excluded[1], "*.b.test") == 0);
        CHECK(strcmp(back.resolvers[0], "9.9.9.9") == 0);
        CHECK(dns_policy_is_excluded("a.test"));
        CHECK(dns_policy_is_excluded("x.b.test"));
        CHECK(dns_policy_addressing("example.com") == PB_DNS_ADDR_HOSTNAME);

        // an unknown mode falls back to the default rather than being taken
        DnsPolicy odd = wire;
        odd.mode = 99;
        CHECK(ProxyBridge_SetDNSPolicy(&odd));
        ZeroMemory(&back, sizeof(back));
        CHECK(ProxyBridge_GetDNSPolicy(&back));
        CHECK(back.mode == PB_DNS_MODE_SYSTEM);
    }

    return pbtest_done("test_dnspolicy");
}
