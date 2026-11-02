import Foundation
import MapKit
import Observation
import RouteEngine

/// Loads the bundled `pois-<city>.json` (PLAN.md §5.5) into RouteEngine POIs.
@MainActor
@Observable
final class POIStore {
    /// Pilot city slug; matches the file name produced by Data/score.py.
    nonisolated static let pilotCity = "lodz"
    /// Opening hours are read in the city's time zone, not the phone's.
    nonisolated static let timeZones = ["lodz": "Europe/Warsaw", "vilnius": "Europe/Vilnius"]

    let timeZone: TimeZone

    private(set) var city = ""
    private(set) var attribution = ""
    private(set) var pois: [POI] = []
    /// Region covering every POI; the map's fallback when there is no location.
    private(set) var region: MKCoordinateRegion?
    private(set) var loadError: Error?

    init(city: String = POIStore.pilotCity, bundle: Bundle = .main) {
        timeZone = Self.timeZones[city].flatMap(TimeZone.init(identifier:)) ?? .current
        do {
            guard let url = bundle.url(forResource: "pois-\(city)", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let file = try JSONDecoder().decode(POIFile.self, from: Data(contentsOf: url))
            self.city = file.city
            self.attribution = file.attribution ?? "© OpenStreetMap contributors"
            self.pois = file.pois
            self.region = Self.region(covering: pois)
        } catch {
            loadError = error
        }
    }

    /// The highest-scoring POIs inside `region`, so the map never draws hundreds of beads.
    func top(in region: MKCoordinateRegion, limit: Int) -> [POI] {
        let latSpan = region.span.latitudeDelta / 2, lonSpan = region.span.longitudeDelta / 2
        let c = region.center
        let inView = pois
            .filter { abs($0.coordinate.lat - c.latitude) <= latSpan && abs($0.coordinate.lon - c.longitude) <= lonSpan }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        // Popular places (a couple of dozen per city) always show, even zoomed out;
        // the rest fill the remaining slots by score.
        let popular = inView.filter { $0.popular == true }
        let others = inView.filter { $0.popular != true }.prefix(max(0, limit - popular.count))
        return popular + others
    }

    private static func region(covering pois: [POI]) -> MKCoordinateRegion? {
        guard let first = pois.first else { return nil }
        var minLat = first.coordinate.lat, maxLat = minLat
        var minLon = first.coordinate.lon, maxLon = minLon
        for p in pois {
            minLat = min(minLat, p.coordinate.lat); maxLat = max(maxLat, p.coordinate.lat)
            minLon = min(minLon, p.coordinate.lon); maxLon = max(maxLon, p.coordinate.lon)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.1, longitudeDelta: (maxLon - minLon) * 1.1)
        )
    }
}

extension Coordinate {
    init(_ c: CLLocationCoordinate2D) { self.init(lat: c.latitude, lon: c.longitude) }

    var clLocation: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}
