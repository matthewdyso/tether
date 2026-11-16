import XCTest
@testable import TetherCore

final class SettingsBackupTests: XCTestCase {
    private let domain = "SettingsBackupTests"
    private var defaults: UserDefaults!
    private var store: InMemorySecrets!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: domain)
        defaults.removePersistentDomain(forName: domain)
        store = InMemorySecrets()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
        super.tearDown()
    }

    private func backup() -> SettingsBackup { SettingsBackup(defaults: defaults, domain: domain, store: store) }

    /// An install that drops the app's data drops the settings too. The next launch puts them back.
    func testSettingsComeBackAfterTheAppsDataIsReset() {
        let first = backup()
        XCTAssertFalse(first.restoreIfLost(), "a first launch has nothing to put back")
        defaults.set("quad9", forKey: "dns")
        defaults.set(true, forKey: "sharing.onlyThroughVPN")
        first.save()

        defaults.removePersistentDomain(forName: domain) // the reinstall
        XCTAssertNil(defaults.string(forKey: "dns"))
        XCTAssertTrue(backup().restoreIfLost())
        XCTAssertEqual(defaults.string(forKey: "dns"), "quad9")
        XCTAssertTrue(defaults.bool(forKey: "sharing.onlyThroughVPN"))
    }

    /// A launch that still has them doesn't overwrite them with an older copy.
    func testSettingsThatAreThereStay() {
        let first = backup()
        first.restoreIfLost()
        defaults.set("quad9", forKey: "dns")
        first.save()
        defaults.set("adguard", forKey: "dns")
        XCTAssertFalse(backup().restoreIfLost())
        XCTAssertEqual(defaults.string(forKey: "dns"), "adguard")
    }

    /// An unchanged round writes nothing to the Keychain.
    func testAnUnchangedSaveWritesNothing() {
        let b = backup()
        b.restoreIfLost()
        defaults.set("quad9", forKey: "dns")
        b.save()
        store.data = Data("sentinel".utf8)
        b.save()
        XCTAssertEqual(store.data, Data("sentinel".utf8))
    }

    /// Locked after a restart, the copy can't be read: the empty settings mustn't replace it, and it's
    /// put back once it can be read.
    func testALockedKeychainLeavesTheCopyAlone() throws {
        let first = backup()
        first.restoreIfLost()
        defaults.set("quad9", forKey: "dns")
        first.save()
        let copy = store.data

        defaults.removePersistentDomain(forName: domain)
        let locked = FlakySecrets()
        locked.data = copy
        locked.failing = true
        let b = SettingsBackup(defaults: defaults, domain: domain, store: locked)
        XCTAssertFalse(b.restoreIfLost())
        b.save()
        XCTAssertEqual(locked.data, copy, "not overwritten while locked")
        locked.failing = false
        b.save()
        XCTAssertEqual(defaults.string(forKey: "dns"), "quad9", "put back once it can be read")
    }
}
