import Foundation

/// A candidate guest address and where it came from.
struct AddressCandidate: Sendable, Equatable {
    let address: String
    let strategy: String
}

/// Finds the guest's IPv4 address.
///
/// Virtualization's NAT attachment does not expose the guest's DHCP lease
/// through any public API, so this has to be inferred from the host. Discovery
/// is therefore a replaceable component with three independent strategies,
/// ordered by how deterministic they are.
struct GuestAddressResolver: Sendable {
    let macAddress: String
    /// A caller-supplied address, which wins outright. This is the most
    /// deterministic debugging path: when discovery misbehaves, being able to
    /// bypass it entirely separates "cannot find the guest" from "the guest is
    /// not answering".
    let override: String?

    /// Returns candidates in confidence order, best first.
    ///
    /// Candidates are *not* verified here. Only an SSH login as the provisioned
    /// user proves an address belongs to this VM, and that check lives in the
    /// readiness gate, which has the credentials.
    func candidates() async -> [AddressCandidate] {
        if let override {
            return [AddressCandidate(address: override, strategy: "override")]
        }

        var found: [AddressCandidate] = []

        for address in await arpAddresses(matching: macAddress) {
            found.append(AddressCandidate(address: address, strategy: "arp"))
        }

        if found.isEmpty {
            // Bonjour names every `_ssh._tcp` advertiser reachable from the
            // host, including the host itself and any other Mac on the LAN with
            // Remote Login enabled. A guest behind Virtualization's NAT can only
            // hold an address inside a bridge subnet, so anything outside one is
            // definitively not this VM and is discarded rather than handed to
            // the SSH gate, which would otherwise spend its whole timeout
            // failing to authenticate against an unrelated machine.
            let subnets = await Self.natBridgeInterfaces()
            for address in await bonjourSSHAddresses() {
                guard let subnet = subnets.first(where: { $0.contains(address: address) }) else {
                    log.debug("Discarding Bonjour candidate \(address): outside every NAT bridge subnet.")
                    continue
                }
                guard address != subnet.address else {
                    log.debug("Discarding Bonjour candidate \(address): it is the host's own bridge address.")
                    continue
                }
                guard !found.contains(where: { $0.address == address }) else { continue }
                found.append(AddressCandidate(address: address, strategy: "bonjour"))
            }
        }

        return found
    }

    // MARK: - Strategy B: ARP by persisted MAC

    /// Reads the host ARP cache and returns addresses whose hardware address
    /// matches the VM's.
    ///
    /// `arp` prints hardware addresses without leading zeroes (`6:a7:...`
    /// rather than `06:a7:...`), so both sides are normalised octet by octet
    /// instead of being compared as strings.
    private func arpAddresses(matching mac: String) async -> [String] {
        guard let wanted = Self.normalizeMAC(mac) else { return [] }

        guard let result = try? await ProcessRunner.run(
            "/usr/sbin/arp", ["-an"],
            timeout: .seconds(15),
            stage: .addressDiscovery
        ), result.succeeded else {
            return []
        }

        var addresses: [String] = []
        for line in result.stdoutText.split(separator: "\n") {
            guard let entry = Self.parseARPLine(String(line)) else { continue }
            guard entry.mac == wanted else { continue }
            addresses.append(entry.address)
        }
        return addresses
    }

    /// Parses one line of `arp -an`.
    ///
    /// The format is:
    ///   `? (192.168.64.5) at d6:a7:58:8e:78:d4 on bridge100 ifscope [ethernet]`
    /// Incomplete entries print `(incomplete)` where the address would be and
    /// are rejected: they mean the host asked and got no answer.
    static func parseARPLine(_ line: String) -> (address: String, mac: String, interface: String)? {
        guard let openParen = line.firstIndex(of: "("),
              let closeParen = line[openParen...].firstIndex(of: ")") else { return nil }
        let address = String(line[line.index(after: openParen)..<closeParen])
        guard isIPv4(address) else { return nil }

        let remainder = line[line.index(after: closeParen)...]
        let fields = remainder.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let atIndex = fields.firstIndex(of: "at"), atIndex + 1 < fields.count else { return nil }

        let rawMAC = fields[atIndex + 1]
        guard rawMAC != "(incomplete)", let mac = normalizeMAC(rawMAC) else { return nil }

        var interface = "unknown"
        if let onIndex = fields.firstIndex(of: "on"), onIndex + 1 < fields.count {
            interface = fields[onIndex + 1]
        }

        return (address, mac, interface)
    }

