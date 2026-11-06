// test_ppx.c - the Proxifier profile reader (gui\profile\ppx.c).
//
// The same fixture and the same cases are in MacOS/tests/logic/ppx_tests.swift, so the two
// platforms cannot drift apart: the same file has to mean the same thing on both.
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include "../gui/profile/ppx.h"
#include "../gui/profile/profile.h"
#include "pbtest.h"

static PBProfile g;                 // a profile is large: keep it off the stack
static wchar_t g_notes[4096];
#define NOTES_CCH ((int)(sizeof(g_notes) / sizeof(wchar_t)))

// The profile Proxifier writes. It has one proxy of every kind, a chain with a switched
// off hop, and one rule of every action.
//
// The curved quote is written as a byte escape on purpose: the file has to hold the same
// bytes whatever the compiler thinks the source charset is.
static const char* SAMPLE =
"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
"<ProxifierProfile version=\"101\" platform=\"MacOSX\" product_id=\"2\" product_minver=\"200\">\n"
"    <Options>\n"
"        <Resolve>\n"
"            <AutoModeDetection enabled=\"false\"/>\n"
"            <ViaProxy enabled=\"true\">\n"
"                <TryLocalDnsFirst enabled=\"false\"/>\n"
"            </ViaProxy>\n"
"            <ExclusionList ExcludeSimpleHostnames=\"false\" ExcludeLocalhost=\"true\" ExcludeSelfHostname=\"true\" ExcludeLocalDomain=\"true\">localhost;%ComputerName%;*.local;\n"
"</ExclusionList>\n"
"        </Resolve>\n"
"        <Encryption mode=\"disabled\"/>\n"
"        <HttpProxiesSupport enabled=\"true\"/>\n"
"    </Options>\n"
"    <ProxyList>\n"
"        <!-- the proxy servers of this profile -->\n"
"        <Proxy id=\"101\" type=\"SOCKS5\">\n"
"            <Address>127.0.0.1</Address>\n"
"            <Port>1080</Port>\n"
"            <Options>0</Options>\n"
"        </Proxy>\n"
"        <Proxy id=\"102\" type=\"HTTP\">\n"
"            <Address>10.0.0.2</Address>\n"
"            <Port>8080</Port>\n"
"            <Options>0</Options>\n"
"        </Proxy>\n"
"        <Proxy id=\"103\" type=\"SOCKS4\">\n"
"            <Address>10.0.0.3</Address>\n"
"            <Port>1080</Port>\n"
"            <Options>0</Options>\n"
"        </Proxy>\n"
"        <Proxy id=\"104\" type=\"SOCKS4A\">\n"
"            <Address>10.0.0.4</Address>\n"
"            <Port>1080</Port>\n"
"            <Options>0</Options>\n"
"        </Proxy>\n"
"        <Proxy id=\"105\" type=\"HTTPS\">\n"
"            <Address>10.0.0.5</Address>\n"
"            <Port>443</Port>\n"
"            <Options>0</Options>\n"
"        </Proxy>\n"
"        <Proxy id=\"106\" type=\"SOCKS5\">\n"
"            <Address>10.0.0.6</Address>\n"
"            <Port>1080</Port>\n"
"            <Options>0</Options>\n"
"            <Authentication enabled=\"true\">\n"
"                <Username>alice</Username>\n"
"                <Password>secret</Password>\n"
"            </Authentication>\n"
"        </Proxy>\n"
"        <Proxy id=\"107\" type=\"CARRIER-PIGEON\">\n"
"            <Address>10.0.0.7</Address>\n"
"            <Port>1080</Port>\n"
"            <Options>0</Options>\n"
"        </Proxy>\n"
"        <Proxy id=\"108\" type=\"SOCKS5\">\n"
"            <Label>work</Label>\n"
"            <Address>10.0.0.8</Address>\n"
"            <Port>1080</Port>\n"
"            <Options>0</Options>\n"
"        </Proxy>\n"
"        <Proxy id=\"109\" type=\"SOCKS5\">\n"
"            <Label>R&amp;D</Label>\n"
"            <Address>10.0.0.9</Address>\n"
"            <Port>1080</Port>\n"
"            <Options>0</Options>\n"
"        </Proxy>\n"
"    </ProxyList>\n"
"    <ChainList>\n"
"        <Chain id=\"126\">\n"
"            <Name>office</Name>\n"
"            <Proxy enabled=\"false\">103</Proxy>\n"
"            <Proxy enabled=\"true\">104</Proxy>\n"
"            <Proxy enabled=\"true\">101</Proxy>\n"
"        </Chain>\n"
"        <Chain id=\"127\">\n"
"            <Name>empty</Name>\n"
"            <Proxy enabled=\"false\">103</Proxy>\n"
"        </Chain>\n"
"    </ChainList>\n"
"    <RuleList>\n"
"        <Rule enabled=\"true\">\n"
"            <Name>direct rule</Name>\n"
"            <Targets>*.example.com; 10.0.0.0/8 </Targets>\n"
"            <Action type=\"Direct\"/>\n"
"        </Rule>\n"
"        <Rule enabled=\"false\">\n"
"            <Name>proxy rule</Name>\n"
"            <Applications>\"WeChat.app\"; com.tencent.xinWeChat; \xE2\x80\x9D"
"QQ.app\"; \"QQ\"; com.tencent.qq; </Applications>\n"
"            <Ports>80;443</Ports>\n"
"            <Action type=\"Proxy\">101</Action>\n"
"        </Rule>\n"
"        <Rule enabled=\"true\">\n"
"            <Name>chain rule</Name>\n"
"            <Action type=\"Chain\">126</Action>\n"
"        </Rule>\n"
"        <Rule enabled=\"true\">\n"
"            <Name>block rule</Name>\n"
"            <Action type=\"Block\"/>\n"
"        </Rule>\n"
"        <Rule enabled=\"true\">\n"
"            <Name>dangling</Name>\n"
"            <Action type=\"Proxy\">999</Action>\n"
"        </Rule>\n"
"        <Rule enabled=\"true\">\n"
"            <Name>empty chain rule</Name>\n"
"            <Action type=\"Chain\">127</Action>\n"
"        </Rule>\n"
"    </RuleList>\n"
"</ProxifierProfile>";

