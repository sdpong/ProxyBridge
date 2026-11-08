import Foundation

// A Proxifier profile (.ppx) is an XML document. Proxifier for macOS and Proxifier for
// Windows write the same format, so one reader serves both.
//
// The importer turns a .ppx into the same dictionary the app's own .pbprofile export
// produces, so the existing import path takes it unchanged. What Proxifier has and
// ProxiRoute does not (traffic encryption, QUIC blocking, loop detection) is reported
// instead of being dropped silently.
//
// The Windows side has the same mapping in Windows/gui/profile/ppx.c. The two have to
// agree, so the test files hold the same cases.

// MARK: - the XML tree

private final class PPXNode {
    var element: String
    var text = ""
    var attributes: [String: String] = [:]
    var children: [PPXNode] = []

    init(element: String) { self.element = element }

    // the text of an element, without the whitespace around it
    var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func child(_ name: String) -> PPXNode? { children.first { $0.element == name } }
    func all(_ name: String) -> [PPXNode] { children.filter { $0.element == name } }

    // the enabled="..." of this element. nil when there is no such attribute, or when
    // it holds something else; the caller then uses its own default
    func enabledFlag() -> Bool? {
        guard let raw = attributes["enabled"]?.lowercased() else { return nil }
        if raw == "true" || raw == "1" || raw == "yes" { return true }
        if raw == "false" || raw == "0" || raw == "no" { return false }
        return nil
    }

    // the enabled="true" of a child, nil when the child is not there
    func flag(_ name: String) -> Bool? { return child(name)?.enabledFlag() }
}

