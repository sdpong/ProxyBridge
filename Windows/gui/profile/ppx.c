// ppx.c - read a Proxifier profile (.ppx).
//
// A .ppx is an XML document. Proxifier for macOS and Proxifier for Windows write the
// same format, so one reader serves both.
//
// The reader here is not a general XML parser: it reads elements, attributes and text,
// and it refuses what could reach outside the file (a doctype that declares entities,
// an external reference). The macOS side has the same mapping in
// MacOS/ProxyBridge/ProxyBridge/PPXImporter.swift; the two have to agree, so the test
// files hold the same cases.
#include "ppx.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <ctype.h>

// ── a small XML tree ──────────────────────────────────────────────────────

#define PBX_MAX_DEPTH  24
#define PBX_MAX_ATTRS  8
#define PBX_MAX_NODES  20000

typedef struct PBXNode PBXNode;
struct PBXNode {
    char*  element;
    char*  text;                                  // the text of the element, unescaped
    char*  attr_name[PBX_MAX_ATTRS];
    char*  attr_value[PBX_MAX_ATTRS];
    int    attr_count;
    PBXNode** child;
    int    child_count;
    int    child_cap;
};

typedef struct {
    PBXNode** node;
    int count;
    int cap;
    int failed;
} PBXDoc;

static void pbx_doc_free(PBXDoc* d)
{
    for (int i = 0; i < d->count; i++)
    {
        PBXNode* n = d->node[i];
        if (!n) continue;
        free(n->element);
        free(n->text);
        for (int a = 0; a < n->attr_count; a++) { free(n->attr_name[a]); free(n->attr_value[a]); }
        free(n->child);
        free(n);
    }
    free(d->node);
    d->node = NULL; d->count = 0; d->cap = 0;
}

static PBXNode* pbx_doc_new(PBXDoc* d)
{
    if (d->count >= PBX_MAX_NODES) { d->failed = TRUE; return NULL; }
    if (d->count == d->cap)
    {
        int cap = d->cap ? d->cap * 2 : 64;
        PBXNode** grown = (PBXNode**)realloc(d->node, (size_t)cap * sizeof(PBXNode*));
        if (!grown) { d->failed = TRUE; return NULL; }
        d->node = grown; d->cap = cap;
    }
    PBXNode* n = (PBXNode*)calloc(1, sizeof(PBXNode));
    if (!n) { d->failed = TRUE; return NULL; }
    d->node[d->count++] = n;
    return n;
}

static BOOL pbx_add_child(PBXNode* parent, PBXNode* child)
{
    if (parent->child_count == parent->child_cap)
    {
        int cap = parent->child_cap ? parent->child_cap * 2 : 8;
        PBXNode** grown = (PBXNode**)realloc(parent->child, (size_t)cap * sizeof(PBXNode*));
        if (!grown) return FALSE;
        parent->child = grown; parent->child_cap = cap;
    }
    parent->child[parent->child_count++] = child;
    return TRUE;
}

// ── the reader ────────────────────────────────────────────────────────────

typedef struct {
    const char* p;
    const char* end;
    int depth;
    PBXDoc* doc;
} PBXReader;

