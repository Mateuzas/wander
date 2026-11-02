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

    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        update(for: manager.authorizationStatus)
    }

    /// Shows the system prompt the first time; does nothing once the user has answered.
    func requestAccess() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    private func update(for status: CLAuthorizationStatus) {
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

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; denial arrives via the authorization callback.
    }
}