    /// Canonicalises a MAC to lowercase, colon-separated, zero-padded octets.
    static func normalizeMAC(_ raw: String) -> String? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var octets: [String] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 2, let value = UInt8(part, radix: 16) else { return nil }
            octets.append(String(format: "%02x", value))
        }
        return octets.joined(separator: ":")
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }

    // MARK: - ARP cache priming

    /// Generates bounded traffic on the NAT bridge so the ARP cache populates.
    ///
    /// A guest that has not yet talked to the host leaves no ARP entry, and
    /// nothing else will create one. The sweep is restricted to bridge
    /// interfaces owned by Virtualization's NAT and to /24-or-smaller subnets;
    /// unrelated interfaces are never touched.
    func primeARPCache() async {
        let interfaces = await Self.natBridgeInterfaces()
        guard !interfaces.isEmpty else {
            log.debug("No NAT bridge interface found; skipping ARP priming.")
            return
        }

        for interface in interfaces {
            guard let hosts = interface.hostAddresses(limit: 254) else {
                log.debug("Skipping \(interface.name): subnet is larger than /24.")
                continue
            }
            log.debug("Priming ARP cache for \(hosts.count) addresses on \(interface.name).")
            await withTaskGroup(of: Void.self) { group in
                var running = 0
                for host in hosts {
                    if running >= 32 {
                        await group.next()
                        running -= 1
                    }
                    group.addTask {
                        _ = try? await ProcessRunner.run(
                            "/sbin/ping", ["-c", "1", "-W", "300", "-t", "1", host],
                            timeout: .seconds(3),
                            stage: .addressDiscovery
                        )
                    }
                    running += 1
                }
                await group.waitForAll()
            }
        }
    }

    struct BridgeInterface: Sendable {
        let name: String
        let address: String
        let netmask: UInt32

        /// Whether an address falls inside this interface's subnet.
        func contains(address candidate: String) -> Bool {
            guard let base = GuestAddressResolver.ipv4ToUInt32(address),
                  let value = GuestAddressResolver.ipv4ToUInt32(candidate) else { return false }
            return (base & netmask) == (value & netmask)
        }

        /// Every host address in this interface's subnet, excluding the network
        /// address, the broadcast address, and the host's own address.
        func hostAddresses(limit: Int) -> [String]? {
            let hostBits = 32 - netmask.nonzeroBitCount
            guard hostBits > 0, (1 << hostBits) - 2 <= limit else { return nil }
            guard let base = GuestAddressResolver.ipv4ToUInt32(address) else { return nil }
            let network = base & netmask
            let broadcast = network | ~netmask
            var hosts: [String] = []
            var candidate = network + 1
            while candidate < broadcast {
                if candidate != base {
                    hosts.append(GuestAddressResolver.uint32ToIPv4(candidate))
                }
                candidate += 1
            }
            return hosts
        }
    }

    /// Bridge interfaces created by Virtualization's NAT.
    ///
    /// The bridge name is not contractual, so the interfaces are found by
    /// prefix and the actual name is logged: recording it is one of the open
    /// questions this POC exists to answer.
    static func natBridgeInterfaces() async -> [BridgeInterface] {
        guard let result = try? await ProcessRunner.run(
            "/sbin/ifconfig", ["-a"],
            timeout: .seconds(15),
            stage: .addressDiscovery
        ), result.succeeded else {
            return []
        }
        return parseBridgeInterfaces(result.stdoutText)
    }

    static func parseBridgeInterfaces(_ text: String) -> [BridgeInterface] {
        var interfaces: [BridgeInterface] = []
        var currentName: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") {
                currentName = line.split(separator: ":").first.map(String.init)
                continue
            }
            guard let name = currentName, name.hasPrefix("bridge") else { continue }

            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let inetIndex = fields.firstIndex(of: "inet"), inetIndex + 1 < fields.count else { continue }
            let address = fields[inetIndex + 1]
            guard isIPv4(address) else { continue }

            var netmask: UInt32 = 0xFFFF_FF00
            if let maskIndex = fields.firstIndex(of: "netmask"), maskIndex + 1 < fields.count {
                let raw = fields[maskIndex + 1]
                if raw.hasPrefix("0x"), let value = UInt32(raw.dropFirst(2), radix: 16) {
                    netmask = value
                } else if let value = ipv4ToUInt32(raw) {
                    netmask = value
                }
            }
            interfaces.append(BridgeInterface(name: name, address: address, netmask: netmask))
        }
        return interfaces
    }

    static func ipv4ToUInt32(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(octet)
        }
        return value
    }

    static func uint32ToIPv4(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    // MARK: - Strategy C: Bonjour

    /// Browses `_ssh._tcp` and returns the IPv4 addresses advertised.
    ///
    /// Useful when macOS advertises Remote Login promptly, but a service name
    /// does not identify *this* VM, so anything found here is only a candidate:
    /// confirmation comes from authenticating as the provisioned user.
    private func bonjourSSHAddresses() async -> [String] {
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/dns-sd", ["-t", "4", "-B", "_ssh._tcp", "local"],
            timeout: .seconds(6),
            stage: .addressDiscovery
        ) else {
            return []
        }

        // dns-sd never exits on its own; it is killed by the timeout above, so
        // its exit status is meaningless and only its output matters.
        var instances: [String] = []
        for line in result.stdoutText.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count > 6, fields.contains("_ssh._tcp.") else { continue }
            let instance = fields[6...].joined(separator: " ")
            if !instance.isEmpty && !instances.contains(instance) {
                instances.append(instance)
            }
        }

        var addresses: [String] = []
        for instance in instances {
            guard let resolved = try? await ProcessRunner.run(
                "/usr/bin/dns-sd", ["-t", "4", "-L", instance, "_ssh._tcp", "local"],
                timeout: .seconds(5),
                stage: .addressDiscovery
            ) else { continue }

            for line in resolved.stdoutText.split(separator: "\n") {
                guard let hostRange = line.range(of: "can be reached at ") else { continue }
                let tail = line[hostRange.upperBound...]
                guard let host = tail.split(separator: ":").first.map(String.init) else { continue }
                let resolvedAddresses = await Self.resolveHostname(host)
                for address in resolvedAddresses where !addresses.contains(address) {
                    addresses.append(address)
                }
            }
        }
        return addresses
    }

    private static func resolveHostname(_ hostname: String) async -> [String] {
        if isIPv4(hostname) { return [hostname] }
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/dscacheutil", ["-q", "host", "-a", "name", hostname],
            timeout: .seconds(5),
            stage: .addressDiscovery
        ), result.succeeded else {
            return []
        }
        var addresses: [String] = []
        for line in result.stdoutText.split(separator: "\n") {
            guard line.hasPrefix("ip_address:") else { continue }
            let value = line.dropFirst("ip_address:".count).trimmingCharacters(in: .whitespaces)
            if isIPv4(value) { addresses.append(value) }
        }
        return addresses
    }

    // MARK: - Diagnostics

    /// Captures the host networking state at the moment discovery gave up.
    ///
    /// Without this, an address-discovery timeout leaves nothing to look at:
    /// the guest is about to be shut down and its lease will be gone.
    static func captureDiagnostics(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let commands: [(String, String, [String])] = [
            ("arp.txt", "/usr/sbin/arp", ["-an"]),
            ("ifconfig.txt", "/sbin/ifconfig", ["-a"]),
            ("route.txt", "/sbin/route", ["-n", "get", "default"]),
            ("netstat.txt", "/usr/sbin/netstat", ["-rn"])
        ]

        for (filename, executable, arguments) in commands {
            guard let result = try? await ProcessRunner.run(
                executable, arguments,
                timeout: .seconds(20),
                stage: .addressDiscovery
            ) else { continue }
            let body = result.stdoutText + "\n--- stderr ---\n" + result.stderrText
            try? Data(body.utf8).write(to: directory.appendingPathComponent(filename))
        }

        let logResult = try? await ProcessRunner.run(
            "/usr/bin/log",
            ["show", "--last", "10m", "--style", "compact",
             "--predicate", "subsystem == \"com.apple.Virtualization\""],
            timeout: .seconds(60),
            stage: .addressDiscovery
        )
        if let logResult {
            try? Data(logResult.stdoutText.utf8)
                .write(to: directory.appendingPathComponent("virtualization-log.txt"))
        }

        log.info("Network diagnostics written to \(directory.path).")
    }
}
