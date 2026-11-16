import dnssd
import Foundation

/// A spike for #65: answers the name tether-xxxx.local on the hotspot with the addresses Tether
/// listens on, so a config could name the iPhone instead of an IPv6 address that changes with the
/// cellular session. It only publishes the name and logs what iOS says. No config uses it yet.
@MainActor
final class HostName {
    static let key = "hostName.spike"
    /// "tether-" and 4 hex digits, kept so the name stays the same across launches.
    let name: String
    private let log: (String) -> Void
    private var connection: DNSServiceRef?
    /// What each record answers, for the reply's log line.
    private var records: [DNSRecordRef: String] = [:]
    private var published: [String] = []

    init(defaults: UserDefaults = .standard, log: @escaping (String) -> Void) {
        if let kept = defaults.string(forKey: Self.key) {
            name = kept
        } else {
            name = String(format: "tether-%04x", UInt16.random(in: .min ... .max))
            defaults.set(name, forKey: Self.key)
        }
        self.log = log
    }

    /// Answers the name with `hosts` from now on, or with nothing for none. The same list again
    /// changes nothing.
    func publish(_ hosts: [String]) {
        guard hosts != published else { return }
        stop()
        published = hosts
        guard !hosts.isEmpty else { return }
        var ref: DNSServiceRef?
        let error = DNSServiceCreateConnection(&ref)
        guard error == kDNSServiceErr_NoError, let ref else {
            log("mDNS: no connection to mDNSResponder: \(error)")
            return
        }
        DNSServiceSetDispatchQueue(ref, .main)
        connection = ref
        let lines = Interfaces.addresses()
        for host in hosts { register(host, interfaces: lines, on: ref) }
    }

    func stop() {
        if let connection { DNSServiceRefDeallocate(connection) } // takes its records with it
        connection = nil
        records = [:]
        published = []
    }

    private func register(_ host: String, interfaces: [String], on ref: DNSServiceRef) {
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
        let full = "\(name).local"
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
