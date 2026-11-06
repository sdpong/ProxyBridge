#include "pb_internal.h"

// The DNS policy layer.
//
// Without it the engine snoops the answers of the application's own DNS queries
// and reuses the names it finds there, so a proxy server sees a name whenever
// the cache happens to hold one. The policy gives the user a say over that:
// which names may become proxy destinations at all, which resolver answers, and
// whether the proxy server or the local resolver resolves the name.
//
// The model is the one the macOS app uses, so the same settings mean the same
// thing on both platforms. The one place where they cannot agree is written
// down in docs/FORK-NOTES.md: on macOS the system extension can answer an
// application's query itself, on Windows the application always asks its own
// resolver first, so a configured resolver decides what the *proxy* is told
// rather than what the application is told.

// what the transparent proxy hands to the proxy server
#define PB_DNS_ADDR_DEFAULT 0  // the per-proxy setting decides
#define PB_DNS_ADDR_ADDRESS 1  // send the address
#define PB_DNS_ADDR_HOSTNAME 2 // send the name

// how long a name resolved by the engine stays usable. The engine resolves a
// name only in local mode, and only to learn which address the proxy server
// should connect to, so a short life is enough and keeps the resolver quiet.
#define PB_DNS_RESOLVE_TTL_MS 60000
#define PB_DNS_RESOLVE_BUCKETS 256
#define PB_DNS_RESOLVE_TIMEOUT_MS 1500

// the resolved-name cache. It exists so a burst of connections to the same host
// does not turn into a burst of DNS queries.
typedef struct PB_DNS_RESOLVED {
    char   name[PB_DNS_NAME_MAX];
    UINT32 ip;
    ULONGLONG expire_tick;
    struct PB_DNS_RESOLVED *next;
} PB_DNS_RESOLVED;

// The policy, its locks and the resolved-name table are ready the moment the module
// is loaded. Initializing them at run time would leave a window in which one thread
// takes a lock another thread is still initializing, so they are initialized here.
static PB_DNS_POLICY     g_dns_policy = { PB_DNS_MODE_SYSTEM, FALSE, TRUE, 0, {{0}}, 0, {{0}} };
static SRWLOCK            g_dns_policy_lock = SRWLOCK_INIT;
static PB_DNS_RESOLVED  *g_dns_resolved[PB_DNS_RESOLVE_BUCKETS];
static SRWLOCK            g_dns_resolved_lock = SRWLOCK_INIT;

// What the proxy server is told about the destination. The relay fills this in
// before the handshake and clears it afterwards. It is per thread because every
// connection is handled by its own thread.
__declspec(thread) int g_tl_dns_mode = PB_DNS_ADDR_DEFAULT;
__declspec(thread) const char *g_tl_dns_name = NULL;

void dns_policy_init(void)
{
    // Nothing to do: see the comment above. The function stays because the callers
    // use it as the place where that guarantee is stated.
}

// ---- the policy itself -------------------------------------------------

BOOL dns_policy_set(const PB_DNS_POLICY *policy)
{
    if (policy == NULL) return FALSE;
    dns_policy_init();

    PB_DNS_POLICY copy = *policy;
    // the counts are bounded, but a caller could still hand over a broken one
    if (copy.excluded_count < 0) copy.excluded_count = 0;
    if (copy.excluded_count > PB_DNS_MAX_EXCLUDED) copy.excluded_count = PB_DNS_MAX_EXCLUDED;
    if (copy.resolver_count < 0) copy.resolver_count = 0;
    if (copy.resolver_count > PB_DNS_MAX_RESOLVERS) copy.resolver_count = PB_DNS_MAX_RESOLVERS;
    if (copy.mode > PB_DNS_MODE_REMOTE) copy.mode = PB_DNS_MODE_SYSTEM;

    AcquireSRWLockExclusive(&g_dns_policy_lock);
    g_dns_policy = copy;
    ReleaseSRWLockExclusive(&g_dns_policy_lock);

    // the resolved names were looked up through the old resolver, they cannot be
    // trusted any more
    AcquireSRWLockExclusive(&g_dns_resolved_lock);
    for (int i = 0; i < PB_DNS_RESOLVE_BUCKETS; i++)
    {
        PB_DNS_RESOLVED *e = g_dns_resolved[i];
        while (e)
        {
            PB_DNS_RESOLVED *next = e->next;
            free(e);
            e = next;
        }
        g_dns_resolved[i] = NULL;
    }
    ReleaseSRWLockExclusive(&g_dns_resolved_lock);

    log_message("DNS policy: mode %s, %d excluded name(s), %d resolver(s)",
        copy.mode == PB_DNS_MODE_LOCAL ? "local" : (copy.mode == PB_DNS_MODE_REMOTE ? "remote" : "system"),
        copy.excluded_count, copy.resolver_count);
    return TRUE;
}

