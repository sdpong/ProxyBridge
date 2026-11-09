import Foundation

// The app's side of the conversation with the helper.
//
// The helper is a program of root that does the three things that need root,
// and the app asks it for them over a unix socket. This file is the app's
// half of that conversation: it opens the socket, asks a question, and reads
// the answer.
//
// The questions themselves are written down in GatewayProtocol.swift, which
// the helper reads as well. A question that is written twice is a question
// with two meanings, and the two meanings only meet at runtime, in a
// failure nobody can explain.

enum GatewayHelperClient {

    // The answer of the helper, and the reason if there was one.
    struct Result {
        let response: GatewayProtocol.Response
        let failure: String?

        // did it work
        var ok: Bool { response.ok && failure == nil }

        // the words to show the person in front of the window
        var message: String {
            if let failure { return failure }
            if let message = response.message, !message.isEmpty { return message }
            return response.ok ? "" : "The helper did not answer."
        }
    }

    // Asks the helper a question and waits for the answer.
    //
    // The wait is bounded: a helper that is busy or stuck must not freeze
    // the window.
    static func ask(_ request: GatewayProtocol.Request, timeout: TimeInterval = 5) -> Result {
        let path = GatewayProtocol.socketPathInUse
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return Result(response: GatewayProtocol.Response.failure(message: "The socket could not be made."),
                          failure: notInstalled())
        }
        defer { Darwin.close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return Result(response: GatewayProtocol.Response.failure(message: "The path of the socket is too long."),
                          failure: notInstalled())
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            var bytes = pathBytes
            bytes.append(0)
            raw.copyBytes(from: bytes)
        }
        let headerLength = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
        address.sun_len = UInt8(headerLength + pathBytes.count + 1)
        let addressLength = socklen_t(address.sun_len)

        let connected = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, addressLength)
            }
        }
        guard connected == 0 else {
            // the helper is not running: the socket is not there, or nobody
            // is listening on it
            return Result(response: GatewayProtocol.Response.failure(message: "The helper is not answering."),
                          failure: notInstalled())
        }

        // the wait is bounded on both sides: a helper that never answers
        // must not leave the window waiting
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let data = GatewayProtocol.encode(request) else {
            return Result(response: GatewayProtocol.Response.failure(message: "The question could not be written."),
                          failure: "The question could not be written.")
        }

        guard sendAll(fd, data) else {
            return Result(response: GatewayProtocol.Response.failure(message: "The helper did not take the question."),
                          failure: "The helper did not take the question.")
        }

        guard let line = readLine(from: fd), let response = GatewayProtocol.decodeResponse(line) else {
            return Result(response: GatewayProtocol.Response.failure(message: "The helper did not answer."),
                          failure: "The helper did not answer.")
        }

        return Result(response: response, failure: response.ok ? nil : response.message)
    }

    // Is the helper there?
    static func status() -> Result {
        return ask(.status())
    }

    // Turns the gateway on.
    static func enable(interface: String, redirectPort: Int) -> Result {
        return ask(.enable(interface: interface, redirectPort: redirectPort))
    }

    // Turns the gateway off.
    static func disable() -> Result {
        return ask(.disable())
    }

    // Where was this connection going before it was redirected?
    static func lookup(clientAddress: String, clientPort: Int,
                       destinationAddress: String, destinationPort: Int) -> Result {
        return ask(.lookup(clientAddress: clientAddress, clientPort: clientPort,
                           destinationAddress: destinationAddress, destinationPort: destinationPort))
    }

    // The words for a helper that is not there.
    //
    // The helper is installed by the package of ProxiRoute. A build that is
    // only the app bundle - the one that is unpacked from a zip - has no
    // helper, and the person is told so, with the way to get one.
    private static func notInstalled() -> String {
        return "The helper of the gateway mode is not installed. Install ProxiRoute with its package to use the gateway mode."
    }

    // Writes everything.
    private static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }

    // Reads one line: everything up to the newline that ends it.
    private static func readLine(from fd: Int32) -> Data? {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while out.count < 1 << 20 {
            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                out.append(contentsOf: buffer[0..<n])
                if let index = out.firstIndex(of: 0x0A) {
                    return out.subdata(in: out.startIndex..<index)
                }
                continue
            }
            if n == 0 {
                return out.isEmpty ? nil : out
            }
            if errno == EINTR { continue }
            return nil
        }
        return nil
    }
}
