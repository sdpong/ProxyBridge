#include "pb_internal.h"

// A proxy chain: the proxies a connection walks through, in order.
//
// A rule names a chain with the action RULE_ACTION_CHAIN and the chain's id in the
// proxy field. The chain ids live in a range of their own (PB_CHAIN_ID_BASE and up),
// so a chain and a proxy can never be mistaken for one another, whatever they are
// called. That is the same idea as the "chain:" prefix the macOS app uses, in the
// numeric shape the Windows rule model has.
//
// The rules about what may be in a chain come from the macOS implementation, so the
// two platforms accept and refuse the same chains:
//   - the chain needs at least one proxy
//   - every hop must be a proxy that exists
//   - only the last hop may be an http proxy: it opens a tunnel with a CONNECT, and
//     the reply can leave bytes behind that the next handshake would read as its own
//     answer
//   - the same proxy twice in a row is refused

static PROXY_CHAIN g_chains[MAX_CHAINS];
static int         g_chain_count = 0;
static SRWLOCK     g_chain_lock = SRWLOCK_INIT;

// The chain table lives in static storage, so it starts empty and needs no
// initialization. The lock is initialized statically for the same reason: a
// runtime InitializeSRWLock would leave a window where one thread waits on a
// lock another is still setting up.
void chain_init(void)
{
}

// The chain with this id, or NULL. The caller has to be quick about it: the table
// can change under it.
PROXY_CHAIN *find_chain(UINT32 chain_id)
{
    if (chain_id < PB_CHAIN_ID_BASE) return NULL;
    chain_init();
    AcquireSRWLockShared(&g_chain_lock);
    PROXY_CHAIN *found = NULL;
    for (int i = 0; i < g_chain_count; i++)
    {
        if (g_chains[i].chain_id == chain_id) { found = &g_chains[i]; break; }
    }
    ReleaseSRWLockShared(&g_chain_lock);
    return found;
}

// The problems a chain of these proxies has, written into out_message as one line
// each. Returns the number of problems, zero when the chain can work.
UINT32 chain_problems(const UINT32 *hop_ids, UINT32 hop_count, char *out_message, size_t cap)
{
    UINT32 problems = 0;
    size_t used = 0;
    if (out_message && cap > 0) out_message[0] = '\0';

    #define CHAIN_SAY(...) do {                                              \
        if (out_message && used + 1 < cap)                                   \
        {                                                                     \
            int n = _snprintf_s(out_message + used, cap - used, _TRUNCATE, __VA_ARGS__); \
            if (n > 0) used += (size_t)n;                                     \
        }                                                                     \
        problems++;                                                          \
    } while (0)

    if (hop_ids == NULL || hop_count == 0)
    {
        CHAIN_SAY("the chain has no proxy in it");
        return problems;
    }
    if (hop_count > MAX_CHAIN_HOPS)
    {
        CHAIN_SAY("a chain can hold at most %d proxies", MAX_CHAIN_HOPS);
        return problems;
    }

    for (UINT32 i = 0; i < hop_count; i++)
    {
        PROXY_CONFIG *hop = find_proxy_config(hop_ids[i]);
        if (hop == NULL)
        {
            CHAIN_SAY("proxy %u of the chain does not exist", (unsigned)(i + 1));
            continue;
        }
        if (hop->type != PROXY_TYPE_SOCKS5 && hop->type != PROXY_TYPE_SOCKS4 && hop->type != PROXY_TYPE_HTTP)
        {
            CHAIN_SAY("proxy %u of the chain has an unknown type", (unsigned)(i + 1));
            continue;
        }
        // only the last hop may be an http proxy
        if (hop->type == PROXY_TYPE_HTTP && i != hop_count - 1)
            CHAIN_SAY("proxy %u of the chain is an http proxy, only the last proxy of a chain may be one",
                      (unsigned)(i + 1));
    }

    for (UINT32 i = 1; i < hop_count; i++)
    {
        if (hop_ids[i] == hop_ids[i - 1])
        {
            CHAIN_SAY("the same proxy is used twice in a row");
            break;
        }
    }

    #undef CHAIN_SAY
    return problems;
}

static void chain_store(PROXY_CHAIN *slot, const char *name, const UINT32 *hop_ids, UINT32 hop_count)
{
    ZeroMemory(slot, sizeof(*slot));
    strncpy_s(slot->name, sizeof(slot->name), name ? name : "", _TRUNCATE);
    slot->hop_count = (int)hop_count;
    for (UINT32 i = 0; i < hop_count && i < MAX_CHAIN_HOPS; i++) slot->hop_ids[i] = hop_ids[i];
}

PROXYBRIDGE_API UINT32 ProxyBridge_AddChain(const char *name, const UINT32 *hop_ids, UINT32 hop_count)
{
    chain_init();
    if (hop_ids == NULL || hop_count == 0 || hop_count > MAX_CHAIN_HOPS) return 0;
    if (chain_problems(hop_ids, hop_count, NULL, 0) != 0) return 0;

    AcquireSRWLockExclusive(&g_chain_lock);
    if (g_chain_count >= MAX_CHAINS)
    {
        ReleaseSRWLockExclusive(&g_chain_lock);
        log_message("Chain: no room for another chain (the limit is %d)", MAX_CHAINS);
        return 0;
    }
    // the ids start above the proxy ids, so a chain and a proxy never share one
    UINT32 id = PB_CHAIN_ID_BASE + (UINT32)g_chain_count;
    for (int i = 0; i < g_chain_count; i++) if (g_chains[i].chain_id >= id) id = g_chains[i].chain_id + 1;
    chain_store(&g_chains[g_chain_count], name, hop_ids, hop_count);
    g_chains[g_chain_count].chain_id = id;
    g_chain_count++;
    ReleaseSRWLockExclusive(&g_chain_lock);

    log_message("Chain: added '%s' with %u proxy/proxies (id=%u)", name ? name : "", (unsigned)hop_count, (unsigned)id);
    return id;
}