private final class PPXTreeBuilder: NSObject, XMLParserDelegate {
    var root: PPXNode?
    private var stack: [PPXNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = PPXNode(element: elementName)
        node.attributes = attributeDict
        if let top = stack.last {
            top.children.append(node)
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { stack.last?.text.append(s) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
}

// MARK: - the result

struct PPXImport {
    // the profile in the shape the app's own .pbprofile export has
    var profile: [String: Any]
    // what could not be carried over, in the order it was found
    var warnings: [String]
    // the name the profile should get
    var name: String
}

// MARK: - the importer

enum PPXImporter {
    // the largest profile we read, so a huge file cannot use all the memory
    static let maxBytes = 8 * 1024 * 1024

    // true when the data looks like a Proxifier profile rather than a .pbprofile
    static func looksLikePPX(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(1024), as: UTF8.self)
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<!DOCTYPE") { return true }
        return trimmed.hasPrefix("<ProxifierProfile")
    }

    static func parse(_ data: Data, name: String? = nil) -> PPXImport? {
        guard data.count <= maxBytes else { return nil }
        let parser = XMLParser(data: data)
        // a profile is data, not a document that may pull in other documents
        parser.shouldResolveExternalEntities = false
        let builder = PPXTreeBuilder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root, root.element == "ProxifierProfile" else { return nil }

        var converter = PPXConverter(root: root, warnings: [])
        return converter.convert(profileName: name)
    }
}

// MARK: - the conversion

private struct PPXConverter {
    let root: PPXNode
    var warnings: [String]

    // ── proxies ─────────────────────────────────────────────────────────────

    // the proxy id (as a string, the app treats ids as opaque) and whether the
    // proxy server resolves the name itself
    private struct ProxyEntry {
        var id: String
        var type: String
        var sendDomain: Bool
    }

    private mutating func readProxies() -> [ProxyEntry] {
        var out: [ProxyEntry] = []
        var httpProxies = 0
        var httpSkipped = 0
        // Proxifier can be told to leave HTTP proxies alone
        let httpAllowed = root.child("Options")?.child("HttpProxiesSupport")?.enabledFlag() ?? true
        for node in root.child("ProxyList")?.all("Proxy") ?? [] {
            guard let id = node.attributes["id"] else { continue }
            let rawType = (node.attributes["type"] ?? "").uppercased()
            var sendDomain = true
            var type = ""
            switch rawType {
            case "SOCKS5": type = "socks5"
            case "SOCKS4":
                // plain socks4 can only carry an address
                type = "socks4"; sendDomain = false
            case "SOCKS4A":
                // socks4a is socks4 with a name instead of an address
                type = "socks4"; sendDomain = true
            case "HTTPS":
                // Proxifier's "HTTPS" is an HTTP proxy that opens CONNECT tunnels
                type = "http"
            case "HTTP":
                type = "http"
                if !httpAllowed {
                    httpSkipped += 1
                    continue
                }
                httpProxies += 1
            default:
                warnings.append(L10n.f("Proxy %@ has the type '%@', which ProxiRoute does not know. It was left out.", "\(id)", rawType))
                continue
            }
            out.append(ProxyEntry(id: id, type: type, sendDomain: sendDomain))
        }
        if httpSkipped > 0 {
            warnings.append(L10n.f("The profile says HTTP proxy servers are not used, so %@ HTTP proxy/proxies were left out.", "\(httpSkipped)"))
        }
        if httpProxies > 0 {
            warnings.append(L10n.f("Proxifier's plain HTTP proxy mode has no CONNECT tunnel. The %@ HTTP proxy/proxies were imported, but ProxiRoute always asks them for a CONNECT tunnel.", "\(httpProxies)"))
        }
        return out
    }

    // ── the conversion ──────────────────────────────────────────────────────

    mutating func convert(profileName: String?) -> PPXImport {
        let proxyEntries = readProxies()
        let proxyIds = Set(proxyEntries.map { $0.id })

        // the proxies, in the shape the app's export has
        var configs: [[String: Any]] = []
        for node in root.child("ProxyList")?.all("Proxy") ?? [] {
            guard let id = node.attributes["id"], let entry = proxyEntries.first(where: { $0.id == id }) else { continue }
            let address = node.child("Address")?.value ?? ""
            let port = Int(node.child("Port")?.value ?? "") ?? 0
            guard !address.isEmpty, port > 0 else {
                warnings.append(L10n.f("Proxy %@ has no address or no port. It was left out.", "\(id)"))
                continue
            }
            var config: [String: Any] = [
                "id": id,
                "name": node.child("Label")?.value ?? "",
                "type": entry.type,
                "host": address,
                "port": port,
                "sendDomain": entry.sendDomain
            ]
            let auth = node.child("Authentication")
            if auth?.attributes["enabled"]?.lowercased() == "true" {
                let user = auth?.child("Username")?.value ?? ""
                let pass = auth?.child("Password")?.value ?? ""
                if !user.isEmpty { config["username"] = user }
                if !pass.isEmpty { config["password"] = pass }
            }
            configs.append(config)
        }

        // the chains. Proxifier keeps every proxy of a chain in the list and lets the
        // user switch the ones that are off; only the ones that are on are walked.
        var chains: [[String: Any]] = []
        // the ids of the chains that were really imported: a rule that names a chain
        // that was left out has to go direct, not point at nothing
        var chainIds = Set<String>()
        for node in root.child("ChainList")?.all("Chain") ?? [] {
            guard let id = node.attributes["id"] else { continue }
            var hops: [String] = []
            for hop in node.all("Proxy") {
                guard hop.enabledFlag() ?? true else { continue }
                let proxyId = hop.value
                if proxyIds.contains(proxyId) { hops.append(proxyId) }
            }
            if hops.isEmpty {
                warnings.append(L10n.f("The chain '%@' has no proxy that is switched on. It was left out, and the rules that named it go direct.", node.child("Name")?.value ?? id))
                continue
            }
            chainIds.insert(id)
            chains.append(["id": id, "name": node.child("Name")?.value ?? "", "proxies": hops])
        }

        // the rules, in the order they are in the file: Proxifier takes the first
        // rule that matches, and so does ProxiRoute
        var rules: [[String: Any]] = []
        for node in root.child("RuleList")?.all("Rule") ?? [] {
            guard let action = node.child("Action") else { continue }
            let actionType = (action.attributes["type"] ?? "").lowercased()
            var actionValue = "DIRECT"
            switch actionType {
            case "direct": actionValue = "DIRECT"
            case "block": actionValue = "BLOCK"
            case "proxy":
                let id = action.value
                guard proxyIds.contains(id) else {
                    warnings.append(L10n.f("A rule points at proxy %@, which is not in the profile. It goes direct.", "\(id)"))
                    actionValue = "DIRECT"
                    break
                }
                actionValue = id
            case "chain":
                let id = action.value
                guard chainIds.contains(id) else {
                    warnings.append(L10n.f("A rule points at chain %@, which is not in the profile. It goes direct.", "\(id)"))
                    actionValue = "DIRECT"
                    break
                }
                actionValue = ProxyChain.actionPrefix + id
            default:
                warnings.append(L10n.f("A rule has the action '%@', which ProxiRoute does not know. It goes direct.", actionType))
                actionValue = "DIRECT"
            }
            let rule: [String: Any] = [
                "name": node.child("Name")?.value ?? "",
                "processNames": normalizeApplications(node.child("Applications")?.value ?? ""),
                "targetHosts": normalizeList(node.child("Targets")?.value ?? ""),
                "targetPorts": normalizeList(node.child("Ports")?.value ?? ""),
                // Proxifier proxies TCP only
                "protocol": "TCP",
                "action": actionValue,
                "enabled": node.enabledFlag() ?? true
            ]
            rules.append(rule)
        }

        // the name resolution settings become the DNS policy
        let policy = dnsPolicy()

        let name = (profileName?.isEmpty == false) ? profileName! : "Proxifier"
        let profile: [String: Any] = [
            "name": name,
            "proxyConfigs": configs,
            "proxyRules": rules,
            "proxyChains": chains,
            "dnsPolicy": policy,
            "dnsEnabled": true,
            "trafficLoggingEnabled": true,
            "closeToMenuBar": false,
            "runAtStartup": false
        ]

        return PPXImport(profile: profile, warnings: warnings, name: name)
    }

    // ── the DNS policy ──────────────────────────────────────────────────────

    private mutating func dnsPolicy() -> [String: Any] {
        let resolve = root.child("Options")?.child("Resolve")
        let viaProxy = resolve?.flag("ViaProxy") ?? false
        let tryLocalFirst = resolve?.child("ViaProxy")?.flag("TryLocalDnsFirst") ?? false
        let autoMode = resolve?.flag("AutoModeDetection") ?? false

        var mode = "local"
        var leakProtection = false
        if autoMode {
            // Proxifier decides by itself; the closest is the default, where the
            // proxy's own setting decides
            mode = "system"
            warnings.append(L10n.t("The profile lets Proxifier detect the DNS settings automatically. The DNS policy was set to 'system'; check it in the DNS settings."))
        } else if viaProxy {
            mode = "remote"
            leakProtection = true
            if tryLocalFirst {
                warnings.append(L10n.t("The profile tries the local DNS first and the proxy second. ProxiRoute asks the proxy server to resolve the name."))
            }
        }

        // the names that are resolved locally and never reach the proxy
        var excluded: [String] = []
        if let list = resolve?.child("ExclusionList") {
            let attrs = list.attributes
            // %ComputerName% is a constant only Proxifier knows; the name of this
            // machine goes in instead
            let host = ProcessInfo.processInfo.hostName
            for piece in list.value.components(separatedBy: ";") {
                var item = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if item.lowercased() == "%computername%" { item = host }
                if item.isEmpty { continue }
                // a name is the same name whatever its case
                if excluded.contains(where: { $0.lowercased() == item.lowercased() }) { continue }
                excluded.append(item)
            }
            func add(_ name: String) {
                guard !name.isEmpty else { return }
                if excluded.contains(where: { $0.lowercased() == name.lowercased() }) { return }
                excluded.append(name)
            }
            if attrs["ExcludeLocalhost"]?.lowercased() == "true" { add("localhost") }
            if attrs["ExcludeLocalDomain"]?.lowercased() == "true" { add("*.local") }
            if attrs["ExcludeSelfHostname"]?.lowercased() == "true" { add(host) }
        }

        return [
            "mode": mode,
            "excludedDomains": excluded,
            "upstreamResolvers": [String](),
            "autoDetectUpstream": true,
            "leakProtection": leakProtection
        ]
    }

    // ── the little helpers ──────────────────────────────────────────────────

    // Proxifier writes the applications as a list separated by semicolons, and
    // writes the name of an app in quotes when the name has a space in it. The
    // matcher compares the pattern with the bundle id and with the name of the
    // executable, so the quotes and the .app suffix are taken off. A quote that
    // was typed by hand can be a curly one, so both kinds go.
    private func normalizeApplications(_ raw: String) -> String {
        let quotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "'", "\u{2018}", "\u{2019}"]
        var out: [String] = []
        for piece in raw.components(separatedBy: ";") {
            var item = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            while item.count >= 2, let first = item.first, let last = item.last,
                  quotes.contains(first), quotes.contains(last) {
                item = String(item.dropFirst().dropLast())
                item = item.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if item.lowercased().hasSuffix(".app") {
                item = String(item.dropLast(4))
            }
            if item.isEmpty { continue }
            // a profile often lists the same app twice ("QQ.app" and "QQ")
            if out.contains(item) { continue }
            out.append(item)
        }
        return out.joined(separator: ";")
    }

    // a list of hosts or ports: the pieces are trimmed and the empty ones go away
    private func normalizeList(_ raw: String) -> String {
        var out: [String] = []
        for piece in raw.components(separatedBy: ";") {
            let item = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isEmpty { continue }
            out.append(item)
        }
        return out.joined(separator: ";")
    }
}
