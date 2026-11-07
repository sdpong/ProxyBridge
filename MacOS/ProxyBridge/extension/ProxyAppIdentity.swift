import Foundation

// What the proxy server is told about the application the traffic comes from.
//
// Proxifier decides per application which proxy a connection uses, but the
// proxy server itself only sees "a connection from somewhere". A proxy server
// that wants to route by application - a local Clash with an "IN-USER" rule,
// a gateway that bills per app - has no way to know which app opened the
// connection.
//
// The protocols have room for it, but not in the same way:
//
//   * HTTP: the CONNECT request is an ordinary HTTP request, and a client may
//     put any header it likes in it. A proxy server that does not know the
//     header ignores it, exactly as it ignores any other unknown header.
//   * SOCKS4: the request carries a free text user id field. It is ignored by
//     most servers, and used by some for authentication.
//   * SOCKS5: the only free text field is the user name of the RFC 1929
//     user/password authentication, and it is only sent when the server asks
//     for authentication. So the client has to offer the authentication method
//     alone - offering "no authentication" as well would let the server pick
//     that one, and the user name would never be sent.
//
// The payload is kept apart from the network code so it can be tested.
enum ProxyAppIdentity {

    // The header that carries the bundle id over HTTP.
    static let httpBundleIdHeader = "ProxyBridge-App-Id"
    // The header that carries the name of the application over HTTP.
    static let httpProcessNameHeader = "ProxyBridge-Process"

    // What the client tells the proxy server about the application.
    struct Payload: Equatable {
        // the bundle id of the application, e.g. "com.apple.dia"
        let bundleId: String
        // the name of the application, e.g. "Dia"
        let processName: String

        init(bundleId: String, processName: String) {
            self.bundleId = bundleId
            self.processName = processName
        }

        // the value that is sent. the bundle id is the one that identifies the
        // application on every system, so it is the one that is sent; the
        // process name is a convenience for a human reading a log.
        var value: String {
            return bundleId.isEmpty ? processName : bundleId
        }

        var isEmpty: Bool {
            return bundleId.isEmpty && processName.isEmpty
        }
    }

    // The header lines for an HTTP CONNECT request.
    //
    // An empty list means nothing is added: the request stays exactly what it
    // was before this feature existed.
    static func httpHeaderLines(for payload: Payload?) -> [String] {
        guard let payload = payload, !payload.isEmpty else { return [] }
        var lines: [String] = []
        if !payload.bundleId.isEmpty {
            lines.append("\(httpBundleIdHeader): \(headerSafe(payload.bundleId))")
        }
        if !payload.processName.isEmpty {
            lines.append("\(httpProcessNameHeader): \(headerSafe(payload.processName))")
        }
        return lines
    }

    // A header value must not contain a line break: a name with one in it would
    // end the header and turn the rest of it into a request of its own.
    static func headerSafe(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // The methods the client offers in the SOCKS5 greeting.
    //
    // With the application id the client offers the user/password method on
    // its own: the server picks the method it likes best out of the ones that
    // are offered, and a server that prefers "no authentication" would pick
    // that one and the user name would never arrive.
    static func socks5GreetingMethods(sendAppId: Bool, hasCredentials: Bool) -> [UInt8] {
        if sendAppId && !hasCredentials {
            return [0x02]
        }
        if hasCredentials {
            return [0x00, 0x02]
        }
        return [0x00]
    }

    // The user name and password of the SOCKS5 authentication.
    //
    // The configured credentials win: they are what the server checks. The
    // application id is only sent when there are none, because there is one
    // field and it can hold one thing.
    static func socks5Credentials(payload: Payload?,
                                   username: String?,
                                   password: String?) -> (username: String, password: String)? {
        if let username = username, let password = password, !username.isEmpty {
            return (username, password)
        }
        guard let payload = payload, !payload.value.isEmpty else { return nil }
        // The password is not empty: a server that asked for authentication
        // expects one, and some of them refuse the connection when it is
        // missing. The application id goes into both fields, so a server that
        // wants the same value on both sides is happy as well.
        return (payload.value, payload.value)
    }

    // The user id of a SOCKS4 request.
    //
    // Same rule as for SOCKS5: the configured user id wins, the application id
    // is only used when there is none.
    static func socks4UserId(payload: Payload?, username: String?) -> String? {
        if let username = username, !username.isEmpty {
            return username
        }
        guard let payload = payload, !payload.value.isEmpty else { return nil }
        return payload.value
    }
}
