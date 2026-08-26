import Foundation
import Testing

@testable import Vivarium

@Suite("Hardware addresses")
struct MACNormalizationTests {
    @Test("an address is canonicalised to lowercase, zero-padded octets")
    func canonicalises() {
        #expect(GuestAddressResolver.normalizeMAC("D6:A7:58:8E:78:D4") == "d6:a7:58:8e:78:d4")
    }

    @Test("arp's unpadded octets compare equal to the persisted address")
    func padsShortOctets() {
        // `arp` prints `6:a7:…` where the bundle records `06:a7:…`; matching on
        // the raw strings is what this normalisation exists to avoid.
        #expect(
            GuestAddressResolver.normalizeMAC("6:a7:58:8e:78:d4")
                == GuestAddressResolver.normalizeMAC("06:A7:58:8E:78:D4")
        )
    }

    @Test("anything that is not six octets is refused", arguments: [
        "d6:a7:58:8e:78",
        "d6:a7:58:8e:78:d4:99",
        "d6:a7:58:8e:78:",
        "d6-a7-58-8e-78-d4",
        "zz:a7:58:8e:78:d4",
        "d6:a7:58:8e:78:d444",
        "",
    ])
    func refusesMalformed(_ raw: String) {
        #expect(GuestAddressResolver.normalizeMAC(raw) == nil)
    }
}

@Suite("IPv4 addresses")
struct IPv4Tests {
    @Test("a dotted quad in range is an address", arguments: [
        "192.168.64.5", "0.0.0.0", "255.255.255.255",
    ])
    func accepts(_ text: String) {
        #expect(GuestAddressResolver.isIPv4(text))
    }

    @Test("anything else is not", arguments: [
        "192.168.64", "192.168.64.5.6", "192.168.64.256", "192.168..5", "", "not-an-address",
    ])
    func rejects(_ text: String) {
        #expect(GuestAddressResolver.isIPv4(text) == false)
    }

    @Test("the integer round trip is the identity")
    func roundTrips() throws {
        let value = try #require(GuestAddressResolver.ipv4ToUInt32("192.168.64.1"))
        #expect(value == 3_232_251_905)
        #expect(GuestAddressResolver.uint32ToIPv4(value) == "192.168.64.1")
    }
}

@Suite("The DHCP lease database")
struct DHCPLeaseParsingTests {
    /// Two leases in the shape `/var/db/dhcpd_leases` records them, the second
    /// with the hardware-type prefix `hw_address` carries.
    private let sample = """
        {
        \tname=guest-one
        \tip_address=192.168.64.5
        \thw_address=1,d6:a7:58:8e:78:d4
        \tidentifier=1,d6:a7:58:8e:78:d4
        \tlease=0x68a1b2c3
        }
        {
        \tname=guest-two
        \tip_address=192.168.64.9
        \thw_address=6:a7:58:8e:78:d4
        \tlease=0x68a1ffff
        }
        """

    @Test("every complete entry is read")
    func readsEntries() {
        let leases = GuestAddressResolver.parseDHCPLeases(sample)
        #expect(leases.map(\.address) == ["192.168.64.5", "192.168.64.9"])
    }

    @Test("the hardware-type prefix is dropped and the address normalised")
    func normalisesHardwareAddress() {
        let leases = GuestAddressResolver.parseDHCPLeases(sample)
        #expect(leases.map(\.mac) == ["d6:a7:58:8e:78:d4", "06:a7:58:8e:78:d4"])
    }

    @Test("the lease time is read as a Unix timestamp")
    func readsExpiry() throws {
        let lease = try #require(GuestAddressResolver.parseDHCPLeases(sample).first)
        #expect(lease.expiry == Date(timeIntervalSince1970: 0x68A1_B2C3))
    }

    @Test("an entry with no address is not a lease")
    func skipsEntryWithoutAddress() {
        let leases = GuestAddressResolver.parseDHCPLeases("""
            {
            \tname=guest
            \thw_address=1,d6:a7:58:8e:78:d4
            }
            """)
        #expect(leases.isEmpty)
    }

    @Test("an entry whose address is not IPv4 is not a lease")
    func skipsNonIPv4Address() {
        let leases = GuestAddressResolver.parseDHCPLeases("""
            {
            \tip_address=fe80::1
            \thw_address=1,d6:a7:58:8e:78:d4
            }
            """)
        #expect(leases.isEmpty)
    }

    @Test("an unterminated entry is not a lease")
    func skipsUnterminatedEntry() {
        // The closing brace is what commits an entry, so a file truncated
        // mid-write contributes nothing rather than a half-read lease.
        let leases = GuestAddressResolver.parseDHCPLeases("""
            {
            \tip_address=192.168.64.5
            \thw_address=1,d6:a7:58:8e:78:d4
            """)
        #expect(leases.isEmpty)
    }
}

