import dnssd
import Foundation

/// Answers <name>.local on the hotspot with the addresses Tether listens on, so a config can name
/// the iPhone instead of an IPv6 address that changes with the cellular session (#65). The name is
/// tether- and the first 4 hex digits of the server's public key, so it stays the same as long as
/// the keys do, or one the person picks in Settings. The picked one is kept in the Keychain with the
/// keys: a reinstall that drops the app's data keeps both. The app can't use the iPhone's own name:
/// iOS gives apps only "iPhone" without an entitlement a sideloaded app can't get.
@MainActor
final class HostName {
    /// The Keychain service of the picked name.
    nonisolated static let service = "tether.hostname"
    private let store: SecretStore
    private let log: (String) -> Void
    /// The one picked in Settings, nil for the one from the key.
    private(set) var custom: String?
    private var connection: DNSServiceRef?
    /// What each record answers, for the reply's log line.
    private var records: [DNSRecordRef: String] = [:]
    /// The name and addresses registered now.
    private var published: (name: String, hosts: [String])?

    /// `store` holds only the picked name, apart from the setup's item.
    init(store: SecretStore, log: @escaping (String) -> Void) {
        self.store = store
        self.log = log
        custom = (try? store.load()).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Self.valid)
    }

    static func name(for publicKey: Data) -> String {
        "tether-" + publicKey.prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    /// The name answered for this server key: the picked one, or the one from the key.
    func name(for publicKey: Data?) -> String? {
        custom ?? publicKey.map(Self.name(for:))
    }

    /// A name as typed, made into a DNS label: lower case, without ".local", only letters, digits
    /// and hyphens, not starting or ending with one, up to 63. Nil when it can't be one.
    static func valid(_ typed: String) -> String? {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".local") { name.removeLast(".local".count) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard (1...63).contains(name.count), name.allSatisfy(allowed.contains),
              name.first != "-", name.last != "-" else { return nil }
        return name
    }

    /// Picks `typed`, or goes back to the name from the key for an empty one. False when it isn't a
    /// name or couldn't be saved, and the name stays as it was.
    func pick(_ typed: String) -> Bool {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? nil : Self.valid(trimmed)
        guard trimmed.isEmpty || name != nil else { return false }
        do {
            try store.save(Data((name ?? "").utf8))
        } catch {
            log("Hotspot name: can't be saved: \(error)")
            return false
        }
        custom = name
        return true
    }

    /// Answers the name with `hosts` from now on, or with nothing for none. The same name and
    /// addresses again change nothing.
    func publish(_ hosts: [String], publicKey: Data?) {
        let name = hosts.isEmpty ? nil : name(for: publicKey)
        guard name != published?.name || hosts != published?.hosts else { return }
        stop()
        guard let name else { return }
        published = (name, hosts)
        var ref: DNSServiceRef?
        let error = DNSServiceCreateConnection(&ref)
        guard error == kDNSServiceErr_NoError, let ref else {
            log("mDNS: no connection to mDNSResponder: \(error)")
            return
        }
        DNSServiceSetDispatchQueue(ref, .main)
        connection = ref
        let lines = Interfaces.addresses()
        for host in hosts { register("\(name).local", host, interfaces: lines, on: ref) }
    }

    func stop() {
        if let connection { DNSServiceRefDeallocate(connection) } // takes its records with it
        connection = nil
        records = [:]
        published = nil
    }

    private func register(_ full: String, _ host: String, interfaces: [String], on ref: DNSServiceRef) {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ipv6 = host.contains(":")
        guard inet_pton(ipv6 ? AF_INET6 : AF_INET, host, &bytes) == 1 else {
            log("mDNS: \(host) isn't an address")
            return
        }
        // Only on the hotspot's interface, so the name means nothing on Wi-Fi or cellular.
        let interface = interfaces.first { $0.hasSuffix(": \(host)") }.map { String($0.prefix { $0 != ":" }) }
        let index = interface.map { if_nametoindex($0) } ?? 0
        guard index != 0 else {
            log("mDNS: no interface has \(host)")
            return
        }
        var record: DNSRecordRef?
        let error = DNSServiceRegisterRecord(ref, &record, DNSServiceFlags(kDNSServiceFlagsUnique), index, full,
                                             UInt16(ipv6 ? kDNSServiceType_AAAA : kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                             UInt16(ipv6 ? 16 : 4), bytes, 120, { _, record, _, error, context in
            guard let context, let record else { return }
            let me = Unmanaged<HostName>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.registered(record, error) }
        }, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let record else {
            log("mDNS: \(full) → \(host) on \(interface ?? "?") refused: \(error)")
            return
        }
        records[record] = "\(full) → \(host) on \(interface ?? "?")"
    }

    /// mDNSResponder's answer once it has probed the name on the network.
    private func registered(_ record: DNSRecordRef, _ error: DNSServiceErrorType) {
        let what = records[record] ?? "a record"
        if error == kDNSServiceErr_NoError {
            log("mDNS: \(what) published")
        } else if error == kDNSServiceErr_NameConflict {
            log("mDNS: \(what) taken by another device on the network")
        } else {
            log("mDNS: \(what) failed: \(error)")
        }
    }
}