void dns_policy_get(PB_DNS_POLICY *out)
{
    if (out == NULL) return;
    dns_policy_init();
    AcquireSRWLockShared(&g_dns_policy_lock);
    *out = g_dns_policy;
    ReleaseSRWLockShared(&g_dns_policy_lock);
}

// ---- matching ----------------------------------------------------------

// lower cases a name and drops the leading and trailing dots, so
// "Example.COM." and "example.com" are the same name. The dots inside a name
// stay where they are, they carry the structure of the name.
static void dns_policy_fold(char *s)
{
    if (s == NULL) return;
    char *r = s;
    const char *w = s;
    while (*w == '.') w++;                 // the leading dots
    while (*w)
    {
        char c = *w++;
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        *r++ = c;
    }
    while (r > s && r[-1] == '.') r--;     // the trailing dots
    *r = '\0';
}

// matches one exclusion pattern against a name. both are compared in lower
// case. "example.com" matches that name only, "*.example.com" matches every
// name below it but not the name itself, "*" matches everything.
BOOL dns_policy_matches(const char *pattern, const char *name)
{
    if (pattern == NULL || name == NULL) return FALSE;

    char p[PB_DNS_NAME_MAX];
    char n[PB_DNS_NAME_MAX];
    strncpy_s(p, sizeof(p), pattern, _TRUNCATE);
    strncpy_s(n, sizeof(n), name, _TRUNCATE);
    dns_policy_fold(p);
    dns_policy_fold(n);

    if (p[0] == '\0' || n[0] == '\0') return FALSE;
    if (strcmp(p, "*") == 0) return TRUE;
    if (p[0] == '*' && p[1] == '.')
    {
        const char *suffix = p + 2;
        if (suffix[0] == '\0') return FALSE;
        size_t sl = strlen(suffix);
        size_t nl = strlen(n);
        // the name must be below the suffix, so it needs the dot as well
        if (nl <= sl) return FALSE;
        return _stricmp(n + nl - sl, suffix) == 0 && n[nl - sl - 1] == '.';
    }
    return strcmp(p, n) == 0;
}

BOOL dns_policy_is_excluded(const char *domain)
{
    if (domain == NULL || domain[0] == '\0') return FALSE;
    dns_policy_init();

    char name[PB_DNS_NAME_MAX];
    strncpy_s(name, sizeof(name), domain, _TRUNCATE);
    dns_policy_fold(name);
    if (name[0] == '\0') return FALSE;

    AcquireSRWLockShared(&g_dns_policy_lock);
    BOOL hit = FALSE;
    for (int i = 0; i < g_dns_policy.excluded_count && !hit; i++)
        hit = dns_policy_matches(g_dns_policy.excluded[i], name);
    ReleaseSRWLockShared(&g_dns_policy_lock);
    return hit;
}

// what the transparent proxy hands to the proxy server for this name.
int dns_policy_addressing(const char *domain)
{
    dns_policy_init();

    if (domain == NULL || domain[0] == '\0') return PB_DNS_ADDR_ADDRESS;

    AcquireSRWLockShared(&g_dns_policy_lock);
    PB_DNS_POLICY p = g_dns_policy;
    ReleaseSRWLockShared(&g_dns_policy_lock);

    // an excluded name never becomes a proxy destination
    if (dns_policy_is_excluded(domain)) return PB_DNS_ADDR_ADDRESS;
    // leak protection wins over every other setting: the proxy server resolves
    // the name, so the address the local resolver produced can never be the
    // address the proxy connects to
    if (p.leak_protection) return PB_DNS_ADDR_HOSTNAME;
    switch (p.mode)
    {
        case PB_DNS_MODE_LOCAL:  return PB_DNS_ADDR_ADDRESS;
        case PB_DNS_MODE_REMOTE: return PB_DNS_ADDR_HOSTNAME;
        default:                 return PB_DNS_ADDR_DEFAULT;
    }
}

// ---- resolvers ---------------------------------------------------------