@Suite("The ARP cache")
struct ARPParsingTests {
    @Test("a complete entry yields its address, hardware address, and interface")
    func parsesCompleteEntry() throws {
        let entry = try #require(
            GuestAddressResolver.parseARPLine(
                "? (192.168.64.5) at d6:a7:58:8e:78:d4 on bridge100 ifscope [ethernet]"
            )
        )
        #expect(entry.address == "192.168.64.5")
        #expect(entry.mac == "d6:a7:58:8e:78:d4")
        #expect(entry.interface == "bridge100")
    }

    @Test("an unpadded hardware address is normalised as it is read")
    func normalisesHardwareAddress() throws {
        let entry = try #require(
            GuestAddressResolver.parseARPLine("? (192.168.64.5) at 6:a7:58:8e:78:d4 on bridge100")
        )
        #expect(entry.mac == "06:a7:58:8e:78:d4")
    }

    @Test("an incomplete entry is refused")
    func refusesIncomplete() {
        // `(incomplete)` means the host asked and got no answer, so the address
        // names nothing that can be connected to.
        #expect(
            GuestAddressResolver.parseARPLine(
                "? (192.168.64.7) at (incomplete) on bridge100 ifscope [ethernet]"
            ) == nil
        )
    }

    @Test("a line that is not an entry is refused", arguments: [
        "",
        "no parentheses here",
        "? (not-an-address) at d6:a7:58:8e:78:d4 on bridge100",
        "? (192.168.64.5) on bridge100",
    ])
    func refusesNonEntries(_ line: String) {
        #expect(GuestAddressResolver.parseARPLine(line) == nil)
    }

    @Test("an entry naming no interface still yields its address")
    func toleratesMissingInterface() throws {
        let entry = try #require(
            GuestAddressResolver.parseARPLine("? (192.168.64.5) at d6:a7:58:8e:78:d4")
        )
        #expect(entry.interface == "unknown")
    }
}

@Suite("NAT bridge interfaces")
struct BridgeInterfaceTests {
    /// `ifconfig -a` as macOS prints it: interface headers unindented, their
    /// address lines indented with a tab.
    private let sample = """
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 10.0.0.42 netmask 0xffffff00 broadcast 10.0.0.255
        bridge100: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
        bridge101: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tinet 192.168.65.1 netmask 255.255.255.0 broadcast 192.168.65.255
        """

    @Test("only bridge interfaces are returned")
    func selectsBridgesOnly() {
        let interfaces = GuestAddressResolver.parseBridgeInterfaces(sample)
        #expect(interfaces.map(\.name) == ["bridge100", "bridge101"])
    }

    @Test("a tab-indented address line is read, not skipped")
    func readsTabIndentedAddress() {
        // ifconfig indents with a tab: splitting on spaces alone leaves the
        // first field as "\tinet", and no lookup for "inet" matches.
        let interfaces = GuestAddressResolver.parseBridgeInterfaces(sample)
        #expect(interfaces.map(\.address) == ["192.168.64.1", "192.168.65.1"])
    }

    @Test("a netmask is read in either notation")
    func readsBothNetmaskNotations() {
        let interfaces = GuestAddressResolver.parseBridgeInterfaces(sample)
        #expect(interfaces.allSatisfy { $0.netmask == 0xFFFF_FF00 })
    }

    @Test("an interface with no address contributes nothing")
    func skipsAddresslessInterface() {
        let interfaces = GuestAddressResolver.parseBridgeInterfaces("""
            bridge100: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500
            \tether 3a:1c:5e:00:00:64
            """)
        #expect(interfaces.isEmpty)
    }

    @Test("an address inside the subnet is contained, and one outside is not")
    func testsContainment() {
        let bridge = GuestAddressResolver.BridgeInterface(
            name: "bridge100", address: "192.168.64.1", netmask: 0xFFFF_FF00
        )
        #expect(bridge.contains(address: "192.168.64.5"))
        #expect(bridge.contains(address: "192.168.65.5") == false)
        #expect(bridge.contains(address: "not-an-address") == false)
    }

    @Test("the sweep covers every host but the network, broadcast, and the host itself")
    func enumeratesHosts() throws {
        let bridge = GuestAddressResolver.BridgeInterface(
            name: "bridge100", address: "192.168.64.1", netmask: 0xFFFF_FF00
        )
        let hosts = try #require(bridge.hostAddresses(limit: 254))
        #expect(hosts.count == 253)
        #expect(hosts.contains("192.168.64.0") == false)
        #expect(hosts.contains("192.168.64.255") == false)
        #expect(hosts.contains("192.168.64.1") == false)
        #expect(hosts.first == "192.168.64.2")
        #expect(hosts.last == "192.168.64.254")
    }

    @Test("a subnet larger than the limit is refused rather than swept")
    func refusesSubnetOverLimit() {
        // The sweep generates real traffic, so a /16 is declined outright
        // rather than truncated to the first `limit` addresses.
        let wide = GuestAddressResolver.BridgeInterface(
            name: "bridge100", address: "192.168.64.1", netmask: 0xFFFF_0000
        )
        #expect(wide.hostAddresses(limit: 254) == nil)

        let narrow = GuestAddressResolver.BridgeInterface(
            name: "bridge100", address: "192.168.64.1", netmask: 0xFFFF_FF00
        )
        #expect(narrow.hostAddresses(limit: 10) == nil)
    }
}
