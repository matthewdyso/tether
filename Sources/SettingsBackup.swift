import Foundation

/// A copy of Tether's settings in the Keychain, next to the keys, put back on a launch that finds
/// them gone. Installing a build through SideStore can drop the app's data, and with it the DNS
/// choice, the idle stop, the notification switches, the data each device used and the IPv6
/// address its configs point at, while the Keychain keeps the devices. Foundation only, so
/// `swift test` covers it.
final class SettingsBackup {
    /// The Keychain service of the copy, apart from the setup's.
    static let service = "tether.settings"
    /// Set in the settings once they're saved or put back: a launch without it has lost them.
    static let marker = "settingsBackup.present"

    private let defaults: UserDefaults
    private let domain: String
    private let store: SecretStore
    private let log: (String) -> Void
    /// The last copy saved, so an unchanged round writes nothing.
    private var saved: Data?

    /// `domain` is the settings' own, the app's bundle identifier for `.standard`.
    init(defaults: UserDefaults, domain: String, store: SecretStore, log: @escaping (String) -> Void = { _ in }) {
        self.defaults = defaults
        self.domain = domain
        self.store = store
        self.log = log
    }

    /// Puts the copy back when the settings were lost since it was made. Call it at launch, before
    /// anything reads them. Says whether it did.
    @discardableResult
    func restoreIfLost() -> Bool {
        guard !defaults.bool(forKey: Self.marker) else { return false }
        // Locked since a restart: not known yet, so neither put back nor marked, and `save` waits.
        let loaded: Data?
        do { loaded = try store.load() } catch { return false }
        guard let data = loaded, !data.isEmpty,
              let copy = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            defaults.set(true, forKey: Self.marker) // nothing to put back: a first launch
            return false
        }
        for (key, value) in copy { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: Self.marker)
        saved = data
        log("settings put back from the Keychain: the app's data was reset, by an install say")
        return true
    }

    /// Saves the settings as they are now, when they changed since the last save.
    /// Waits for `restoreIfLost` to have decided, so settings a reset dropped never replace the copy.
    func save() {
        if !defaults.bool(forKey: Self.marker) {
            restoreIfLost()
            guard defaults.bool(forKey: Self.marker) else { return }
        }
        var settings = defaults.persistentDomain(forName: domain) ?? [:]
        settings[Self.marker] = nil
        guard let data = try? PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0),
              data != saved else { return }
        do {
            try store.save(data)
            saved = data
        } catch {
            log("settings couldn't be copied to the Keychain: \(error)")
        }
    }
}
