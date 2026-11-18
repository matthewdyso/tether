import AppIntents

// Actions for the Shortcuts app, Siri, Spotlight and the Action button. iOS suspends Tether once
// nothing has been on the hotspot for 10 minutes (KeepAlivePolicy), and Shortcuts has no trigger
// for Personal Hotspot turning on. So a shortcut turns the hotspot on with Shortcuts' own Set Personal Hotspot
// action, then runs Start Tether, which wakes Tether in the background without opening it.

struct StartTetherIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Tether"
    static let description = IntentDescription(
        "Wakes Tether in the background, the same as opening it. It shares as soon as a device joins Personal Hotspot in the next 10 minutes. Put it after Set Personal Hotspot.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let model = Model.shared
        let keptAlive = model.wake()
        let state = model.shortcutState()
        return .result(value: state.sharing, dialog: "\(ShortcutReply.start(state, keptAlive: keptAlive))")
    }
}

struct TetherStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Tether Sharing?"
    static let description = IntentDescription(
        "True while Tether is sharing Personal Hotspot, for an If in a shortcut. It also says how many devices are connected.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let model = Model.shared
        model.syncWithHotspot() // a cold launch for this action hasn't looked at the hotspot yet
        let state = model.shortcutState()
        return .result(value: state.sharing, dialog: "\(ShortcutReply.status(state))")
    }
}

/// Ready in Shortcuts, Siri and Spotlight as soon as Tether is installed, with nothing to set up.
struct TetherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartTetherIntent(),
                    phrases: ["Start \(.applicationName)", "Share internet with \(.applicationName)"],
                    shortTitle: "Start Tether", systemImageName: "link")
        AppShortcut(intent: TetherStatusIntent(),
                    phrases: ["Is \(.applicationName) sharing", "\(.applicationName) status"],
                    shortTitle: "Is Tether Sharing?", systemImageName: "link.circle")
        AppShortcut(intent: StopTetherIntent(),
                    phrases: ["Stop \(.applicationName)", "Stop sharing with \(.applicationName)"],
                    shortTitle: "Stop Tether", systemImageName: "stop.circle")
        AppShortcut(intent: GetTetherDevicesIntent(),
                    phrases: ["Which devices are on \(.applicationName)", "\(.applicationName) devices"],
                    shortTitle: "Tether Devices", systemImageName: "laptopcomputer.and.iphone")
    }
}

/// Stops sharing until Tether is opened or Start Tether runs, for a shortcut that turns everything off.
struct StopTetherIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Tether"
    static let description = IntentDescription(
        "Stops sharing now, the same as the idle stop. Tether shares again when it's opened or Start Tether runs.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let was = Model.shared.stopNow()
        return .result(dialog: "\(ShortcutReply.stop(wasRunning: was))")
    }
}

/// Where Tether stands, as values a shortcut can test, not only a sentence.
struct GetTetherStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Tether Status"
    static let description = IntentDescription(
        "Whether Tether is sharing, how many devices are connected, whether the internet goes out through a VPN, the hotspot name, and the problem if there is one.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TetherStatusEntity> {
        let model = Model.shared
        model.syncWithHotspot() // a cold launch for this action hasn't looked at the hotspot yet
        return .result(value: TetherStatusEntity(model.shortcutState(), name: model.hotspotName))
    }
}

struct TetherStatusEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tether Status"

    @Property(title: "Sharing") var sharing: Bool
    @Property(title: "Connected Devices") var connectedDevices: Int
    @Property(title: "Through a VPN") var vpn: Bool
    @Property(title: "Hotspot Name") var hotspotName: String
    @Property(title: "Problem") var problem: String

    init() {}

    init(_ state: ShortcutReply.State, name: String?) {
        sharing = state.sharing
        connectedDevices = state.connected
        vpn = state.vpn
        hotspotName = name.map { "\($0).local" } ?? ""
        problem = state.problem ?? ""
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(ShortcutReply.status(state))")
    }

    private var state: ShortcutReply.State {
        ShortcutReply.State(running: sharing || !problem.isEmpty, connected: connectedDevices, problem: problem.isEmpty ? nil : problem)
    }
}

/// A device in Tether's list, for Get Tether Devices and the Pause and Resume actions.
struct TetherDeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tether Device"
    static let defaultQuery = TetherDeviceQuery()

    var id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Connected") var connected: Bool
    @Property(title: "Paused") var paused: Bool
    @Property(title: "Last Connected") var lastConnected: Date?
    @Property(title: "Data This Month") var dataThisMonth: Measurement<UnitInformationStorage>

    init(_ device: ShortcutReply.Device) {
        id = device.id
        name = device.name
        connected = device.connected
        paused = device.paused
        lastConnected = device.lastConnected
        dataThisMonth = Measurement(value: Double(device.bytesThisMonth), unit: .bytes)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(paused ? "Paused" : connected ? "Connected" : "Not connected")")
    }
}

struct TetherDeviceQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [TetherDeviceEntity] {
        Model.shared.shortcutDevices().filter { identifiers.contains($0.id) }.map(TetherDeviceEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [TetherDeviceEntity] {
        Model.shared.shortcutDevices().map(TetherDeviceEntity.init)
    }
}

struct GetTetherDevicesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Tether Devices"
    static let description = IntentDescription(
        "Every device in Tether's list, with whether it's connected or paused, when it last connected, and its data this month.")

    @Parameter(title: "Only Connected", default: false) var onlyConnected: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Get Tether devices") { \.$onlyConnected }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TetherDeviceEntity]> {
        let model = Model.shared
        model.syncWithHotspot()
        let devices = model.shortcutDevices().filter { !onlyConnected || $0.connected }
        return .result(value: devices.map(TetherDeviceEntity.init))
    }
}

struct PauseTetherDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Tether Device"
    static let description = IntentDescription("Stops a device from connecting until it's resumed, as Pause on its screen does.")

    @Parameter(title: "Device") var device: TetherDeviceEntity

    static var parameterSummary: some ParameterSummary { Summary("Pause \(\.$device)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try TetherDeviceError.change(device.id, toPaused: true) { Model.shared.pauseWireGuardDevice($0) }
        return .result(dialog: "\(device.name) is paused.")
    }
}

struct ResumeTetherDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Tether Device"
    static let description = IntentDescription("Lets a paused device connect again, as Resume on its screen does.")

    @Parameter(title: "Device") var device: TetherDeviceEntity

    static var parameterSummary: some ParameterSummary { Summary("Resume \(\.$device)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try TetherDeviceError.change(device.id, toPaused: false) { Model.shared.resumeWireGuardDevice($0) }
        return .result(dialog: "\(device.name) can connect again.")
    }
}

/// Why Pause or Resume Tether Device didn't, so Shortcuts says so rather than that it did. Shortcuts
/// shows the message of an error that conforms to CustomLocalizedStringResourceConvertible only.
enum TetherDeviceError: Error, CustomLocalizedStringResourceConvertible {
    /// Removed since the shortcut picked it.
    case gone
    /// The change couldn't be saved, see `HotspotSession.pause`.
    case notSaved

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .gone: "That device isn't in Tether anymore."
        case .notSaved: "Tether couldn't save the change. Try again on the device's screen in Tether."
        }
    }

    /// Runs `change` on the device and checks it took, by reading the list again.
    @MainActor
    static func change(_ id: UUID, toPaused paused: Bool, _ change: (UUID) -> Void) throws {
        let model = Model.shared
        guard model.shortcutDevices().contains(where: { $0.id == id }) else { throw gone }
        change(id)
        guard model.shortcutDevices().first(where: { $0.id == id })?.paused == paused else { throw notSaved }
    }
}