static BOOL pbx_is_space(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

static void pbx_skip_space(PBXReader* r)
{
    while (r->p < r->end && pbx_is_space(*r->p)) r->p++;
}

// The name of an element or an attribute: letters, digits and a few marks.
static BOOL pbx_is_name_char(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
           c == '_' || c == '-' || c == '.' || c == ':';
}

static char* pbx_read_name(PBXReader* r)
{
    const char* start = r->p;
    while (r->p < r->end && pbx_is_name_char(*r->p)) r->p++;
    if (r->p == start) return NULL;
    size_t n = (size_t)(r->p - start);
    char* out = (char*)malloc(n + 1);
    if (!out) return NULL;
    memcpy(out, start, n);
    out[n] = '\0';
    return out;
}

// ── text buffers ──────────────────────────────────────────────────────────

typedef struct { char* buf; size_t len; size_t cap; } PBXBuf;

static void pbx_buf_free(PBXBuf* b) { free(b->buf); b->buf = NULL; b->len = b->cap = 0; }

static BOOL pbx_buf_reserve(PBXBuf* b, size_t extra)
{
    if (b->len + extra + 1 <= b->cap) return TRUE;
    size_t cap = b->cap ? b->cap : 64;
    while (cap < b->len + extra + 1) cap *= 2;
    char* grown = (char*)realloc(b->buf, cap);
    if (!grown) return FALSE;
    b->buf = grown; b->cap = cap;
    return TRUE;
}

static BOOL pbx_buf_add(PBXBuf* b, const char* s, size_t n)
{
    if (!pbx_buf_reserve(b, n)) return FALSE;
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = '\0';
    return TRUE;
}

// The five entities XML knows, and a number written as &#123; or &#x7b;. Anything
// else is left as it is: a profile is not a place where a stray & has to be an error.
static BOOL pbx_buf_add_decoded(PBXBuf* b, const char* s, size_t n)
{
    for (size_t i = 0; i < n; i++)
    {
        if (s[i] != '&') { if (!pbx_buf_add(b, s + i, 1)) return FALSE; continue; }
        size_t end = i + 1;
        while (end < n && s[end] != ';' && end - i < 12) end++;
        if (end >= n || s[end] != ';') { if (!pbx_buf_add(b, s + i, 1)) return FALSE; continue; }
        size_t len = end - i - 1;
        const char* e = s + i + 1;
        if (len == 3 && memcmp(e, "amp", 3) == 0)       { if (!pbx_buf_add(b, "&", 1)) return FALSE; }
        else if (len == 2 && memcmp(e, "lt", 2) == 0)   { if (!pbx_buf_add(b, "<", 1)) return FALSE; }
        else if (len == 2 && memcmp(e, "gt", 2) == 0)   { if (!pbx_buf_add(b, ">", 1)) return FALSE; }
        else if (len == 4 && memcmp(e, "quot", 4) == 0) { if (!pbx_buf_add(b, "\"", 1)) return FALSE; }
        else if (len == 4 && memcmp(e, "apos", 4) == 0) { if (!pbx_buf_add(b, "'", 1)) return FALSE; }
        else if (len >= 2 && e[0] == '#')
        {
            unsigned long code = 0;
            if (e[1] == 'x' || e[1] == 'X') code = strtoul(e + 2, NULL, 16);
            else code = strtoul(e + 1, NULL, 10);
            char one[4];
            int n2 = 1;
            if (code < 0x80) one[0] = (char)code;
            else if (code < 0x800) { one[0] = (char)(0xC0 | (code >> 6)); one[1] = (char)(0x80 | (code & 0x3F)); n2 = 2; }
            else { one[0] = (char)(0xE0 | (code >> 12)); one[1] = (char)(0x80 | ((code >> 6) & 0x3F)); one[2] = (char)(0x80 | (code & 0x3F)); n2 = 3; }
            if (!pbx_buf_add(b, one, (size_t)n2)) return FALSE;
        }
        else if (!pbx_buf_add(b, s + i, len + 2)) return FALSE;
        i = end;
    }
    return TRUE;
}

// ── the parser ────────────────────────────────────────────────────────────

static PBXNode* pbx_parse_element(PBXReader* r);

// Skips what is not content: the xml declaration, comments and the doctype.
// A doctype is skipped as a whole: a profile never needs one, and reading one could
// pull an entity definition in.
static void pbx_skip_misc(PBXReader* r)
{
    for (;;)
    {
        pbx_skip_space(r);
        if (r->end - r->p < 2 || r->p[0] != '<') return;
        if (r->p[1] == '?')
        {
            const char* q = r->p + 2;
            while (q + 1 < r->end && !(q[0] == '?' && q[1] == '>')) q++;
            r->p = (q + 1 < r->end) ? q + 2 : r->end;
            continue;
        }
        if (r->p[1] == '!')
        {
            if (r->end - r->p >= 4 && memcmp(r->p, "<!--", 4) == 0)
            {
                const char* q = r->p + 4;
                while (q + 2 < r->end && memcmp(q, "-->", 3) != 0) q++;
                r->p = (q + 2 < r->end) ? q + 3 : r->end;
                continue;
            }
            // a doctype, with or without an internal subset
            const char* q = r->p + 2;
            int brackets = 0;
            while (q < r->end)
            {
                if (*q == '[') brackets++;
                else if (*q == ']') brackets--;
                else if (*q == '>' && brackets <= 0) { q++; break; }
                q++;
            }
            r->p = q;
            continue;
        }
        return;
    }
}

static BOOL pbx_read_attr_value(PBXReader* r, char** out)
{
    if (r->p >= r->end) return FALSE;
    char quote = *r->p;
    if (quote != '"' && quote != '\'') return FALSE;
    r->p++;
    const char* start = r->p;
    while (r->p < r->end && *r->p != quote) r->p++;
    if (r->p >= r->end) return FALSE;
    PBXBuf b; ZeroMemory(&b, sizeof(b));
    if (!pbx_buf_add_decoded(&b, start, (size_t)(r->p - start))) { pbx_buf_free(&b); return FALSE; }
    r->p++;     // the closing quote
    if (!b.buf) { b.buf = (char*)calloc(1, 1); if (!b.buf) return FALSE; }
    *out = b.buf;
    return TRUE;
}

static PBXNode* pbx_parse_element(PBXReader* r)
{
    if (r->depth >= PBX_MAX_DEPTH) { r->doc->failed = TRUE; return NULL; }
    if (r->p >= r->end || *r->p != '<') { r->doc->failed = TRUE; return NULL; }
    r->p++;
    char* name = pbx_read_name(r);
    if (!name) { r->doc->failed = TRUE; return NULL; }

    PBXNode* node = pbx_doc_new(r->doc);
    if (!node) { free(name); return NULL; }
    node->element = name;

    // the attributes
    for (;;)
    {
        pbx_skip_space(r);
        if (r->p >= r->end) { r->doc->failed = TRUE; return node; }
        if (*r->p == '>' || *r->p == '/') break;
        char* aname = pbx_read_name(r);
        if (!aname) { r->doc->failed = TRUE; return node; }
        pbx_skip_space(r);
        char* avalue = NULL;
        if (r->p < r->end && *r->p == '=')
        {
            r->p++;
            pbx_skip_space(r);
            if (!pbx_read_attr_value(r, &avalue)) { free(aname); r->doc->failed = TRUE; return node; }
        }
        else avalue = (char*)calloc(1, 1);
        if (!avalue) { free(aname); r->doc->failed = TRUE; return node; }
        if (node->attr_count < PBX_MAX_ATTRS)
        {
            node->attr_name[node->attr_count] = aname;
            node->attr_value[node->attr_count] = avalue;
            node->attr_count++;
        }
        else { free(aname); free(avalue); }
    }

    if (r->p < r->end && *r->p == '/')
    {
        r->p++;      // the slash of an empty element
        if (r->p < r->end && *r->p == '>') r->p++;
        return node;
    }
    if (r->p >= r->end || *r->p != '>') { r->doc->failed = TRUE; return node; }
    r->p++;

    // the content
    PBXBuf text; ZeroMemory(&text, sizeof(text));
    for (;;)
    {
        if (r->p >= r->end) { pbx_buf_free(&text); r->doc->failed = TRUE; return node; }
        if (*r->p == '<')
        {
            if (r->end - r->p >= 2 && r->p[1] == '/')
            {
                // the end of this element
                const char* q = r->p + 2;
                while (q < r->end && *q != '>') q++;
                if (q < r->end) r->p = q + 1;
                else r->p = r->end;
                break;
            }
            if (r->end - r->p >= 4 && memcmp(r->p, "<!--", 4) == 0)
            {
                const char* q = r->p + 4;
                while (q + 2 < r->end && memcmp(q, "-->", 3) != 0) q++;
                r->p = (q + 2 < r->end) ? q + 3 : r->end;
                continue;
            }
            if (r->end - r->p >= 9 && memcmp(r->p, "<![CDATA[", 9) == 0)
            {
                const char* q = r->p + 9;
                while (q + 2 < r->end && memcmp(q, "]]>", 3) != 0) q++;
                if (!pbx_buf_add(&text, r->p + 9, (size_t)(q - (r->p + 9)))) { pbx_buf_free(&text); r->doc->failed = TRUE; return node; }
                r->p = (q + 2 < r->end) ? q + 3 : r->end;
                continue;
            }
            if (r->end - r->p >= 2 && r->p[1] == '?')
            {
                const char* q = r->p + 2;
                while (q + 1 < r->end && !(q[0] == '?' && q[1] == '>')) q++;
                r->p = (q + 1 < r->end) ? q + 2 : r->end;
                continue;
            }
            r->depth++;
            PBXNode* kid = pbx_parse_element(r);
            r->depth--;
            if (!kid) { pbx_buf_free(&text); r->doc->failed = TRUE; return node; }
            if (!pbx_add_child(node, kid)) { pbx_buf_free(&text); r->doc->failed = TRUE; return node; }
            continue;
        }
        const char* start = r->p;
        while (r->p < r->end && *r->p != '<') r->p++;
        if (!pbx_buf_add_decoded(&text, start, (size_t)(r->p - start))) { pbx_buf_free(&text); r->doc->failed = TRUE; return node; }
    }

    // the text is trimmed: the whitespace around an element is not part of it
    if (text.buf)
    {
        char* s = text.buf;
        while (*s && pbx_is_space(*s)) s++;
        size_t n = strlen(s);
        while (n > 0 && pbx_is_space(s[n - 1])) n--;
        char* trimmed = (char*)malloc(n + 1);
        if (trimmed)
        {
            memcpy(trimmed, s, n);
            trimmed[n] = '\0';
            free(text.buf);
            node->text = trimmed;
        }
        else node->text = text.buf;
    }
    return node;
}

// ── finding things in the tree ────────────────────────────────────────────

static const char* pbx_attr(const PBXNode* n, const char* name)
{
    if (!n) return NULL;
    for (int i = 0; i < n->attr_count; i++)
        if (_stricmp(n->attr_name[i], name) == 0) return n->attr_value[i];
    return NULL;
}

static int pbx_attr_bool(const PBXNode* n, const char* name, int fallback)
{
    const char* v = pbx_attr(n, name);
    if (!v) return fallback;
    if (_stricmp(v, "true") == 0 || _stricmp(v, "1") == 0 || _stricmp(v, "yes") == 0) return TRUE;
    if (_stricmp(v, "false") == 0 || _stricmp(v, "0") == 0 || _stricmp(v, "no") == 0) return FALSE;
    return fallback;
}

static const PBXNode* pbx_child(const PBXNode* n, const char* name)
{
    if (!n) return NULL;
    for (int i = 0; i < n->child_count; i++)
        if (_stricmp(n->child[i]->element, name) == 0) return n->child[i];
    return NULL;
}

static int pbx_children(const PBXNode* n, const char* name, const PBXNode** out, int max)
{
    int count = 0;
    if (!n) return 0;
    for (int i = 0; i < n->child_count && count < max; i++)
        if (_stricmp(n->child[i]->element, name) == 0) out[count++] = n->child[i];
    return count;
}

// how many children carry this name, even when there are more than the room for
static int pbx_count_children(const PBXNode* n, const char* name)
{
    int count = 0;
    if (!n) return 0;
    for (int i = 0; i < n->child_count; i++)
        if (_stricmp(n->child[i]->element, name) == 0) count++;
    return count;
}

static const char* pbx_text(const PBXNode* n, const char* name)
{
    const PBXNode* c = pbx_child(n, name);
    return c ? (c->text ? c->text : "") : "";
}

// ── from the XML to the profile ───────────────────────────────────────────

typedef struct {
    wchar_t* buf;
    size_t len;
    size_t cap;
    int cch;
} PBXNotes;

static void pbx_note(PBXNotes* n, const char* fmt, ...)
{
    if (!n || !n->buf || n->cch <= 0) return;
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    int written = _vsnprintf_s(line, sizeof(line), _TRUNCATE, fmt, ap);
    va_end(ap);
    if (written < 0) return;
    wchar_t wide[512];
    int w = MultiByteToWideChar(CP_UTF8, 0, line, (int)strlen(line), wide, 511);
    if (w <= 0) { wide[0] = 0; w = 0; }
    wide[w] = 0;
    // every note is one line
    size_t need = n->len + (size_t)w + 3;
    if (need > (size_t)n->cch) return;
    memcpy(n->buf + n->len, wide, (size_t)w * sizeof(wchar_t));
    n->len += (size_t)w;
    n->buf[n->len] = L'\r';
    n->buf[n->len + 1] = L'\n';
    n->buf[n->len + 2] = 0;
    n->len += 2;
}

// turns a piece of utf-8 into wide text, so the profile keeps the names as they are.
// a text that does not fit is cut, not lost.
static void pbx_to_wide(const char* utf8, wchar_t* out, int cch)
{
    if (cch <= 0) return;
    if (!utf8) { out[0] = 0; return; }
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, cch - 1);
    if (n <= 0)
    {
        // the text is longer than the room: cut it at a character boundary
        int max = cch - 1;
        int w = MultiByteToWideChar(CP_UTF8, 0, utf8, max, out, cch - 1);
        if (w > 0) out[w] = 0;
        else out[0] = 0;
        return;
    }
    out[cch - 1] = 0;
}