// ── the helpers ──────────────────────────────────────────────────────────

static int import_text(const char* text)
{
    ZeroMemory(&g_notes, sizeof(g_notes));
    return PB_ImportPPXData(text, strlen(text), &g, g_notes, NOTES_CCH);
}

static int has_note(const wchar_t* needle)
{
    return g_notes[0] && wcsstr(g_notes, needle) != NULL;
}

static const PBConfig* cfg_by_host(const char* host)
{
    wchar_t wide[256];
    if (!MultiByteToWideChar(CP_UTF8, 0, host, -1, wide, 256)) return NULL;
    for (int i = 0; i < g.cfgCount; i++)
        if (_wcsicmp(g.cfg[i].host, wide) == 0) return &g.cfg[i];
    return NULL;
}

static const PBConfig* cfg_by_id(UINT32 id)
{
    for (int i = 0; i < g.cfgCount; i++)
        if (g.cfg[i].storedId == id) return &g.cfg[i];
    return NULL;
}

static int dns_excluded(const wchar_t* name)
{
    for (int i = 0; i < g.dns.excludedCount; i++)
        if (_wcsicmp(g.dns.excluded[i], name) == 0) return 1;
    return 0;
}

// the sample with one piece replaced, for the variants
static char* replace_once(const char* from, const char* to)
{
    const char* at = strstr(SAMPLE, from);
    if (!at) return NULL;
    size_t headLen = (size_t)(at - SAMPLE);
    size_t tailLen = strlen(at + strlen(from));
    size_t toLen = strlen(to);
    char* out = (char*)malloc(headLen + toLen + tailLen + 1);
    if (!out) return NULL;
    memcpy(out, SAMPLE, headLen);
    memcpy(out + headLen, to, toLen);
    memcpy(out + headLen + toLen, at + strlen(from), tailLen + 1);
    return out;
}

