import Foundation

// The addresses that belong to this machine or to the network it is in.
//
// The global mode hands the traffic that no rule names to the proxy. The
// traffic of the local network is not part of that: a proxy on the internet
// cannot answer for a server on this network, and a program that asks the
// nameserver of the local router would wait for an answer that never comes.

func expect(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        exit(1)
    }
}

// the addresses of the local network
for host in ["192.168.254.254", "192.168.0.1", "10.0.0.1", "10.255.255.255",
             "172.16.0.1", "172.31.255.255", "127.0.0.1", "169.254.1.1",
             "100.64.0.1", "0.0.0.0"] {
    expect(LocalAddress.isLocal(host), "\(host) is on this network")
}

// the addresses that are not
for host in ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1", "192.169.0.1",
             "11.0.0.1", "100.63.0.1", "100.128.0.1", "223.5.5.5"] {
    expect(!LocalAddress.isLocal(host), "\(host) is not on this network")
}

// the names of this machine and of the local network
expect(LocalAddress.isLocal("localhost"), "localhost is here")
expect(LocalAddress.isLocal("LOCALHOST"), "the name does not matter")
expect(LocalAddress.isLocal("printer.local"), "a name of the local network is here")
expect(LocalAddress.isLocal("my-mac.localhost"), "a name of this machine is here")
expect(!LocalAddress.isLocal("example.com"), "a name on the internet is not here")
expect(!LocalAddress.isLocal(""), "nothing is not here")

// the ipv6 addresses
expect(LocalAddress.isLocal("::1"), "the loopback of ipv6 is here")
expect(LocalAddress.isLocal("::"), "the unspecific address is here")
expect(LocalAddress.isLocal("fd00::1"), "fd00::1 is a local address")
expect(LocalAddress.isLocal("fc00::1"), "fc00::1 is a local address")
expect(LocalAddress.isLocal("fe80::1"), "fe80::1 is a local address")
expect(LocalAddress.isLocal("::ffff:192.168.0.1"), "the ipv4 in an ipv6 is read")
expect(LocalAddress.isLocal("::ffff:8.8.8.8") == false, "8.8.8.8 in an ipv6 is not local")
expect(!LocalAddress.isLocal("2001:db8::1"), "a global ipv6 address is not local")

// the text that is not an address at all
expect(!LocalAddress.isLocal("not an address"), "a sentence is not an address")
expect(!LocalAddress.isLocal("1.2.3"), "three numbers are not an address")
expect(!LocalAddress.isLocal("1.2.3.4.5"), "five numbers are not an address")
expect(!LocalAddress.isLocal("256.1.1.1"), "256 is not a part of an address")

// the parts of an address
expect(LocalAddress.ipv4Bytes("192.168.0.1") == [192, 168, 0, 1], "an ipv4 is four numbers")
expect(LocalAddress.ipv4Bytes("192.168.0") == nil, "three numbers are not an address")
expect(LocalAddress.ipv4Bytes("192.168.0.256") == nil, "256 is not a part of an address")
expect(LocalAddress.ipv4Bytes("192.168.0.x") == nil, "a letter is not a part of an address")

expect(LocalAddress.ipv6Bytes("::1")?.last == 1, "::1 ends in a one")
expect(LocalAddress.ipv6Bytes("fe80::1")?.prefix(2) == [0xfe, 0x80], "fe80::1 starts with fe80")
expect(LocalAddress.ipv6Bytes("2001:db8::1")?.prefix(2) == [0x20, 0x01], "2001:db8::1 starts with 2001")
expect(LocalAddress.ipv6Bytes("::ffff:192.168.0.1")?.suffix(4) == [192, 168, 0, 1],
       "the ipv4 at the end is read")
expect(LocalAddress.ipv6Bytes("::ffff:192.168.0.1")?.prefix(10) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
       "the ipv4 at the end has its own place")
expect(LocalAddress.ipv6Bytes("12345::") == nil, "a group of five digits is not an address")
expect(LocalAddress.ipv6Bytes("1::2::3") == nil, "two :: are not an address")

print("local address tests: ALL PASS")