// splits "1.1.1.1" or "1.1.1.1:5353" into a host and a port. the default port
// is 53, which is what a resolver listens on unless it says otherwise.
BOOL dns_policy_normalize_resolver(const char *raw, char *host, size_t host_cap, UINT16 *port)
{
    if (raw == NULL || host == NULL || host_cap == 0) return FALSE;

    char buf[PB_DNS_NAME_MAX];
    strncpy_s(buf, sizeof(buf), raw, _TRUNCATE);

    // trim the blanks on both ends
    char *s = buf;
    while (*s == ' ' || *s == '\t') s++;
    size_t len = strlen(s);
    while (len > 0 && (s[len - 1] == ' ' || s[len - 1] == '\t')) s[--len] = '\0';
    if (s[0] == '\0') return FALSE;

    // an ipv6 literal has colons of its own, so only split on the last one and
    // only when there is exactly one
    int colons = 0;
    for (const char *q = s; *q; q++) if (*q == ':') colons++;
    char *colon = strrchr(s, ':');
    if (colon != NULL && colons == 1)
    {
        *colon = '\0';
        unsigned long p = strtoul(colon + 1, NULL, 10);
        if (p == 0 || p > 65535) return FALSE;
        if (port) *port = (UINT16)p;
    }
    else if (port)
    {
        *port = 53;
    }

    if (s[0] == '\0') return FALSE;
    strncpy_s(host, host_cap, s, _TRUNCATE);
    return TRUE;
}

// the resolver to ask. the configured ones come first, the resolver the system
// uses is the fallback when auto detection is on.
BOOL dns_policy_preferred_resolver(char *host, size_t host_cap, UINT16 *port)
{
    dns_policy_init();

    AcquireSRWLockShared(&g_dns_policy_lock);
    PB_DNS_POLICY p = g_dns_policy;
    ReleaseSRWLockShared(&g_dns_policy_lock);

    for (int i = 0; i < p.resolver_count; i++)
    {
        char h[PB_DNS_NAME_MAX];
        UINT16 pt = 53;
        if (!dns_policy_normalize_resolver(p.resolvers[i], h, sizeof(h), &pt)) continue;
        if (port) *port = pt;
        if (host) strncpy_s(host, host_cap, h, _TRUNCATE);
        return TRUE;
    }

    if (!p.auto_detect_upstream) return FALSE;

    // the resolver the system uses. GetNetworkParams hands back the servers of
    // every adapter, the first one is good enough.
    FIXED_INFO info;
    ULONG size = sizeof(info);
    if (GetNetworkParams(&info, &size) == ERROR_SUCCESS && info.DnsServerList.IpAddress[0] != 0)
    {
        char h[PB_DNS_NAME_MAX];
        UINT16 pt = 53;
        if (!dns_policy_normalize_resolver(info.DnsServerList.IpAddress[0], h, sizeof(h), &pt)) return FALSE;
        if (port) *port = pt;
        if (host) strncpy_s(host, host_cap, h, _TRUNCATE);
        return TRUE;
    }
    return FALSE;
}

// ---- resolving a name through the chosen resolver -----------------------

// builds a DNS query for one A record.
int dns_policy_build_query(const char *name, UINT8 *out, int cap)
{
    if (name == NULL || out == NULL || cap < 12) return -1;

    size_t nlen = strlen(name);
    if (nlen == 0 || nlen > 240) return -1;
    int len = 12 + (int)nlen + 2 + 4;   // header, the name in label form, QTYPE, QCLASS
    if (len > cap) return -1;

    int o = 0;
    out[o++] = (UINT8)(GetTickCount() & 0xFF);          // id, only used to match the answer
    out[o++] = (UINT8)((GetTickCount() >> 8) & 0xFF);
    out[o++] = 0x01;                                    // flags: recursion desired
    out[o++] = 0x00;
    out[o++] = 0x00; out[o++] = 0x01;                   // one question
    out[o++] = 0x00; out[o++] = 0x00;                   // no answers yet
    out[o++] = 0x00; out[o++] = 0x00;                   // no authority records
    out[o++] = 0x00; out[o++] = 0x00;                   // no additional records

    const char *p = name;
    while (*p)
    {
        const char *dot = strchr(p, '.');
        size_t label = dot ? (size_t)(dot - p) : strlen(p);
        if (label == 0 || label > 63) return -1;
        out[o++] = (UINT8)label;
        memcpy(out + o, p, label);
        o += (int)label;
        if (!dot) break;
        p = dot + 1;
        if (*p == '\0') return -1;                       // a trailing dot is not accepted here
    }
    out[o++] = 0x00;                                    // the end of the name

    out[o++] = 0x00; out[o++] = 0x01;                   // QTYPE = A
    out[o++] = 0x00; out[o++] = 0x01;                   // QCLASS = IN
    return o;
}

