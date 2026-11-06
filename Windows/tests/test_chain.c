// test_chain.c - the proxy chains (src\pb_chain.c): what a chain may hold, the chain
// list itself, and the rules that walk through one.
//
// The rules about what may be in a chain are the ones the macOS app uses (ProxyChain.problems
// and ChainPlan.problems in the macOS sources), so a chain that Windows accepts is one the
// macOS extension can run, and the other way round.
#include "pb_internal.h"
#include "pbtest.h"

// The action a rule gets for this process, and the chain id it would walk through.
static RuleAction MatchChain(const char* proc, UINT32* out_chain_id)
{
    struct in_addr a; inet_pton(AF_INET, "203.0.113.7", &a);
    UINT32 id = 0;
    RuleAction act = match_rule(proc, a.S_un.S_addr, (UINT16)443, FALSE, &id);
    if (out_chain_id) *out_chain_id = id;
    return act;
}

int main(void)
{
    // three proxies to build chains from
    UINT32 socks5 = ProxyBridge_AddProxyConfig(PROXY_TYPE_SOCKS5, "127.0.0.1", 9101, NULL, NULL, TRUE);
    UINT32 socks4 = ProxyBridge_AddProxyConfig(PROXY_TYPE_SOCKS4, "127.0.0.1", 9102, NULL, NULL, TRUE);
    UINT32 http   = ProxyBridge_AddProxyConfig(PROXY_TYPE_HTTP,   "127.0.0.1", 9103, NULL, NULL, TRUE);
    CHECK(socks5 != 0 && socks4 != 0 && http != 0);
    if (!socks5 || !socks4 || !http) return pbtest_done("test_chain");

    char msg[1024];

    // ── what a chain may hold ─────────────────────────────────────────────────
    // a chain needs at least one proxy
    CHECK(chain_problems(NULL, 0, msg, sizeof(msg)) == 1);
    CHECK(strstr(msg, "no proxy") != NULL);
    CHECK(chain_problems(socks5 ? &socks5 : NULL, 0, msg, sizeof(msg)) == 1);

    // one proxy is a chain
    CHECK(chain_problems(&socks5, 1, msg, sizeof(msg)) == 0);
    CHECK(chain_problems(&socks4, 1, msg, sizeof(msg)) == 0);

    // two socks proxies in a row are fine
    { UINT32 hops[2] = { socks5, socks4 };
      CHECK(chain_problems(hops, 2, msg, sizeof(msg)) == 0); }

    // the same proxy twice in a row is not: the connection would go nowhere
    { UINT32 hops[2] = { socks5, socks5 };
      CHECK(chain_problems(hops, 2, msg, sizeof(msg)) == 1);
      CHECK(strstr(msg, "twice") != NULL); }

    // only the last proxy of a chain may be an http proxy: it opens a tunnel with a
    // CONNECT, and the reply can leave bytes behind that the next handshake reads
    { UINT32 hops[2] = { http, socks5 };
      CHECK(chain_problems(hops, 2, msg, sizeof(msg)) == 1);
      CHECK(strstr(msg, "http") != NULL); }
    { UINT32 hops[2] = { socks5, http };
      CHECK(chain_problems(hops, 2, msg, sizeof(msg)) == 0); }
    { UINT32 hops[3] = { socks5, http, socks5 };
      CHECK(chain_problems(hops, 3, msg, sizeof(msg)) == 1); }

    // a proxy that is not there
    { UINT32 hops[2] = { socks5, 987654 };
      CHECK(chain_problems(hops, 2, msg, sizeof(msg)) == 1);
      CHECK(strstr(msg, "does not exist") != NULL); }

    // more hops than a chain can hold
    { UINT32 hops[PB_CHAIN_MAX_HOPS + 2];
      for (int i = 0; i < (int)(sizeof(hops) / sizeof(hops[0])); i++) hops[i] = socks5;
      CHECK(chain_problems(hops, (UINT32)(sizeof(hops) / sizeof(hops[0])), msg, sizeof(msg)) == 1); }

    // the problems come back one per line
    { UINT32 hops[3] = { http, http, http };
      CHECK(chain_problems(hops, 3, msg, sizeof(msg)) >= 1); }

    // ── the chain list ───────────────────────────────────────────────────────
    { UINT32 hops[2] = { socks5, socks4 };
      UINT32 id = ProxyBridge_AddChain("work", hops, 2);
      CHECK(id >= PB_CHAIN_ID_BASE);            // the chain ids live in a range of their own
      CHECK(id != socks5 && id != socks4 && id != http);   // a chain is never a proxy

      PB_CHAIN chains[8];
      UINT32 n = ProxyBridge_GetChains(chains, 8);
      CHECK(n == 1);
      CHECK(chains[0].id == id);
      CHECK(chains[0].hopCount == 2);
      CHECK(chains[0].hops[0] == socks5 && chains[0].hops[1] == socks4);
      CHECK(strcmp(chains[0].name, "work") == 0);

      // the engine can find it again
      PROXY_CHAIN* c = find_chain(id);
      CHECK(c != NULL && c->hop_count == 2 && c->hop_ids[0] == socks5);

      // editing it in place keeps the id
      UINT32 hops2[1] = { http };
      CHECK(ProxyBridge_EditChain(id, "home", hops2, 1));
      n = ProxyBridge_GetChains(chains, 8);
      CHECK(n == 1 && chains[0].id == id && chains[0].hopCount == 1 && chains[0].hops[0] == http);
      CHECK(strcmp(chains[0].name, "home") == 0);

      // editing a chain that is not there fails
      CHECK(!ProxyBridge_EditChain(id + 500, "x", hops2, 1));

      // deleting it
      CHECK(ProxyBridge_DeleteChain(id));
      CHECK(ProxyBridge_GetChains(chains, 8) == 0);
      CHECK(find_chain(id) == NULL);
      CHECK(!ProxyBridge_DeleteChain(id));      // it is gone already
    }

    // a chain that cannot work is refused
    { UINT32 hops[2] = { http, socks5 };
      CHECK(ProxyBridge_AddChain("broken", hops, 2) == 0); }
    { UINT32 hops[2] = { socks5, socks5 };
      CHECK(ProxyBridge_AddChain("twice", hops, 2) == 0); }
    CHECK(ProxyBridge_AddChain("empty", NULL, 0) == 0);

    // ── the rules that walk through a chain ──────────────────────────────────
    { UINT32 hops[2] = { socks5, socks4 };
      UINT32 chain_id = ProxyBridge_AddChain("two hops", hops, 2);
      CHECK(chain_id >= PB_CHAIN_ID_BASE);

      // a rule that names a chain is accepted
      UINT32 rule = ProxyBridge_AddRule("chain.exe", "*", "*", "*",
                                        RULE_PROTOCOL_BOTH, RULE_ACTION_CHAIN, chain_id, FALSE);
      CHECK(rule != 0);

      // the rule matches with the chain's action, and the chain's id comes with it
      UINT32 got = 0;
      CHECK(MatchChain("chain.exe", &got) == RULE_ACTION_CHAIN);
      CHECK(got == chain_id);

      // a rule that names a chain but gives a proxy id is refused: the two can
      // never be mistaken for one another
      CHECK(ProxyBridge_AddRule("bad.exe", "*", "*", "*",
                                RULE_PROTOCOL_BOTH, RULE_ACTION_CHAIN, socks5, FALSE) == 0);
      CHECK(ProxyBridge_AddRule("bad.exe", "*", "*", "*",
                                RULE_PROTOCOL_BOTH, RULE_ACTION_CHAIN, 0, FALSE) == 0);

      // the same holds when the rule is edited
      CHECK(ProxyBridge_EditRule(rule, "chain.exe", "*", "*", "*",
                                 RULE_PROTOCOL_BOTH, RULE_ACTION_CHAIN, socks5, FALSE) == FALSE);
      CHECK(ProxyBridge_EditRule(rule, "chain.exe", "*", "*", "*",
                                 RULE_PROTOCOL_BOTH, RULE_ACTION_CHAIN, chain_id, FALSE) == TRUE);

      // a chain that goes away leaves the rules that used it on direct
      CHECK(ProxyBridge_DeleteChain(chain_id));
      CHECK(MatchChain("chain.exe", &got) == RULE_ACTION_DIRECT);
      CHECK(got == 0);

      ProxyBridge_DeleteRule(rule);
    }

    // a rule that names a chain is not touched by the deletion of another chain
    { UINT32 hops[1] = { socks5 };
      UINT32 keep  = ProxyBridge_AddChain("keep", hops, 1);
      UINT32 other = ProxyBridge_AddChain("other", hops, 1);
      CHECK(keep != 0 && other != 0 && keep != other);
      UINT32 rule = ProxyBridge_AddRule("keep.exe", "*", "*", "*",
                                        RULE_PROTOCOL_BOTH, RULE_ACTION_CHAIN, keep, FALSE);
      CHECK(rule != 0);
      CHECK(ProxyBridge_DeleteChain(other));
      UINT32 got = 0;
      CHECK(MatchChain("keep.exe", &got) == RULE_ACTION_CHAIN);
      CHECK(got == keep);
      ProxyBridge_DeleteRule(rule);
      ProxyBridge_DeleteChain(keep);
    }

    return pbtest_done("test_chain");
}
