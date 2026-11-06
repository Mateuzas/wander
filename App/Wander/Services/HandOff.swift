import MapKit
import RouteEngine

/// Hand-off to other map apps (PLAN.md §9).
enum HandOff {
    /// Google Maps directions with waypoints, walking.
    static func googleMapsURL(for plan: WanderPlan) -> URL? {
        var components = URLComponents(string: "https://www.google.com/maps/dir/")
        var items = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "origin", value: text(plan.legs.first?.from ?? plan.baseline.from)),
            URLQueryItem(name: "destination", value: text(end(of: plan))),
            URLQueryItem(name: "travelmode", value: "walking"),
        ]
        // An "anywhere" walk ends at its last stop, which is then the destination, not a waypoint.
        let stops = plan.waypoints.filter { $0.coordinate != end(of: plan) }
        if !stops.isEmpty {
            items.append(URLQueryItem(name: "waypoints", value: stops.map { text($0.coordinate) }.joined(separator: "|")))
        }
        components?.queryItems = items
        return components?.url
    }

    /// Apple Maps takes a destination only, so this opens walking directions
    /// to the first stop (or the destination when there are no stops).
    static func openAppleMaps(for plan: WanderPlan, destinationName: String) {
        let first = plan.waypoints.first
        let coordinate = first?.coordinate ?? end(of: plan)
        let item: MKMapItem
        if #available(iOS 26, *) {
            item = MKMapItem(location: CLLocation(latitude: coordinate.lat, longitude: coordinate.lon), address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate.clLocation))
        }
        item.name = first?.name ?? destinationName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    /// Where the walk ends: the last leg's end (the destination, or the last stop).
    private static func end(of plan: WanderPlan) -> Coordinate {
        plan.legs.last?.to ?? plan.baseline.to
    }

    private static func text(_ c: Coordinate) -> String {
        String(format: "%.6f,%.6f", c.lat, c.lon)
    }
}
