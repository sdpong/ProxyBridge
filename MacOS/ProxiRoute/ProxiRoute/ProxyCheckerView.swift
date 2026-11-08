import SwiftUI
import Combine
import Darwin
import Network

struct ProxyCheckerView: View {
    // the language of the app: the strings are read through it, so a change of
    // the language redraws the window
    @ObservedObject private var loc = LocalizationManager.shared
    let config: ProxiRouteViewModel.ProxyConfig
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ProxyCheckerModel

    init(config: ProxiRouteViewModel.ProxyConfig) {
        self.config = config
        _model = StateObject(wrappedValue: ProxyCheckerModel(config: config))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.t("Host:")).fontWeight(.medium)
                TextField("www.google.com", text: $model.targetHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                Text(L10n.t("Port:")).fontWeight(.medium)
                TextField("80", text: $model.targetPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Spacer()
                Button(L10n.t("Retest")) { model.run() }
                    .disabled(model.isRunning)
                Button(L10n.t("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                Text(model.log)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(width: 640, height: 460)
        .onAppear { model.run() }
    }
}

final class ProxyCheckerModel: ObservableObject {
    @Published var log = ""
    @Published var targetHost = "www.google.com"
    @Published var targetPort = "80"
    @Published var isRunning = false

    private let config: ProxiRouteViewModel.ProxyConfig

    init(config: ProxiRouteViewModel.ProxyConfig) {
        self.config = config
    }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        log = ""
        let host = targetHost.trimmingCharacters(in: .whitespaces)
        let port = Int(targetPort) ?? 80
        DispatchQueue.global().async {
            self.performTests(targetHost: host, targetPort: port)
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func line(_ text: String) {
        DispatchQueue.main.async { self.log += text + "\n" }
    }

    private func performTests(targetHost: String, targetPort: Int) {
        let proxyHost = config.host
        let proxyPort = config.port
        let proxyType = config.type.lowercased()
        let isSocks5 = proxyType == "socks5"
        let isSocks4 = proxyType == "socks4"
        let hasAuth = config.username != nil && config.password != nil

        line("Proxy:    \(proxyHost):\(proxyPort)")
        line("Protocol: \(config.type.uppercased())")
        line("Auth:     \(hasAuth ? "yes" : "no")")
        line("Target:   \(targetHost):\(targetPort)")
        line("")

        // Test 1 - reach the proxy
        line("Test 1: Connection to the proxy server")
        guard let (fd1, ms1) = openConnection(host: proxyHost, port: proxyPort) else {
            line("  Could not connect to the proxy")
            line("  Test 1 failed")
            line("")
            line("Testing finished: proxy is not reachable.")
            return
        }
        line(String(format: "  Connection established (%.0f ms)", ms1))
        line("  Test 1 passed")
        line("")

        // Test 2 - go through the proxy to the target
        line("Test 2: Connection through the proxy server")
        var connected = false
        if isSocks5 {
            if socks5Handshake(fd1, hasAuth: hasAuth) {
                let (ok, reason) = socks5Connect(fd1, host: targetHost, port: targetPort)
                connected = ok
                if !ok { line("  SOCKS5 CONNECT failed: \(reason)") }
            } else {
                line("  SOCKS5 handshake or auth failed")
            }
        } else if isSocks4 {
            let (ok, reason) = socks4Connect(fd1, host: targetHost, port: targetPort, username: config.username)
            connected = ok
            if !ok { line("  SOCKS4 CONNECT failed: \(reason)") }
        } else {
            let (ok, firstLine) = httpConnect(fd1, host: targetHost, port: targetPort)
            connected = ok
            if !ok { line("  HTTP CONNECT failed: \(firstLine)") }
        }

        if connected {
            let request = "GET / HTTP/1.0\r\nHost: \(targetHost)\r\nConnection: close\r\n\r\n"
            _ = sendAll(fd1, Array(request.utf8))
            let response = String(bytes: recvBytes(fd1, 512), encoding: .utf8) ?? ""
            let status = response.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? "no response"
            line("  Connection to \(targetHost):\(targetPort) established through the proxy")
            line("  Page loaded: \(status)")
            line("  Test 2 passed")
        } else {
            line("  Test 2 failed")
        }
        Darwin.close(fd1)
        line("")

        // Test 3 - latency (fresh connect to the proxy)
        line("Test 3: Proxy server latency")
        if let (fd3, ms3) = openConnection(host: proxyHost, port: proxyPort) {
            line(String(format: "  Latency = %.0f ms", ms3))
            line("  Test 3 passed")
            Darwin.close(fd3)
        } else {
            line("  Could not measure latency")
            line("  Test 3 failed")
        }
        line("")

        // Test 4 - SOCKS5 UDP ASSOCIATE support
        if isSocks5 {
            line("Test 4: SOCKS5 UDP ASSOCIATE support")
            if let (fd4, _) = openConnection(host: proxyHost, port: proxyPort) {
                if socks5Handshake(fd4, hasAuth: hasAuth) {
                    let (granted, info) = socks5UDPAssociate(fd4)
                    if granted {
                        line("  UDP ASSOCIATE granted; relay = \(info)")
                        line("  UDP is supported by this proxy")
                    } else {
                        line("  UDP ASSOCIATE rejected: \(info)")
                        line("  UDP is not supported by this proxy")
                    }
                } else {
                    line("  Handshake failed")
                }
                Darwin.close(fd4)
            } else {
                line("  Could not connect to the proxy")
            }
            line("")
        }

        line("Testing finished.")
    }

    // MARK: - sockets

    // The sockets live in ProxySocket, so that the test of a proxy and the test
    // of a chain speak the same language.
    private func openConnection(host: String, port: Int) -> (Int32, Double)? {
        return ProxySocket.open(host: host, port: port)
    }

    private func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        return ProxySocket.sendAll(fd, bytes)
    }

    private func recvBytes(_ fd: Int32, _ maxLen: Int) -> [UInt8] {
        return ProxySocket.recvBytes(fd, maxLen)
    }

    private func recvExact(_ fd: Int32, _ n: Int) -> [UInt8]? {
        return ProxySocket.recvExact(fd, n)
    }

    // MARK: - SOCKS5

    private func socks5Handshake(_ fd: Int32, hasAuth: Bool) -> Bool {
        return ProxySocket.socks5Handshake(fd,
                                           username: hasAuth ? config.username : nil,
                                           password: hasAuth ? config.password : nil)
    }

    private func socks5Connect(_ fd: Int32, host: String, port: Int) -> (Bool, String) {
        var req: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(min(host.utf8.count, 255))]
        req += Array(host.utf8.prefix(255))
        req.append(UInt8(port >> 8))
        req.append(UInt8(port & 0xFF))
        guard sendAll(fd, req), let head = recvExact(fd, 4), head[0] == 0x05 else { return (false, "no reply") }
        if head[1] != 0x00 { return (false, "REP=0x\(hex(head[1])) (\(socksReason(head[1])))") }
        return (consumeBoundAddress(fd, atyp: head[3]) != nil, "")
    }

    private func socks5UDPAssociate(_ fd: Int32) -> (Bool, String) {
        let req: [UInt8] = [0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        guard sendAll(fd, req), let head = recvExact(fd, 4), head[0] == 0x05 else { return (false, "no reply") }
        if head[1] != 0x00 { return (false, "REP=0x\(hex(head[1])) (\(socksReason(head[1])))") }
        guard let relay = consumeBoundAddress(fd, atyp: head[3]) else { return (false, "bad reply") }
        return (true, relay)
    }

    // reads the bound address + port that follows a SOCKS5 reply header, returns "host:port"
    private func consumeBoundAddress(_ fd: Int32, atyp: UInt8) -> String? {
        var host = ""
        switch atyp {
        case 0x01:
            guard let a = recvExact(fd, 4) else { return nil }
            host = "\(a[0]).\(a[1]).\(a[2]).\(a[3])"
        case 0x04:
            guard let a = recvExact(fd, 16) else { return nil }
            var parts: [String] = []
            for i in stride(from: 0, to: 16, by: 2) {
                parts.append(String(format: "%x", (UInt16(a[i]) << 8) | UInt16(a[i + 1])))
            }
            host = parts.joined(separator: ":")
        case 0x03:
            guard let l = recvExact(fd, 1)?.first, let d = recvExact(fd, Int(l)) else { return nil }
            host = String(bytes: d, encoding: .utf8) ?? "?"
        default:
            return nil
        }
        guard let p = recvExact(fd, 2) else { return nil }
        return "\(host):\((Int(p[0]) << 8) | Int(p[1]))"
    }

    // MARK: - HTTP CONNECT

    private func socks4Connect(_ fd: Int32, host: String, port: Int, username: String?) -> (Bool, String) {
        return ProxySocket.socks4Connect(fd, host: host, port: port, username: username)
    }

    private func httpConnect(_ fd: Int32, host: String, port: Int) -> (Bool, String) {
        return ProxySocket.httpConnect(fd, host: host, port: port, username: config.username, password: config.password)
    }

    private func hex(_ b: UInt8) -> String { ProxySocket.hex(b) }

    private func socksReason(_ rep: UInt8) -> String { ProxySocket.socksReason(rep) }
}
