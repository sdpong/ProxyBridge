import Foundation

// The settings of the proxy server that runs inside ProxiRoute.
//
// It is the other half of what ProxiRoute does: the extension sends the
// traffic of this machine out, and this server lets the other machines of
// the network send their traffic out through this one.
//
// The settings are a property of the machine and not of the profile: the
// server is there whether a profile is running or not.
struct LocalProxySettings: Equatable {

    // what the server listens for
    enum Mode: String, CaseIterable, Identifiable {
        case socks5 = "socks5"
        case http = "http"
        case both = "both"

        var id: String { rawValue }

        var speaksSOCKS5: Bool { self == .socks5 || self == .both }
        var speaksHTTP: Bool { self == .http || self == .both }
    }

    // where the traffic of the clients goes
    enum Upstream: Equatable {
        // straight out of this machine
        case direct
        // through one of the proxies of the app
        case proxy(String)
        // through the rules of the app. a client on the network has no
        // program, so only the rules that name a host or a port can match.
        case rules
    }

    var enabled = false
    var protocolMode = Mode.both
    // the address to listen on. empty means every address of this machine.
    var listenAddress = ""
    // the interface to listen on: "wifi", "ethernet" or empty for all of them
    var listenInterface = ""
    var port = 8888
    // udp needs a socks5 association, and only socks5 has one
    var udpEnabled = false
    var upstream: Upstream = .direct
    // how many clients may be connected at the same time
    var maxConnections = 64
    // a connection with no traffic for this many seconds is closed
    var idleTimeout = 300

    static let storageKey = "localProxySettings"

    // The defaults, for a server that was never set up.
    static let `default` = LocalProxySettings()

    func toDictionary() -> [String: Any] {
        var out: [String: Any] = [
            "enabled": enabled,
            "protocolMode": protocolMode.rawValue,
            "listenAddress": listenAddress,
            "listenInterface": listenInterface,
            "port": port,
            "udpEnabled": udpEnabled,
            "maxConnections": maxConnections,
            "idleTimeout": idleTimeout
        ]
        switch upstream {
        case .direct: out["upstream"] = "direct"
        case .rules: out["upstream"] = "rules"
        case .proxy(let id): out["upstream"] = "proxy"; out["upstreamProxyId"] = id
        }
        return out
    }

    static func fromDictionary(_ dict: [String: Any]) -> LocalProxySettings {
        var settings = LocalProxySettings()
        settings.enabled = dict["enabled"] as? Bool ?? false
        if let raw = dict["protocolMode"] as? String, let mode = Mode(rawValue: raw) {
            settings.protocolMode = mode
        }
        settings.listenAddress = dict["listenAddress"] as? String ?? ""
        settings.listenInterface = dict["listenInterface"] as? String ?? ""
        settings.port = dict["port"] as? Int ?? 8888
        settings.udpEnabled = dict["udpEnabled"] as? Bool ?? false
        settings.maxConnections = dict["maxConnections"] as? Int ?? 64
        settings.idleTimeout = dict["idleTimeout"] as? Int ?? 300
        if let kind = dict["upstream"] as? String {
            switch kind {
            case "proxy":
                settings.upstream = .proxy(dict["upstreamProxyId"] as? String ?? "")
            case "rules":
                settings.upstream = .rules
            default:
                settings.upstream = .direct
            }
        }
        return settings
    }

    static func load() -> LocalProxySettings {
        let dict = UserDefaults.standard.dictionary(forKey: storageKey)
        guard let dict = dict else { return LocalProxySettings.default }
        return LocalProxySettings.fromDictionary(dict)
    }

    func save() {
        UserDefaults.standard.set(toDictionary(), forKey: LocalProxySettings.storageKey)
    }
}

// Who is on the port.
//
// When the server cannot start because the port is taken, the person wants
// to know who took it. lsof says: it is on every Mac, and it gives the name
// of the program that holds the port.
enum PortOwner {

    // The name of the program that is listening on the port, or nil when the
    // port is free or when nothing says who has it.
    static func listener(ofPort port: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "pc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // the -F output is one field per line: p for the pid, c for the name
        var name: String?
        var pid: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p") { pid = String(line.dropFirst()) }
            if line.hasPrefix("c") { name = String(line.dropFirst()) }
        }
        guard let name = name, !name.isEmpty else { return nil }
        if let pid = pid { return "\(name) (pid \(pid))" }
        return name
    }
}