// reads the A record out of a DNS answer.
BOOL dns_policy_parse_answer(const UINT8 *msg, int msg_len, UINT32 *out_ip)
{
    if (msg == NULL || out_ip == NULL || msg_len < 12) return FALSE;

    UINT16 flags = ((UINT16)msg[2] << 8) | msg[3];
    if (!(flags & 0x8000)) return FALSE;                 // not a response
    if (flags & 0x000F) return FALSE;                    // RCODE != NOERROR

    UINT16 qdcount = ((UINT16)msg[4] << 8) | msg[5];
    UINT16 ancount = ((UINT16)msg[6] << 8) | msg[7];
    if (qdcount == 0 || ancount == 0) return FALSE;

    int offset = 12;
    for (int q = 0; q < qdcount; q++)
    {
        char tmp[PB_DNS_NAME_MAX];
        if (!dns_parse_name(msg, msg_len, &offset, tmp, sizeof(tmp))) return FALSE;
        offset += 4;                                     // QTYPE + QCLASS
    }

    for (int i = 0; i < ancount && offset < msg_len; i++)
    {
        char rname[PB_DNS_NAME_MAX];
        if (!dns_parse_name(msg, msg_len, &offset, rname, sizeof(rname))) return FALSE;
        if (offset + 10 > msg_len) return FALSE;
        UINT16 rtype  = ((UINT16)msg[offset + 0] << 8) | msg[offset + 1];
        UINT16 rclass = ((UINT16)msg[offset + 2] << 8) | msg[offset + 3];
        UINT16 rdlen  = ((UINT16)msg[offset + 8] << 8) | msg[offset + 9];
        offset += 10;
        if (offset + rdlen > msg_len) return FALSE;
        if (rtype == 1 && rclass == 1 && rdlen == 4)
        {
            memcpy(out_ip, msg + offset, 4);             // network byte order, like every other address here
            return TRUE;
        }
        offset += rdlen;
    }
    return FALSE;
}

// the cache of names the engine resolved itself.
static UINT32 dns_policy_resolved_bucket(const char *name)
{
    UINT32 h = 2166136261u;
    for (const char *q = name; *q; q++) h = (h ^ (UINT8)*q) * 16777619u;
    return h & (PB_DNS_RESOLVE_BUCKETS - 1);
}

static BOOL dns_policy_resolved_lookup(const char *name, UINT32 *out_ip)
{
    ULONGLONG now = GetTickCount64();
    BOOL found = FALSE;
    AcquireSRWLockShared(&g_dns_resolved_lock);
    PB_DNS_RESOLVED *e = g_dns_resolved[dns_policy_resolved_bucket(name)];
    while (e)
    {
        if (strcmp(e->name, name) == 0 && e->expire_tick > now)
        {
            *out_ip = e->ip;
            found = TRUE;
            break;
        }
        e = e->next;
    }
    ReleaseSRWLockShared(&g_dns_resolved_lock);
    return found;
}

static void dns_policy_resolved_store(const char *name, UINT32 ip)
{
    UINT32 bucket = dns_policy_resolved_bucket(name);
    ULONGLONG now = GetTickCount64();
    AcquireSRWLockExclusive(&g_dns_resolved_lock);
    PB_DNS_RESOLVED *e = g_dns_resolved[bucket];
    while (e)
    {
        if (strcmp(e->name, name) == 0)
        {
            e->ip = ip;
            e->expire_tick = now + PB_DNS_RESOLVE_TTL_MS;
            ReleaseSRWLockExclusive(&g_dns_resolved_lock);
            return;
        }
        e = e->next;
    }
    PB_DNS_RESOLVED *ne = (PB_DNS_RESOLVED *)malloc(sizeof(PB_DNS_RESOLVED));
    if (ne)
    {
        strncpy_s(ne->name, sizeof(ne->name), name, _TRUNCATE);
        ne->ip = ip;
        ne->expire_tick = now + PB_DNS_RESOLVE_TTL_MS;
        ne->next = g_dns_resolved[bucket];
        g_dns_resolved[bucket] = ne;
    }
    ReleaseSRWLockExclusive(&g_dns_resolved_lock);
}