static BOOL pbx_is_wspace(wchar_t c)
{
    return c == L' ' || c == L'\t' || c == L'\r' || c == L'\n';
}

// The name of this machine, which is what Proxifier's %ComputerName% stands for.
// GetComputerNameW takes the size of the buffer in characters and needs it up front:
// a size of zero asks for the length and fails.
static BOOL pbx_computer_name(wchar_t* out, int cch)
{
    if (cch <= 0) return FALSE;
    DWORD n = (DWORD)cch;
    if (!GetComputerNameW(out, &n) || n == 0) { out[0] = 0; return FALSE; }
    out[cch - 1] = 0;
    return TRUE;
}

// a list separated by semicolons: the pieces are trimmed and the empty ones go away
static void pbx_normalize_list(const char* raw, wchar_t* out, int cch)
{
    if (cch <= 0) return;
    out[0] = 0;
    if (!raw) return;
    wchar_t wide[32768];
    pbx_to_wide(raw, wide, 32768);
    wchar_t* piece = wide;
    size_t used = 0;
    while (*piece)
    {
        wchar_t* end = piece;
        while (*end && *end != L';') end++;
        wchar_t save = *end;
        *end = 0;
        while (*piece && pbx_is_wspace(*piece)) piece++;
        size_t l = wcslen(piece);
        while (l > 0 && pbx_is_wspace(piece[l - 1])) piece[--l] = 0;
        if (l > 0)
        {
            if (used > 0 && used + 1 < (size_t)cch) { out[used++] = L';'; }
            if (used + l < (size_t)cch)
            {
                memcpy(out + used, piece, l * sizeof(wchar_t));
                used += l;
            }
        }
        if (!save) break;
        piece = end + 1;
    }
    out[used < (size_t)cch ? used : (size_t)cch - 1] = 0;
}

