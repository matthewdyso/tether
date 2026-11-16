import CoreLocation

/// The silent sound, and with Settings > Keep running with location on, location updates as well.
/// iOS doesn't suspend an app that gets them, and a call, Siri or an alarm, which take the sound,
/// leave them running. They start and stop with the sound, by `KeepAlivePolicy`, so the idle stop
/// and the 10 minutes without a hotspot stop them too. Only the rough location from cell towers,
/// which costs little battery, and Tether never reads or keeps it. Fine for a personally installed
/// app; App Store review would reject it, like the sound.
final class KeepAliveWithLocation: NSObject, KeepAliveSound, CLLocationManagerDelegate {
    /// Settings > Keep running with location, off at first.
    static let key = "keepAlive.location"

    private let sound: KeepAliveSound
    private let enabled: () -> Bool
    private let log: (String) -> Void
    private let manager = CLLocationManager()
    /// Location updates run now.
    private(set) var locating = false
    /// Wanted: the sound is on and so is the setting. Location starts once iOS allows it.
    private var wanted = false
    private var refusalLogged = false

    init(sound: KeepAliveSound, enabled: @escaping () -> Bool, log: @escaping (String) -> Void) {
        self.sound = sound
        self.enabled = enabled
        self.log = log
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        // A hotspot on a desk doesn't move, and paused updates would let iOS suspend Tether.
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
    }

    var playing: Bool { sound.playing }
    /// Something keeps Tether running now: the sound, or location during a call.
    var sounding: Bool { sound.sounding || locating }
    func takeInterruption() -> Bool { sound.takeInterruption() }

    /// Each watcher round while the sound should play, so a change of the setting counts by the next.
    func start() {
        sound.start()
        follow(want: enabled())
    }

    func stop() {
        sound.stop()
        follow(want: false)
    }

    private func follow(want: Bool) {
        wanted = want
        guard want != locating else { return }
        guard want else {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            locating = false
            log("location no longer keeps Tether running")
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            // Always: Start Tether wakes it in the background, where While Using can't start updates.
            manager.requestAlwaysAuthorization()
        case .denied, .restricted:
            if !refusalLogged { log("location can't keep Tether running: it isn't allowed in Settings > Privacy > Location Services") }
            refusalLogged = true
        default:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
            locating = true
            refusalLogged = false
            log("location keeps Tether running too, through calls")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if wanted, !locating { follow(want: true) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {} // never read

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
