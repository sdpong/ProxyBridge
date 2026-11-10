import Foundation

// The helper of the gateway mode.
//
// It is a program of root that does the three things that need root, and
// nothing else:
//
//   - it loads the rules of the packet filter and turns the forwarding of
//     the machine on, and puts both back when the gateway is turned off;
//   - it asks the kernel where a redirected connection was going before it
//     was redirected;
//   - it says whether it is there, so that the app can tell the person in
//     front of the window what is going on.
//
// The rules of the app, the proxies and the carrying of the bytes are not
// here. They are in the app, which runs as the person who is sitting in
// front of the machine: the app is the one that knows the rules, and the
// helper is the one that knows the machine.
//
// The helper is started by the system at boot and stays up. It waits on a
// unix socket and answers one question at a time.

final class GatewayHelper {

    // The socket it waits on.
    private var listener: Int32 = -1

    // Whether the gateway is on right now.
    //
    // The helper keeps this because the app asks it whether the gateway is
    // on, and because the helper has to know what to put back when it is
    // turned off.
    private var gatewayEnabled = false

    // The interface the traffic of the network comes in through.
    private var interface: String?
    // The port the redirected traffic is taken in on.
    private var redirectPort: Int?
    // The address the redirected traffic is taken in on.
    private var redirectAddress: String?

    // The version of the helper, which is in every answer.
    static let version = "1"

    // MARK: - the life of the helper

    func run() -> Int32 {
        // the socket is made first: a failure here is the one thing that
        // stops the helper from being any use at all
        let fd = listen()
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            FileHandle.standardError.write(Data("The helper could not open its socket: \(reason)\n".utf8))
            return 1
        }

