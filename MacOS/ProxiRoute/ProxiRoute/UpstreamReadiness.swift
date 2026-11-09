import Foundation

// Whether an upstream that runs on this machine is ready to be used.
//
// The probe is a connection to the port: a proxy that answers on its port is
// a proxy that is there. Nothing is sent through it - the connection is closed
// right away - so the probe does not put anything into the log of the proxy
// and does not make a request on behalf of the person.
//
// The probe is made on a thread of its own, and it is the only place in the
// app that waits for something without being asked.

enum UpstreamReadiness {

    /// Whether something is listening on the port of the endpoint.
    ///
    /// The connection is made and closed again, so the proxy on the other end
    /// sees a connection that carried nothing. That is enough to tell that it
    /// is up.
    static func canConnect(_ endpoint: UpstreamEndpoint, timeout: TimeInterval = 1.0) -> Bool {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(endpoint.host, String(endpoint.port), &hints, &result)
        guard status == 0, let list = result else { return false }
        defer { freeaddrinfo(list) }

        var entry: UnsafeMutablePointer<addrinfo>? = list
        while let current = entry {
            if canConnect(address: current.pointee, timeout: timeout) {
                return true
            }
            entry = current.pointee.ai_next
        }
        return false
    }

    /// The same, for one address of the list of the host.
    private static func canConnect(address: addrinfo, timeout: TimeInterval) -> Bool {
        let descriptor = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // The connection is not waited for with a blocking call: the host may
        // be a name that takes a moment to be resolved, and the wait has to
        // have a limit of its own.
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        let result = connect(descriptor, address.ai_addr, socklen_t(address.ai_addrlen))
        if result == 0 {
            return true
        }
        // the connection is on its way: the wait is for it to be finished
        guard errno == EINPROGRESS else { return false }

        var waiting = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&waiting, 1, Int32(timeout * 1000))
        guard ready > 0 else { return false }

        // the connection is there, or it is not: the reason is in the socket
        var reason: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &reason, &length) == 0 else { return false }
        return reason == 0
    }

    /// Waits until the endpoint that matters most answers.
    ///
    /// The endpoints come in the order of how much they carry: the first one
    /// is the one that the most rules use. The wait ends as soon as that one
    /// answers, because an upstream that carries three rules out of
    /// twenty-six must not hold up the whole proxy.
    ///
    /// The endpoints that are still not ready when the wait is over are given
    /// back: the caller decides what to do with them, and the app starts
    /// anyway - a proxy that is not there is a reason to say so, not a reason
    /// to never start.
    ///
    /// The work is done on a thread of its own, so that the window of the app
    /// keeps answering while it waits.
    static func wait(for endpoints: [UpstreamEndpoint],
                     timeout: TimeInterval,
                     queue: DispatchQueue = DispatchQueue(label: "com.sdpong.proxiroute.upstream-readiness"),
                     onReady: @escaping (UpstreamEndpoint) -> Void,
                     completion: @escaping ([UpstreamEndpoint]) -> Void) {
        guard !endpoints.isEmpty else {
            completion([])
            return
        }
        queue.async {
            let deadline = Date().addingTimeInterval(timeout)
            let mostUsed = endpoints[0]
            var ready: [UpstreamEndpoint] = []

            while true {
                for endpoint in endpoints where !ready.contains(endpoint) {
                    if canConnect(endpoint, timeout: 1.0) {
                        ready.append(endpoint)
                        onReady(endpoint)
                    }
                }
                // the one that carries the most is there: the wait is over
                if ready.contains(mostUsed) { break }
                if Date() >= deadline { break }
                Thread.sleep(forTimeInterval: 0.5)
            }

            completion(endpoints.filter { !ready.contains($0) })
        }
    }
}
