// Socks4Request: the SOCKS4 and SOCKS4a request, and the reply.
// Compiled as main.swift by run.sh.
import Foundation

var fails = 0
func t(_ name: String, _ ok: Bool) { if !ok { fails += 1; print("FAIL", name) } }

// a request for an address
if let req = Socks4Request.build(destination: "1.2.3.4", port: 8080, username: nil) {
    let b = [UInt8](req)
    t("the version is 4", b[0] == 0x04)
    t("the command is connect", b[1] == 0x01)
    t("the port is big endian", b[2] == 0x1F && b[3] == 0x90)
    t("the address follows", b[4] == 1 && b[5] == 2 && b[6] == 3 && b[7] == 4)
    t("an empty user id is allowed", b.count == 9 && b[8] == 0)
} else {
    t("the request is built", false)
}

// a request with a user id
if let req = Socks4Request.build(destination: "1.2.3.4", port: 443, username: "bob") {
    let b = [UInt8](req)
    t("the user id is in the request", b.count == 12 && b[8] == 98 && b[9] == 111 && b[10] == 98 && b[11] == 0)
} else {
    t("the request with a user id is built", false)
}

// a request for a name is socks4a: the address says a name follows
if let req = Socks4Request.build(destination: "example.com", port: 443, username: nil) {
    let b = [UInt8](req)
    t("socks4a marks the address", b[4] == 0 && b[5] == 0 && b[6] == 0 && b[7] == 1)
    t("the user id ends first", b[8] == 0)
    t("the name follows", b.count == 9 + "example.com".utf8.count + 1)
    t("the name is terminated", b.last == 0)
    t("the name is the name", String(bytes: b[9..<b.count - 1], encoding: .utf8) == "example.com")
} else {
    t("the socks4a request is built", false)
}

// a socks4a request with a user id
if let req = Socks4Request.build(destination: "example.com", port: 443, username: "bob") {
    let b = [UInt8](req)
    t("the user id comes before the name", b[8] == 98 && b[9] == 111 && b[10] == 98 && b[11] == 0)
    t("the name comes after the user id", String(bytes: b[12..<b.count - 1], encoding: .utf8) == "example.com")
} else {
    t("the socks4a request with a user id is built", false)
}

// socks4 has no ipv6
t("an ipv6 address cannot be asked for", Socks4Request.build(destination: "2606::1", port: 443, username: nil) == nil)
// an empty name has no meaning
t("an empty name cannot be asked for", Socks4Request.build(destination: "", port: 443, username: nil) == nil)
// the name has to fit in one byte of length
t("a long name cannot be asked for", Socks4Request.build(destination: String(repeating: "a", count: 256), port: 443, username: nil) == nil)
// the user id has to fit as well
t("a long user id cannot be asked for", Socks4Request.build(destination: "1.2.3.4", port: 443, username: String(repeating: "u", count: 256)) == nil)

// the reply
let grantedReply = Data([0x00, 90, 0x1F, 0x90, 0, 0, 0, 0])
let rejectedReply = Data([0x00, 91, 0, 0, 0, 0, 0, 0])
t("a granted reply is granted", Socks4Request.isGranted(grantedReply))
t("a rejected reply is not granted", !Socks4Request.isGranted(rejectedReply))
t("the code is read", Socks4Request.replyCode(grantedReply) == 90)
t("a short reply has no code", Socks4Request.replyCode(Data([0x00])) == nil)
t("a granted reply says so", Socks4Request.reason(grantedReply) == "granted")
t("a rejected reply says so", Socks4Request.reason(rejectedReply) == "rejected")
t("an unknown code is named", Socks4Request.reason(Data([0, 99, 0, 0, 0, 0, 0, 0])).contains("99"))

print(fails == 0 ? "socks4 tests: ALL PASS" : "socks4 tests: \(fails) FAILED")
exit(fails == 0 ? 0 : 1)