        // the machine may be shut down while the helper is waiting
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        acceptLoop()
        close(listener)
        return 0
    }

    // Makes the socket and waits on it.
    private func listen() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = GatewayProtocol.socketPathInUse
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            return -1
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            // the path is written with the zero that ends it: the kernel
            // reads as many bytes as sun_len says, and without the zero it
            // would read whatever was in the memory after the name
            var bytes = pathBytes
            bytes.append(0)
            raw.copyBytes(from: bytes)
        }
        // The length of the address that is used: the two bytes in front of
        // the name (the length and the family), the name, and the zero that
        // ends it. The kernel reads as many bytes as this says, so a length
        // of the whole struct would have it read the memory after the name
        // as well.
        let headerLength = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
        address.sun_len = UInt8(headerLength + pathBytes.count + 1)

        // the socket of a run that was killed is left behind, and the new one
        // cannot take its place. The file is only removed when it is really
        // there: a helper that is not root cannot remove the socket of the
        // helper that is, and pretending that it did would only hide the
        // reason.
        if access(path, F_OK) == 0 {
            if unlink(path) != 0 {
                Darwin.close(fd)
                errno = EADDRINUSE
                return -1
            }
        }
        // the errno of the check above is still the one of the check, and it
        // would be told to the person as the reason of a later failure
        errno = 0

        // the length is read before the address is given to the kernel: the
        // address is borrowed while it is in use, and reading a field of it
        // at the same time is a fight over the same memory
        let addressLength = socklen_t(address.sun_len)
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(fd, generic, addressLength)
            }
        }
        guard bound == 0 else {
            // the socket of this run is not there, so nothing is left behind
            Darwin.close(fd)
            return -1
        }

        // the socket is for the people of the machine: the helper checks who
        // is on the other end of it anyway, but the folder is not for
        // everybody
        chmod(path, 0o666)

        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            return -1
        }

        listener = fd
        return fd
    }

    // Waits for a question and answers it, for as long as it is up.
    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            handle(client: client)
            Darwin.close(client)
        }
    }

    // Reads one question and answers it.
    private func handle(client: Int32) {
        // who is on the other end
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        let named = getsockopt(client, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0
        if !named || !GatewaySocket.isAllowed(uid: credentials.cr_uid) {
            // the answer says nothing about what was asked: a person who may
            // not talk to the helper learns nothing from the way it is refused
            let refusal = GatewayProtocol.Response.failure(message: "This program may not talk to the helper.")
            if let data = GatewayProtocol.encode(refusal) {
                _ = data.withUnsafeBytes { raw in
                    Darwin.send(client, raw.baseAddress, raw.count, 0)
                }
            }
            return
        }

        guard let line = readLine(from: client) else { return }
        guard let request = GatewayProtocol.decodeRequest(line) else {
            let refusal = GatewayProtocol.Response.failure(message: "That is not a question the helper understands.")
            send(response: refusal, to: client)
            return
        }

        let answer = respond(to: request)
        send(response: answer, to: client)
    }

    // Reads one line: everything up to the newline that ends it.
    private func readLine(from fd: Int32) -> Data? {
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
                // the other side went away before the line was finished
                return out.isEmpty ? nil : out
            }
            if errno == EINTR { continue }
            return nil
        }
        return nil
    }

    // Sends one answer.
    private func send(response: GatewayProtocol.Response, to fd: Int32) {
        guard let data = GatewayProtocol.encode(response) else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                sent += n
            }
        }
    }

    // MARK: - the questions

    // The answer to a question.
    private func respond(to request: GatewayProtocol.Request) -> GatewayProtocol.Response {
        switch request.command {
        case .status:
            return status()
        case .enable:
            return enable(request)
        case .disable:
            return disable()
        case .lookup:
            return lookup(request)
        }
    }

    // Is the helper there, and what is it doing?
    private func status() -> GatewayProtocol.Response {
        var answer = GatewayProtocol.Response.success(version: GatewayHelper.version)
        answer.gatewayEnabled = gatewayEnabled
        answer.filterEnabled = GatewayFilter.filterEnabled()
        answer.forwardingEnabled = GatewayFilter.forwardingEnabled()
        answer.interface = interface
        answer.redirectPort = redirectPort
        answer.redirectAddress = redirectAddress
        return answer
    }

    // Turn the gateway on.
    private func enable(_ request: GatewayProtocol.Request) -> GatewayProtocol.Response {
        guard let interface = request.interface, !interface.isEmpty else {
            return GatewayProtocol.Response.failure(message: "No interface was named for the gateway.")
        }
        guard let port = request.redirectPort, port > 0, port < 65536 else {
            return GatewayProtocol.Response.failure(message: "No port was named for the gateway.")
        }

        // the network of the clients is read from the interface itself, so
        // that the rules always describe the network as it is now
        guard let network = GatewayNetwork.info(interface: interface) else {
            return GatewayProtocol.Response.failure(message: "The interface \(interface) has no address on this network.")
        }

        // The address the traffic is redirected to.
        //
        // The app names it, because the app is the one that listens on it:
        // the answer of the filter has to come from the same place the
        // traffic was sent to, and the app is the one that sends it. The
        // address has to be an address of this machine, or the answer would
        // come from a place that does not exist.
        let ownAddresses = GatewayNetwork.addresses()
        let redirectAddress: String
        if let named = request.redirectAddress, !named.isEmpty {
            guard ownAddresses.contains(named) else {
                return GatewayProtocol.Response.failure(
                    message: "The address \(named) is not an address of this machine.")
            }
            redirectAddress = named
        } else {
            redirectAddress = network.address
        }

        // The addresses of the proxies: the traffic to a proxy does not go
        // through a proxy, or the proxy would be talking to itself. Only the
        // addresses that are written down as numbers can be named in a rule:
        // a proxy that is named by a word is not known to the filter.
        //
        // The same proxy may be written down many times in the list of the
        // app, and a rule that names an address twice is a rule that is read
        // twice.
        var seen = Set<String>()
        let proxyAddresses = (request.proxyHosts ?? []).filter { host in
            guard GatewayNetwork.number(host) != nil else { return false }
            return seen.insert(host).inserted
        }

        let rules = GatewayFilter.Rules(interface: interface,
                                         address: redirectAddress,
                                         subnet: network.subnet,
                                         redirectPort: port,
                                         ownAddresses: ownAddresses,
                                         proxyAddresses: proxyAddresses)
        switch GatewayFilter.enable(rules: rules) {
        case .success(let message):
            gatewayEnabled = true
            self.interface = interface
            redirectPort = port
            self.redirectAddress = redirectAddress
            var answer = GatewayProtocol.Response.success(message: message, version: GatewayHelper.version)
            answer.gatewayEnabled = true
            answer.interface = interface
            answer.redirectPort = port
            answer.redirectAddress = redirectAddress
            return answer
        case .failure(let failure):
            return GatewayProtocol.Response.failure(message: failure.reason)
        }
    }

    // Turn the gateway off.
    private func disable() -> GatewayProtocol.Response {
        switch GatewayFilter.disable() {
        case .success(let message):
            gatewayEnabled = false
            interface = nil
            redirectPort = nil
            var answer = GatewayProtocol.Response.success(message: message, version: GatewayHelper.version)
            answer.gatewayEnabled = false
            return answer
        case .failure(let failure):
            return GatewayProtocol.Response.failure(message: failure.reason)
        }
    }

    // Where was this connection going before it was redirected?
    private func lookup(_ request: GatewayProtocol.Request) -> GatewayProtocol.Response {
        guard let clientAddress = request.clientAddress,
              let clientPort = request.clientPort,
              let destinationAddress = request.destinationAddress,
              let destinationPort = request.destinationPort else {
            return GatewayProtocol.Response.failure(message: "That question does not say which connection it is about.")
        }

        guard let client = GatewayNetwork.number(clientAddress),
              let destination = GatewayNetwork.number(destinationAddress),
              clientPort > 0, clientPort < 65536,
              destinationPort > 0, destinationPort < 65536 else {
            return GatewayProtocol.Response.failure(message: "That question does not say a place this kernel knows.")
        }

        var result = proxiroute_natlook_result()
        // the ports go in the way the kernel wants them: the order of the
        // network, the same order the answer comes back in
        //
        // The protocol is said as well, because the kernel keeps the states
        // of tcp and of udp apart. A state of udp is only found when the
        // variant of the protocol is the one the filter gives to its own
        // rules: that was measured on this machine, where a lookup of a
        // datagram finds its state with the variant at one and finds
        // nothing with it at zero.
        let transport = (request.transport ?? "TCP").uppercased()
        let protocolNumber: Int32
        let protocolVariant: Int32
        if transport == "UDP" {
            protocolNumber = IPPROTO_UDP
            protocolVariant = PROXIROUTE_PF_EXTFILTER_APD
        } else {
            protocolNumber = IPPROTO_TCP
            protocolVariant = 0
        }

        let rc = proxiroute_natlook(client,
                                    UInt16(clientPort).bigEndian,
                                    destination,
                                    UInt16(destinationPort).bigEndian,
                                    protocolNumber,
                                    protocolVariant,
                                    &result)
        if rc != 0 {
            // the kernel says why: there is no such state, or there is more
            // than one and it will not choose
            let reason = String(cString: strerror(errno))
            return GatewayProtocol.Response.failure(message: "The kernel did not say where this connection was going: \(reason)")
        }

        guard result.address != 0 || result.port != 0 else {
            return GatewayProtocol.Response.failure(message: "The kernel did not say where this connection was going.")
        }

        var answer = GatewayProtocol.Response.success(version: GatewayHelper.version)
        answer.clientAddress = clientAddress
        answer.originalAddress = GatewayNetwork.text(result.address)
        answer.originalPort = Int(UInt16(bigEndian: result.port))
        return answer
    }
}