int main(void)
{
    // ── the file is recognised ─────────────────────────────────────────────
    CHECK(!import_text("not xml"));
    CHECK(!import_text("{\"a\":1}"));
    CHECK(!import_text("<Other/>"));
    CHECK(!import_text(""));

    // ── the proxies ────────────────────────────────────────────────────────
    CHECK(import_text(SAMPLE));
    CHECK(g.cfgCount == 8);
    {
        const PBConfig* c = cfg_by_host("127.0.0.1");
        CHECK(c && _wcsicmp(c->type, L"SOCKS5") == 0);
    }
    {
        const PBConfig* c = cfg_by_host("10.0.0.2");
        CHECK(c && _wcsicmp(c->type, L"HTTP") == 0);
    }
    {
        const PBConfig* c = cfg_by_host("10.0.0.3");
        CHECK(c && _wcsicmp(c->type, L"SOCKS4") == 0);
    }
    {
        // socks4a is a socks4 proxy that sends the name
        const PBConfig* c = cfg_by_host("10.0.0.4");
        CHECK(c && _wcsicmp(c->type, L"SOCKS4") == 0 && c->sendDomain == 1);
    }
    {
        // a socks4 proxy does not send the name
        const PBConfig* c = cfg_by_host("10.0.0.3");
        CHECK(c && c->sendDomain == 0);
    }
    {
        // an https proxy is an http proxy
        const PBConfig* c = cfg_by_host("10.0.0.5");
        CHECK(c && _wcsicmp(c->type, L"HTTP") == 0);
    }
    CHECK(cfg_by_host("10.0.0.7") == NULL);                 // a proxy of an unknown type
    {
        const PBConfig* c = cfg_by_host("127.0.0.1");
        CHECK(c && _wcsicmp(c->port, L"1080") == 0);         // the port is imported
    }
    {
        const PBConfig* c = cfg_by_host("10.0.0.6");
        CHECK(c && _wcsicmp(c->user, L"alice") == 0 && _wcsicmp(c->pass, L"secret") == 0);
    }
    {
        const PBConfig* c = cfg_by_host("127.0.0.1");
        CHECK(c && c->user[0] == 0);                         // no credentials, no user
    }
    {
        const PBConfig* c = cfg_by_host("10.0.0.8");
        CHECK(c && _wcsicmp(c->name, L"work") == 0);         // the label becomes the name
    }
    {
        const PBConfig* c = cfg_by_host("10.0.0.9");
        CHECK(c && _wcsicmp(c->name, L"R&D") == 0);           // the entities in a label are decoded
    }
    CHECK(has_note(L"CARRIER-PIGEON"));                      // the unknown type is reported
    // a proxy that is added later gets an id of its own, never one that is in use
    CHECK(g.nextCfgId > 109);

    // ── the chains ─────────────────────────────────────────────────────────
    CHECK(g.chainCount == 1);
    CHECK(_wcsicmp(g.chain[0].name, L"office") == 0);        // the chain keeps its name
    CHECK(g.chain[0].hopCount == 2);                         // a hop that is off is not walked
    CHECK(g.chain[0].hops[0] == 104 && g.chain[0].hops[1] == 101);   // the order is kept
    CHECK(g.chain[0].storedId >= PB_CHAIN_ID_BASE);          // a chain never looks like a proxy
    CHECK(cfg_by_id(104) != NULL);                           // the hops point at real proxies

    // ── the rules ──────────────────────────────────────────────────────────
    CHECK(g.ruleCount == 6);
    CHECK(_wcsicmp(g.rule[0].name, L"direct rule") == 0 && _wcsicmp(g.rule[5].name, L"empty chain rule") == 0);
    CHECK(_wcsicmp(g.rule[0].action, L"DIRECT") == 0);       // a direct rule stays direct
    CHECK(_wcsicmp(g.rule[3].action, L"BLOCK") == 0);        // a block rule stays block
    CHECK(_wcsicmp(g.rule[1].action, L"PROXY") == 0 && g.rule[1].cfgStoredId == 101);
    CHECK(_wcsicmp(g.rule[2].action, L"CHAIN") == 0 && g.rule[2].cfgStoredId == g.chain[0].storedId);
    CHECK(_wcsicmp(g.rule[4].action, L"DIRECT") == 0 && g.rule[4].cfgStoredId == 0);
    CHECK(_wcsicmp(g.rule[5].action, L"DIRECT") == 0 && g.rule[5].cfgStoredId == 0);
    CHECK(has_note(L"999"));                                 // the dangling rule is reported
    CHECK(has_note(L"127"));                                 // the empty chain rule is reported
    CHECK(g.rule[1].enabled == 0);                           // a rule that is off stays off
    CHECK(g.rule[0].enabled == 1);                           // a rule that is on stays on
    {
        int allTcp = 1;
        for (int i = 0; i < g.ruleCount; i++)
            if (_wcsicmp(g.rule[i].proto, L"TCP") != 0) allTcp = 0;
        CHECK(allTcp);                                       // proxifier proxies tcp only
    }
    CHECK(_wcsicmp(g.rule[1].proc, L"WeChat;com.tencent.xinWeChat;QQ;com.tencent.qq") == 0);
    CHECK(_wcsicmp(g.rule[0].hosts, L"*.example.com;10.0.0.0/8") == 0);
    CHECK(_wcsicmp(g.rule[1].ports, L"80;443") == 0);
    CHECK(g.rule[2].hosts[0] == 0);                          // a rule without targets has none

    // ── the name resolution settings ───────────────────────────────────────
    CHECK(g.dns.mode == PB_DNS_MODE_REMOTE);
    CHECK(g.dns.leakProtection == 1);
    CHECK(dns_excluded(L"localhost"));
    CHECK(dns_excluded(L"*.local"));
    {
        wchar_t host[256]; DWORD n = 256;
        if (GetComputerNameW(host, &n)) CHECK(dns_excluded(host));
    }
    CHECK(!dns_excluded(L"%ComputerName%"));

    // the same file with the proxy resolving turned off
    {
        char* v = replace_once("<ViaProxy enabled=\"true\">", "<ViaProxy enabled=\"false\">");
        CHECK(v != NULL);
        if (v)
        {
            CHECK(import_text(v));
            CHECK(g.dns.mode == PB_DNS_MODE_LOCAL);
            CHECK(g.dns.leakProtection == 0);
            free(v);
        }
    }

    // and with the automatic detection on
    {
        char* v = replace_once("<AutoModeDetection enabled=\"false\"/>", "<AutoModeDetection enabled=\"true\"/>");
        CHECK(v != NULL);
        if (v)
        {
            CHECK(import_text(v));
            CHECK(g.dns.mode == PB_DNS_MODE_SYSTEM);
            CHECK(has_note(L"automatically"));
            free(v);
        }
    }

    // ── a profile with nothing in it is still a profile ─────────────────────
    CHECK(import_text("<ProxifierProfile/>"));
    CHECK(g.cfgCount == 0 && g.ruleCount == 0 && g.chainCount == 0);

    return pbtest_done("test_ppx");
}
