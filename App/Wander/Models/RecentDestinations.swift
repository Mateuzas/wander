import Foundation
import MapKit
import Observation

/// A destination the user picked before. Stored on device only.
struct Destination: Codable, Hashable, Identifiable {
    var name: String
    var subtitle: String
    var lat: Double
    var lon: Double

    var id: String { "\(name)|\(lat)|\(lon)" }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    init(name: String, subtitle: String, coordinate: CLLocationCoordinate2D) {
        self.name = name
        self.subtitle = subtitle
        self.lat = coordinate.latitude
        self.lon = coordinate.longitude
    }

    init(_ item: MKMapItem) {
        let placemark = item.placemark
        let name = item.name ?? placemark.title ?? "Dropped pin"
        let subtitle = [placemark.thoroughfare, placemark.locality]
            .compactMap { $0 }
            .filter { $0 != name }
            .joined(separator: ", ")
        self.init(name: name, subtitle: subtitle, coordinate: placemark.coordinate)
    }
}

/// Most recent first, de-duplicated, capped at `limit`.
@MainActor
@Observable
final class RecentDestinations {
    static let limit = 5
    private static let key = "recentDestinations"

    private(set) var items: [Destination]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: Self.key)
        items = data.flatMap { try? JSONDecoder().decode([Destination].self, from: $0) } ?? []
    }

    func add(_ destination: Destination) {
        items.removeAll { $0.name == destination.name && $0.subtitle == destination.subtitle }
        items.insert(destination, at: 0)
        items = Array(items.prefix(Self.limit))
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
