import CoreLocation
import MapKit

/// Names a dropped pin: a place name or street address for a coordinate.
/// Best effort. Returns nil on any failure (offline, throttled, nothing there),
/// and callers keep showing coordinates.
enum ReverseGeocoder {
    struct Place: Equatable {
        /// A place name or the street address, e.g. "Pilies g. 4".
        var name: String
        /// Short context under the name, e.g. "Vilnius"; nil if nothing useful.
        var detail: String?
    }

    static func place(at coordinate: CLLocationCoordinate2D) async -> Place? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if #available(iOS 26, *) {
            return await mapKitPlace(at: location)
        }
        return await geocoderPlace(at: location)
    }

    /// iOS 26+: MapKit's reverse-geocoding request (CLGeocoder is deprecated there).
    @available(iOS 26, *)
    @MainActor
    private static func mapKitPlace(at location: CLLocation) async -> Place? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        let items = try? await withTaskCancellationHandler(
            operation: { try await request.mapItems },
            onCancel: { request.cancel() })
        guard let item = items?.first else { return nil }
        let short = item.address?.shortAddress
        let city = item.addressRepresentations?.cityWithContext
        guard let name = clean(item.name) ?? clean(short) else { return nil }
        let detail = [clean(short), clean(city)].compactMap { $0 }.first { $0 != name }
        return Place(name: name, detail: detail)
    }

    /// iOS 17–25.
    private static func geocoderPlace(at location: CLLocation) async -> Place? {
        let geocoder = CLGeocoder()
        let placemarks = try? await withTaskCancellationHandler(
            operation: { try await geocoder.reverseGeocodeLocation(location) },
            onCancel: { geocoder.cancelGeocode() })
        guard let placemark = placemarks?.first else { return nil }
        let street = [placemark.thoroughfare, placemark.subThoroughfare].compactMap(clean).joined(separator: " ")
        guard let name = clean(placemark.name) ?? clean(street) else { return nil }
        let detail = [clean(street), clean(placemark.locality)].compactMap { $0 }.first { $0 != name }
        return Place(name: name, detail: detail)
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Single line: MapKit sometimes returns multi-line addresses.
        return text.components(separatedBy: .newlines).first { !$0.isEmpty }
    }
}
