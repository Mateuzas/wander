import CoreLocation
import Observation

/// Current position and permission state. "When in use" only, no background
/// modes (PLAN.md §8). The usage string lives in the target's build settings
/// (INFOPLIST_KEY_NSLocationWhenInUseUsageDescription).
@MainActor
@Observable
final class LocationService: NSObject {
    enum Access: Equatable {
        case notDetermined
        case allowed
        /// Denied by the user, or restricted (parental controls, MDM).
        case denied
    }

    private(set) var access: Access = .notDetermined
    private(set) var location: CLLocation?
    /// Degrees clockwise from north the phone points (true north when known),
    /// or nil without a reliable compass reading (`headingAccuracy < 0`).
    private(set) var heading: CLLocationDirection?

    @ObservationIgnored private let manager = CLLocationManager()
    /// Heading updates are wanted (the map is on screen and the app is active).
    @ObservationIgnored private var wantsHeading = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        // Small turns don't need a redraw.
        manager.headingFilter = 5
        update(for: manager.authorizationStatus)
    }

    /// Shows the system prompt the first time; does nothing once the user has answered.
    func requestAccess() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// While walking, every fix counts (no distance filter) and CoreLocation is
    /// told the user is on foot. Still when-in-use only: no background updates.
    func setWalking(_ walking: Bool) {
        manager.activityType = walking ? .fitness : .other
        manager.distanceFilter = walking ? kCLDistanceFilterNone : 10
    }

    /// Compass on while the map is visible, off in the background. Covered by the
    /// when-in-use permission; nothing happens without it or without a compass.
    func setHeadingActive(_ active: Bool) {
        wantsHeading = active
        updateHeading()
    }

    private func updateHeading() {
        if wantsHeading, access == .allowed, CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        } else {
            manager.stopUpdatingHeading()
            heading = nil
        }
    }

    private func update(for status: CLAuthorizationStatus) {
        defer { updateHeading() }
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            access = .allowed
            manager.startUpdatingLocation()
        case .denied, .restricted:
            access = .denied
            location = nil
            manager.stopUpdatingLocation()
        case .notDetermined:
            access = .notDetermined
        @unknown default:
            access = .denied
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.update(for: status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.location = last }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading: CLLocationDirection?
        if newHeading.headingAccuracy < 0 {
            heading = nil   // invalid: no reliable reading
        } else {
            heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        }
        Task { @MainActor in
            guard self.wantsHeading else { return }
            self.heading = heading
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; denial arrives via the authorization callback.
    }
}
