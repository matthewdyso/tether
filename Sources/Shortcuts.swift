import AppIntents

// Actions for the Shortcuts app, Siri, Spotlight and the Action button. iOS suspends Tether once
// nothing has been on the hotspot for 10 minutes (KeepAlivePolicy), and Shortcuts has no trigger
// for Personal Hotspot turning on. So a shortcut turns the hotspot on with Shortcuts' own Set Personal Hotspot
// action, then runs Start Tether, which wakes Tether in the background without opening it.

struct StartTetherIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Tether"
    static var description = IntentDescription(
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
    static var title: LocalizedStringResource = "Is Tether Sharing?"
    static var description = IntentDescription(
        "True while Tether is sharing Personal Hotspot, for an If in a shortcut. It also says how many devices are connected, and whether the proxy is in use.")

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
    static var title: LocalizedStringResource = "Stop Tether"
    static var description = IntentDescription(
        "Stops sharing now, the same as the idle stop. Tether shares again when it's opened or Start Tether runs.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let was = Model.shared.stopNow()
        return .result(dialog: "\(ShortcutReply.stop(wasRunning: was))")
    }
}

/// Where Tether stands, as values a shortcut can test, not only a sentence.
struct GetTetherStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Tether Status"
    static var description = IntentDescription(
        "Whether Tether is sharing, how many devices are connected, the hotspot name, and the problem if there is one.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TetherStatusEntity> {
        let model = Model.shared
        model.syncWithHotspot() // a cold launch for this action hasn't looked at the hotspot yet
        return .result(value: TetherStatusEntity(model.shortcutState(), name: model.hotspotName))
    }
}

struct TetherStatusEntity: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tether Status"

    @Property(title: "Sharing") var sharing: Bool
    @Property(title: "Connected Devices") var connectedDevices: Int
    @Property(title: "Hotspot Name") var hotspotName: String
    @Property(title: "Problem") var problem: String

    init() {}

    init(_ state: ShortcutReply.State, name: String?) {
        sharing = state.sharing
        connectedDevices = state.connected
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
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tether Device"
    static var defaultQuery = TetherDeviceQuery()

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
    static var title: LocalizedStringResource = "Get Tether Devices"
    static var description = IntentDescription(
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
    static var title: LocalizedStringResource = "Pause Tether Device"
    static var description = IntentDescription("Stops a device from connecting until it's resumed, as Pause on its screen does.")

    @Parameter(title: "Device") var device: TetherDeviceEntity

    static var parameterSummary: some ParameterSummary { Summary("Pause \(\.$device)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        Model.shared.pauseWireGuardDevice(device.id)
        return .result(dialog: "\(device.name) is paused.")
    }
}

struct ResumeTetherDeviceIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Tether Device"
    static var description = IntentDescription("Lets a paused device connect again, as Resume on its screen does.")

    @Parameter(title: "Device") var device: TetherDeviceEntity

    static var parameterSummary: some ParameterSummary { Summary("Resume \(\.$device)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        Model.shared.resumeWireGuardDevice(device.id)
        return .result(dialog: "\(device.name) can connect again.")
    }
}