// Proxifier writes the name of an app in quotes when the name has a space in it.
// The matcher compares the pattern with the bundle id and with the name of the
// executable, so the quotes and the .app suffix are taken off. A quote that was typed
// by hand can be a curly one, so both kinds go.
static BOOL pbx_is_quote(wchar_t c)
{
    return c == L'"' || c == 0x201C || c == 0x201D || c == L'\'' || c == 0x2018 || c == 0x2019;
}

static void pbx_normalize_apps(const char* raw, wchar_t* out, int cch)
{
    if (cch <= 0) return;
    out[0] = 0;
    if (!raw) return;
    wchar_t wide[32768];
    pbx_to_wide(raw, wide, 32768);
    wchar_t* piece = wide;
    size_t used = 0;
    while (*piece)
    {
        wchar_t* end = piece;
        while (*end && *end != L';') end++;
        wchar_t save = *end;
        *end = 0;
        wchar_t* s = piece;
        // the spaces around the name
        while (*s && pbx_is_wspace(*s)) s++;
        size_t l = wcslen(s);
        while (l > 0 && pbx_is_wspace(s[l - 1])) s[--l] = 0;
        // the quotes, as many as there are
        for (;;)
        {
            l = wcslen(s);
            if (l < 2 || !pbx_is_quote(s[0]) || !pbx_is_quote(s[l - 1])) break;
            s[l - 1] = 0;
            s++;
            while (*s && pbx_is_wspace(*s)) s++;
            l = wcslen(s);
            while (l > 0 && pbx_is_wspace(s[l - 1])) s[--l] = 0;
        }
        // the .app suffix
        l = wcslen(s);
        if (l >= 4 && _wcsicmp(s + l - 4, L".app") == 0) { s[l - 4] = 0; l -= 4; }
        if (l > 0)
        {
            // a profile often lists the same app twice ("QQ.app" and "QQ")
            BOOL seen = FALSE;
            for (int i = 0; i < (int)used; i++)
            {
                size_t seg = 0;
                while (i + (int)seg < (int)used && out[i + seg] != L';') seg++;
                if (seg == l && wcsncmp(out + i, s, l) == 0) { seen = TRUE; break; }
                i += (int)seg;
            }
            if (!seen)
            {
                if (used > 0 && used + 1 < (size_t)cch) out[used++] = L';';
                if (used + l < (size_t)cch) { memcpy(out + used, s, l * sizeof(wchar_t)); used += l; }
            }
        }
        if (!save) break;
        piece = end + 1;
    }
    out[used < (size_t)cch ? used : (size_t)cch - 1] = 0;
}