// asks one resolver for the A record of a name.
BOOL dns_policy_query_resolver(const char *name, const char *resolver_host, UINT16 resolver_port, UINT32 *out_ip)
{
    if (name == NULL || resolver_host == NULL || out_ip == NULL) return FALSE;

    UINT8 query[512];
    int qlen = dns_policy_build_query(name, query, sizeof(query));
    if (qlen < 0) return FALSE;

    UINT32 resolver_ip = parse_ipv4(resolver_host);
    if (resolver_ip == 0) resolver_ip = resolve_hostname(resolver_host);
    if (resolver_ip == 0) return FALSE;

    SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) return FALSE;

    DWORD to = PB_DNS_RESOLVE_TIMEOUT_MS;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&to, sizeof(to));

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(resolver_port ? resolver_port : 53);
    dst.sin_addr.s_addr = resolver_ip;

    BOOL ok = FALSE;
    if (sendto(s, (const char *)query, qlen, 0, (struct sockaddr *)&dst, sizeof(dst)) == qlen)
    {
        UINT8 answer[1500];
        int got = recv(s, (char *)answer, sizeof(answer), 0);
        if (got > 0)
        {
            // the answer must carry the id of the question, otherwise it belongs
            // to another query that was in flight at the same time
            if (answer[0] == query[0] && answer[1] == query[1])
                ok = dns_policy_parse_answer(answer, got, out_ip);
        }
    }
    closesocket(s);
    return ok;
}

// the address the proxy server should connect to for this name. the name is
// resolved through the resolver the policy chose, so the proxy lands on the
// address that resolver believes in and not on the one the application's own
// resolver produced.
BOOL dns_policy_resolve_for_proxy(const char *name, UINT32 *out_ip)
{
    if (name == NULL || out_ip == NULL || name[0] == '\0') return FALSE;

    if (dns_policy_resolved_lookup(name, out_ip)) return TRUE;

    char host[PB_DNS_NAME_MAX];
    UINT16 port = 53;
    if (!dns_policy_preferred_resolver(host, sizeof(host), &port)) return FALSE;

    UINT32 ip = 0;
    if (!dns_policy_query_resolver(name, host, port, &ip)) return FALSE;

    dns_policy_resolved_store(name, ip);
    *out_ip = ip;
    return TRUE;
}

// ---- the exported API --------------------------------------------------

PROXYBRIDGE_API BOOL ProxyBridge_SetDNSPolicy(const PBDnsPolicy *policy)
{
    if (policy == NULL) return FALSE;
    dns_policy_init();

    PB_DNS_POLICY p;
    ZeroMemory(&p, sizeof(p));
    p.mode = (policy->mode <= PB_DNS_MODE_REMOTE) ? policy->mode : PB_DNS_MODE_SYSTEM;
    p.leak_protection = policy->leakProtection ? TRUE : FALSE;
    p.auto_detect_upstream = policy->autoDetectUpstream ? TRUE : FALSE;
    p.excluded_count = (int)policy->excludedCount;
    p.resolver_count = (int)policy->resolverCount;
    if (p.excluded_count > PB_DNS_MAX_EXCLUDED) p.excluded_count = PB_DNS_MAX_EXCLUDED;
    if (p.resolver_count > PB_DNS_MAX_RESOLVERS) p.resolver_count = PB_DNS_MAX_RESOLVERS;
    for (int i = 0; i < p.excluded_count; i++)
        strncpy_s(p.excluded[i], sizeof(p.excluded[i]), policy->excluded[i], _TRUNCATE);
    for (int i = 0; i < p.resolver_count; i++)
        strncpy_s(p.resolvers[i], sizeof(p.resolvers[i]), policy->resolvers[i], _TRUNCATE);

    return dns_policy_set(&p);
}

PROXYBRIDGE_API BOOL ProxyBridge_GetDNSPolicy(PBDnsPolicy *policy)
{
    if (policy == NULL) return FALSE;
    dns_policy_init();

    PB_DNS_POLICY p;
    dns_policy_get(&p);
    ZeroMemory(policy, sizeof(*policy));
    policy->mode = p.mode;
    policy->leakProtection = p.leak_protection ? 1 : 0;
    policy->autoDetectUpstream = p.auto_detect_upstream ? 1 : 0;
    policy->excludedCount = (UINT32)(p.excluded_count > 0 ? p.excluded_count : 0);
    policy->resolverCount = (UINT32)(p.resolver_count > 0 ? p.resolver_count : 0);
    for (int i = 0; i < (int)policy->excludedCount; i++)
        strncpy_s(policy->excluded[i], sizeof(policy->excluded[i]), p.excluded[i], _TRUNCATE);
    for (int i = 0; i < (int)policy->resolverCount; i++)
        strncpy_s(policy->resolvers[i], sizeof(policy->resolvers[i]), p.resolvers[i], _TRUNCATE);
    return TRUE;
}