PROXYBRIDGE_API BOOL ProxyBridge_EditChain(UINT32 chain_id, const char *name, const UINT32 *hop_ids, UINT32 hop_count)
{
    chain_init();
    if (hop_ids == NULL || hop_count == 0 || hop_count > MAX_CHAIN_HOPS) return FALSE;
    if (chain_problems(hop_ids, hop_count, NULL, 0) != 0) return FALSE;

    AcquireSRWLockExclusive(&g_chain_lock);
    BOOL ok = FALSE;
    for (int i = 0; i < g_chain_count; i++)
    {
        if (g_chains[i].chain_id != chain_id) continue;
        chain_store(&g_chains[i], name, hop_ids, hop_count);
        g_chains[i].chain_id = chain_id;
        ok = TRUE;
        break;
    }
    ReleaseSRWLockExclusive(&g_chain_lock);
    return ok;
}

PROXYBRIDGE_API BOOL ProxyBridge_DeleteChain(UINT32 chain_id)
{
    chain_init();
    AcquireSRWLockExclusive(&g_chain_lock);
    BOOL ok = FALSE;
    for (int i = 0; i < g_chain_count; i++)
    {
        if (g_chains[i].chain_id != chain_id) continue;
        for (int j = i; j < g_chain_count - 1; j++) g_chains[j] = g_chains[j + 1];
        g_chain_count--;
        ok = TRUE;
        break;
    }
    ReleaseSRWLockExclusive(&g_chain_lock);
    if (ok)
    {
        // the rules that named this chain now go direct, so nothing is left
        // pointing at something that does not exist
        rules_detach_chain(chain_id);
        log_message("Chain: deleted id=%u", chain_id);
    }
    return ok;
}

PROXYBRIDGE_API UINT32 ProxyBridge_ChainProblems(const UINT32 *hop_ids, UINT32 hop_count, char *out_message, size_t cap)
{
    return chain_problems(hop_ids, hop_count, out_message, cap);
}

// The hops of a chain, copied out. A caller that holds a pointer into the table can be
// looking at a chain that is being changed, so the hops are copied while the lock is held.
int chain_hops_of(UINT32 chain_id, UINT32 *out_hops, int max)
{
    int n = 0;
    if (chain_id < PB_CHAIN_ID_BASE || out_hops == NULL || max <= 0) return 0;
    AcquireSRWLockShared(&g_chain_lock);
    for (int i = 0; i < g_chain_count; i++)
    {
        if (g_chains[i].chain_id != chain_id) continue;
        n = g_chains[i].hop_count;
        if (n > max) n = max;
        for (int h = 0; h < n; h++) out_hops[h] = g_chains[i].hop_ids[h];
        break;
    }
    ReleaseSRWLockShared(&g_chain_lock);
    return n;
}

// Can this chain carry the traffic? It has to be there, it has to have hops, and
// every hop has to be a proxy that is still there. A rule that names a chain which
// cannot work sends its traffic direct, the way the macOS app does.
BOOL chain_usable(UINT32 chain_id)
{
    UINT32 hops[MAX_CHAIN_HOPS];
    int n = chain_hops_of(chain_id, hops, MAX_CHAIN_HOPS);
    if (n <= 0) return FALSE;
    for (int i = 0; i < n; i++)
        if (find_proxy_config(hops[i]) == NULL) return FALSE;
    return TRUE;
}

// The label of a chain for the connection log: the proxies it walks through, in order.
void chain_label(UINT32 chain_id, char *out, size_t cap)
{
    if (out == NULL || cap == 0) return;
    out[0] = '\0';
    UINT32 hops[MAX_CHAIN_HOPS];
    int n = chain_hops_of(chain_id, hops, MAX_CHAIN_HOPS);
    if (n <= 0) { strncpy_s(out, cap, "Chain", _TRUNCATE); return; }
    size_t used = 0;
    for (int i = 0; i < n; i++)
    {
        PROXY_CONFIG *hop = find_proxy_config(hops[i]);
        char one[96];
        if (hop != NULL)
            snprintf(one, sizeof(one), "%s://%s:%d", proxy_type_name(hop->type), hop->host, hop->port);
        else
            snprintf(one, sizeof(one), "?");
        // snprintf returns the length it wanted, so the room left is known even
        // when the text did not fit
        int wanted = snprintf(out + used, cap - used, "%s%s", used ? " -> " : "", one);
        if (wanted < 0) break;
        used += (size_t)wanted;
        if (used >= cap - 1) { out[cap - 1] = '\0'; break; }
    }
    if (used == 0) strncpy_s(out, cap, "Chain", _TRUNCATE);
}

PROXYBRIDGE_API UINT32 ProxyBridge_GetChains(PB_CHAIN *out, UINT32 max)
{
    chain_init();
    if (out == NULL || max == 0) return 0;
    AcquireSRWLockShared(&g_chain_lock);
    UINT32 n = 0;
    for (int i = 0; i < g_chain_count && n < max; i++)
    {
        PB_CHAIN *c = &out[n];
        ZeroMemory(c, sizeof(*c));
        c->id = g_chains[i].chain_id;
        c->hopCount = (UINT32)g_chains[i].hop_count;
        for (int h = 0; h < g_chains[i].hop_count && h < MAX_CHAIN_HOPS; h++) c->hops[h] = g_chains[i].hop_ids[h];
        strncpy_s(c->name, sizeof(c->name), g_chains[i].name, _TRUNCATE);
        n++;
    }
    ReleaseSRWLockShared(&g_chain_lock);
    return n;
}