// ── the import ────────────────────────────────────────────────────────────

typedef struct {
    UINT32 id;
    wchar_t type[16];       // L"SOCKS5" | L"SOCKS4" | L"HTTP"
    int    sendDomain;
} PBXProxyInfo;

BOOL PB_ImportPPXData(const char* data, size_t len, PBProfile* p, wchar_t* notes, int cchNotes)
{
    if (!data || !p || len == 0) return FALSE;

    PBXNotes nt;
    ZeroMemory(&nt, sizeof(nt));
    nt.buf = notes;
    nt.cch = cchNotes;
    if (notes && cchNotes > 0) notes[0] = 0;

    PBXDoc doc;
    ZeroMemory(&doc, sizeof(doc));
    PBXReader r;
    ZeroMemory(&r, sizeof(r));
    r.p = data; r.end = data + len; r.doc = &doc;
    pbx_skip_misc(&r);
    PBXNode* root = pbx_parse_element(&r);
    if (!root || doc.failed || _stricmp(root->element, "ProxifierProfile") != 0)
    {
        pbx_doc_free(&doc);
        return FALSE;
    }

    PB_ProfileDefaults(p, L"Proxifier");

    // ── the proxies ─────────────────────────────────────────────────────────
    const PBXNode* proxyList = pbx_child(root, "ProxyList");
    int httpAllowed = pbx_attr_bool(pbx_child(pbx_child(root, "Options"), "HttpProxiesSupport"), "enabled", TRUE);
    int httpProxies = 0;

    // the ids of the proxies that were read, so a rule can find its proxy again
    UINT32 ids[PB_MAX_CFG * 4];
    int idCount = 0;

    const PBXNode* proxies[PB_MAX_CFG * 4];
    int proxyCount = pbx_children(proxyList, "Proxy", proxies, PB_MAX_CFG * 4);
    int noRoom = 0;         // the profile has more proxies than the profile can hold
    int httpSkipped = 0;    // the profile says the HTTP proxies are not used
    for (int i = 0; i < proxyCount; i++)
    {
        if (p->cfgCount >= PB_MAX_CFG) { noRoom++; continue; }
        const PBXNode* node = proxies[i];
        const char* idText = pbx_attr(node, "id");
        if (!idText) continue;
        char type[32];
        strncpy_s(type, sizeof(type), pbx_attr(node, "type") ? pbx_attr(node, "type") : "", _TRUNCATE);
        for (char* q = type; *q; q++) *q = (char)toupper((unsigned char)*q);

        PBXProxyInfo info;
        ZeroMemory(&info, sizeof(info));
        info.id = (UINT32)strtoul(idText, NULL, 10);
        if (strcmp(type, "SOCKS5") == 0) { wcscpy_s(info.type, 16, L"SOCKS5"); info.sendDomain = TRUE; }
        else if (strcmp(type, "SOCKS4") == 0) { wcscpy_s(info.type, 16, L"SOCKS4"); info.sendDomain = FALSE; }
        else if (strcmp(type, "SOCKS4A") == 0) { wcscpy_s(info.type, 16, L"SOCKS4"); info.sendDomain = TRUE; }
        else if (strcmp(type, "HTTPS") == 0) { wcscpy_s(info.type, 16, L"HTTP"); info.sendDomain = TRUE; }
        else if (strcmp(type, "HTTP") == 0)
        {
            wcscpy_s(info.type, 16, L"HTTP");
            info.sendDomain = TRUE;
            if (!httpAllowed) { httpSkipped++; continue; }
            httpProxies++;
        }
        else
        {
            pbx_note(&nt, "Proxy %s has the type '%s', which ProxyBridge does not know. It was left out.", idText, type);
            continue;
        }

        const char* address = pbx_text(node, "Address");
        const char* portText = pbx_text(node, "Port");
        long port = strtol(portText, NULL, 10);
        if (!address || !address[0] || port <= 0 || port > 65535)
        {
            pbx_note(&nt, "Proxy %s has no address or no port. It was left out.", idText);
            continue;
        }

        PBConfig* c = &p->cfg[p->cfgCount];
        ZeroMemory(c, sizeof(*c));
        c->storedId = info.id;
        pbx_to_wide(address, c->host, (int)(sizeof(c->host) / sizeof(wchar_t)));
        _snwprintf_s(c->port, 16, _TRUNCATE, L"%ld", port);
        wcsncpy_s(c->type, 16, info.type, _TRUNCATE);
        const char* label = pbx_text(node, "Label");
        if (label && label[0]) pbx_to_wide(label, c->name, (int)(sizeof(c->name) / sizeof(wchar_t)));
        c->sendDomain = info.sendDomain;
        const PBXNode* auth = pbx_child(node, "Authentication");
        if (pbx_attr_bool(auth, "enabled", FALSE))
        {
            const char* user = pbx_text(auth, "Username");
            const char* pass = pbx_text(auth, "Password");
            if (user && user[0]) pbx_to_wide(user, c->user, (int)(sizeof(c->user) / sizeof(wchar_t)));
            if (pass && pass[0]) pbx_to_wide(pass, c->pass, (int)(sizeof(c->pass) / sizeof(wchar_t)));
        }
        p->cfgCount++;
        ids[idCount] = info.id;
        idCount++;
        // a proxy that is added later gets an id of its own, never one that is in use
        if (info.id >= p->nextCfgId) p->nextCfgId = info.id + 1;
    }
    if (httpSkipped > 0)
        pbx_note(&nt, "The profile says HTTP proxy servers are not used, so %d HTTP proxy/proxies were left out.", httpSkipped);
    if (noRoom > 0)
        pbx_note(&nt, "The profile has %d proxies, ProxyBridge holds %d. %d of them were left out.", proxyCount, p->cfgCount, noRoom);
    if (httpProxies > 0)
        pbx_note(&nt, "Proxifier's plain HTTP proxy mode has no CONNECT tunnel. The %d HTTP proxy/proxies were imported, but ProxyBridge always asks them for a CONNECT tunnel.", httpProxies);

    // ── the chains ──────────────────────────────────────────────────────────
    // Proxifier keeps every proxy of a chain in the list and lets the user switch
    // the ones that are off; only the ones that are on are walked.
    const PBXNode* chains[PB_MAX_CHAIN];
    const PBXNode* chainList = pbx_child(root, "ChainList");
    int chainTotal = pbx_count_children(chainList, "Chain");
    int chainCount = pbx_children(chainList, "Chain", chains, PB_MAX_CHAIN);
    // the id the file gives the chain, so a rule that names it can be found again
    UINT32 chainFileId[PB_MAX_CHAIN];
    for (int i = 0; i < chainCount && p->chainCount < PB_MAX_CHAIN; i++)
    {
        const PBXNode* node = chains[i];
        const char* idText = pbx_attr(node, "id");
        if (!idText) continue;
        UINT32 fileId = (UINT32)strtoul(idText, NULL, 10);
        const char* name = pbx_text(node, "Name");

        // the hops first: a chain without a proxy that is on is of no use
        UINT32 hops[PB_MAX_CHAIN_HOPS];
        int hopCount = 0;
        for (int k = 0; k < node->child_count && hopCount < PB_MAX_CHAIN_HOPS; k++)
        {
            const PBXNode* hop = node->child[k];
            if (_stricmp(hop->element, "Proxy") != 0) continue;
            if (!pbx_attr_bool(hop, "enabled", TRUE)) continue;
            UINT32 proxyId = (UINT32)strtoul(hop->text ? hop->text : "0", NULL, 10);
            BOOL found = FALSE;
            for (int j = 0; j < idCount; j++) if (ids[j] == proxyId) { found = TRUE; break; }
            if (!found) continue;
            hops[hopCount++] = proxyId;
        }
        if (hopCount == 0)
        {
            pbx_note(&nt, "The chain '%s' has no proxy that is switched on. It was left out, and the rules that named it go direct.", name && name[0] ? name : idText);
            continue;
        }

        // the slot is taken first, so the id the allocator hands out sees the chains
        // that are already there
        p->chainCount++;
        PBChainProfile* ch = &p->chain[p->chainCount - 1];
        ZeroMemory(ch, sizeof(*ch));
        ch->storedId = PB_AllocChainId(p);
        if (name && name[0]) pbx_to_wide(name, ch->name, (int)(sizeof(ch->name) / sizeof(wchar_t)));
        for (int h = 0; h < hopCount; h++) ch->hops[h] = hops[h];
        ch->hopCount = hopCount;
        chainFileId[p->chainCount - 1] = fileId;
    }
    if (chainTotal > chainCount)
        pbx_note(&nt, "The profile has %d chains, ProxyBridge holds %d. %d of them were left out.", chainTotal, chainCount, chainTotal - chainCount);

    // ── the rules ───────────────────────────────────────────────────────────
    // Proxifier takes the first rule that matches, and so does ProxyBridge, so the
    // order of the file is kept.
    const PBXNode* rules[PB_MAX_RULE];
    const PBXNode* ruleList = pbx_child(root, "RuleList");
    int ruleTotal = pbx_count_children(ruleList, "Rule");
    int ruleCount = pbx_children(ruleList, "Rule", rules, PB_MAX_RULE);
    for (int i = 0; i < ruleCount && p->ruleCount < PB_MAX_RULE; i++)
    {
        const PBXNode* node = rules[i];
        const PBXNode* action = pbx_child(node, "Action");
        if (!action) continue;
        char actionType[32];
        strncpy_s(actionType, sizeof(actionType), pbx_attr(action, "type") ? pbx_attr(action, "type") : "", _TRUNCATE);
        for (char* q = actionType; *q; q++) *q = (char)tolower((unsigned char)*q);
        const char* actionId = action->text ? action->text : "";

        PBRule* r = &p->rule[p->ruleCount];
        ZeroMemory(r, sizeof(*r));
        const char* name = pbx_text(node, "Name");
        if (name && name[0]) pbx_to_wide(name, r->name, (int)(sizeof(r->name) / sizeof(wchar_t)));
        pbx_normalize_apps(pbx_text(node, "Applications"), r->proc, (int)(sizeof(r->proc) / sizeof(wchar_t)));
        pbx_normalize_list(pbx_text(node, "Targets"), r->hosts, (int)(sizeof(r->hosts) / sizeof(wchar_t)));
        pbx_normalize_list(pbx_text(node, "Ports"), r->ports, (int)(sizeof(r->ports) / sizeof(wchar_t)));
        // Proxifier proxies TCP only
        wcsncpy_s(r->proto, 8, L"TCP", _TRUNCATE);
        r->enabled = pbx_attr_bool(node, "enabled", TRUE);

        if (strcmp(actionType, "direct") == 0) { wcsncpy_s(r->action, 16, L"DIRECT", _TRUNCATE); r->cfgStoredId = 0; }
        else if (strcmp(actionType, "block") == 0) { wcsncpy_s(r->action, 16, L"BLOCK", _TRUNCATE); r->cfgStoredId = 0; }
        else if (strcmp(actionType, "proxy") == 0)
        {
            UINT32 id = (UINT32)strtoul(actionId, NULL, 10);
            BOOL found = FALSE;
            for (int j = 0; j < idCount; j++) if (ids[j] == id) { found = TRUE; break; }
            if (found) { wcsncpy_s(r->action, 16, L"PROXY", _TRUNCATE); r->cfgStoredId = id; }
            else { wcsncpy_s(r->action, 16, L"DIRECT", _TRUNCATE); r->cfgStoredId = 0; pbx_note(&nt, "A rule points at proxy %s, which is not in the profile. It goes direct.", actionId); }
        }
        else if (strcmp(actionType, "chain") == 0)
        {
            UINT32 id = (UINT32)strtoul(actionId, NULL, 10);
            // the chain of the file has its own id; the profile gives it a fresh one
            // in the range where a chain can never look like a proxy
            UINT32 stored = 0;
            for (int j = 0; j < p->chainCount; j++)
                if (chainFileId[j] == id) { stored = p->chain[j].storedId; break; }
            if (stored)
            {
                r->cfgStoredId = stored;
                wcsncpy_s(r->action, 16, L"CHAIN", _TRUNCATE);
            }
            else { wcsncpy_s(r->action, 16, L"DIRECT", _TRUNCATE); r->cfgStoredId = 0; pbx_note(&nt, "A rule points at chain %s, which is not in the profile. It goes direct.", actionId); }
        }
        else
        {
            wcsncpy_s(r->action, 16, L"DIRECT", _TRUNCATE);
            r->cfgStoredId = 0;
            pbx_note(&nt, "A rule has the action '%s', which ProxyBridge does not know. It goes direct.", actionType);
        }
        p->ruleCount++;
    }
    if (ruleTotal > ruleCount)
        pbx_note(&nt, "The profile has %d rules, ProxyBridge holds %d. %d of them were left out.", ruleTotal, ruleCount, ruleTotal - ruleCount);

    // ── the name resolution settings become the DNS policy ─────────────────
    const PBXNode* resolve = pbx_child(pbx_child(root, "Options"), "Resolve");
    int viaProxy = pbx_attr_bool(pbx_child(resolve, "ViaProxy"), "enabled", FALSE);
    int tryLocalFirst = pbx_attr_bool(pbx_child(pbx_child(resolve, "ViaProxy"), "TryLocalDnsFirst"), "enabled", FALSE);
    int autoMode = pbx_attr_bool(pbx_child(resolve, "AutoModeDetection"), "enabled", FALSE);

    if (autoMode)
    {
        // Proxifier decides by itself; the closest is the default, where the proxy's
        // own setting decides
        p->dns.mode = PB_DNS_MODE_SYSTEM;
        pbx_note(&nt, "The profile lets Proxifier detect the DNS settings automatically. The DNS policy was set to 'system'; check it in the DNS settings.");
    }
    else if (viaProxy)
    {
        p->dns.mode = PB_DNS_MODE_REMOTE;
        p->dns.leakProtection = 1;
        if (tryLocalFirst)
            pbx_note(&nt, "The profile tries the local DNS first and the proxy second. ProxyBridge asks the proxy server to resolve the name.");
    }
    else p->dns.mode = PB_DNS_MODE_LOCAL;

    // the names that are resolved locally and never reach the proxy
    const PBXNode* list = pbx_child(resolve, "ExclusionList");
    if (list)
    {
        wchar_t names[PB_DNS_MAX_EXCLUDED][PB_DNS_NAME_MAX];
        int count = 0;
        wchar_t wide[16384];
        pbx_to_wide(list->text ? list->text : "", wide, 16384);
        wchar_t* piece = wide;
        while (*piece && count < PB_DNS_MAX_EXCLUDED)
        {
            wchar_t* end = piece;
            while (*end && *end != L';') end++;
            wchar_t save = *end;
            *end = 0;
            wchar_t* s = piece;
            while (*s && pbx_is_wspace(*s)) s++;
            size_t l = wcslen(s);
            while (l > 0 && pbx_is_wspace(s[l - 1])) s[--l] = 0;
            // %ComputerName% is a constant only Proxifier knows
            if (_wcsicmp(s, L"%ComputerName%") == 0)
            {
                wchar_t host[256];
                if (pbx_computer_name(host, 256))
                {
                    // the name goes where the constant was, so it has to fit there
                    size_t room = (size_t)(wide + 16384 - s);
                    wcsncpy_s(s, room, host, _TRUNCATE);
                }
                else s[0] = 0;
            }
            if (s[0])
            {
                BOOL seen = FALSE;
                for (int j = 0; j < count; j++) if (_wcsicmp(names[j], s) == 0) { seen = TRUE; break; }
                if (!seen) wcsncpy_s(names[count++], PB_DNS_NAME_MAX, s, _TRUNCATE);
            }
            if (!save) break;
            piece = end + 1;
        }
        if (pbx_attr_bool(list, "ExcludeLocalhost", FALSE))
        {
            BOOL seen = FALSE;
            for (int j = 0; j < count; j++) if (_wcsicmp(names[j], L"localhost") == 0) { seen = TRUE; break; }
            if (!seen && count < PB_DNS_MAX_EXCLUDED) wcsncpy_s(names[count++], PB_DNS_NAME_MAX, L"localhost", _TRUNCATE);
        }
        if (pbx_attr_bool(list, "ExcludeLocalDomain", FALSE))
        {
            BOOL seen = FALSE;
            for (int j = 0; j < count; j++) if (_wcsicmp(names[j], L"*.local") == 0) { seen = TRUE; break; }
            if (!seen && count < PB_DNS_MAX_EXCLUDED) wcsncpy_s(names[count++], PB_DNS_NAME_MAX, L"*.local", _TRUNCATE);
        }
        if (pbx_attr_bool(list, "ExcludeSelfHostname", FALSE))
        {
            wchar_t host[256];
            if (pbx_computer_name(host, 256))
            {
                BOOL seen = FALSE;
                for (int j = 0; j < count; j++) if (_wcsicmp(names[j], host) == 0) { seen = TRUE; break; }
                if (!seen && count < PB_DNS_MAX_EXCLUDED) wcsncpy_s(names[count++], PB_DNS_NAME_MAX, host, _TRUNCATE);
            }
        }
        for (int j = 0; j < count; j++) wcsncpy_s(p->dns.excluded[j], PB_DNS_NAME_MAX, names[j], _TRUNCATE);
        p->dns.excludedCount = count;
    }

    pbx_doc_free(&doc);
    return TRUE;
}

BOOL PB_ImportPPX(const wchar_t* path, PBProfile* p, wchar_t* notes, int cchNotes)
{
    if (!path || !p) return FALSE;
    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return FALSE;
    LARGE_INTEGER size;
    if (!GetFileSizeEx(f, &size) || size.QuadPart <= 0 || size.QuadPart > 8 * 1024 * 1024)
    {
        CloseHandle(f);
        return FALSE;
    }
    size_t len = (size_t)size.QuadPart;
    char* data = (char*)malloc(len + 1);
    if (!data) { CloseHandle(f); return FALSE; }
    DWORD read = 0;
    BOOL ok = ReadFile(f, data, (DWORD)len, &read, NULL);
    CloseHandle(f);
    if (!ok || read != len) { free(data); return FALSE; }
    data[len] = '\0';
    BOOL result = PB_ImportPPXData(data, len, p, notes, cchNotes);
    free(data);
    return result;
}
