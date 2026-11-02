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

    private(set) var city = ""
    private(set) var attribution = ""
    private(set) var pois: [POI] = []
    /// Region covering every POI; the map's fallback when there is no location.
    private(set) var region: MKCoordinateRegion?
    private(set) var loadError: Error?

    init(city: String = POIStore.pilotCity, bundle: Bundle = .main) {
        do {
            guard let url = bundle.url(forResource: "pois-\(city)", withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let file = try JSONDecoder().decode(POIFile.self, from: Data(contentsOf: url))
            self.city = file.city
            self.attribution = file.attribution ?? "© OpenStreetMap contributors"
            self.pois = file.pois.compactMap(Self.makePOI)
            self.region = Self.region(covering: pois)
        } catch {
            loadError = error
        }
    }

    /// The highest-scoring POIs inside `region`, so the map never draws hundreds of beads.
    func top(in region: MKCoordinateRegion, limit: Int) -> [POI] {
        let latSpan = region.span.latitudeDelta / 2, lonSpan = region.span.longitudeDelta / 2
        let c = region.center
        return pois
            .filter { abs($0.coordinate.lat - c.latitude) <= latSpan && abs($0.coordinate.lon - c.longitude) <= lonSpan }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Decoding

    /// The JSON as written by the pipeline. Unknown categories or kinds drop the row
    /// rather than failing the whole file.
    private struct POIFile: Decodable {
        let city: String
        let attribution: String?
        let pois: [Row]

        struct Row: Decodable {
            let id: String
            let name: String
            let lat: Double
            let lon: Double
            let category: String
            let score: Double
            let kind: String
            let reason: String?
        }
    }

    private static func makePOI(_ row: POIFile.Row) -> POI? {
        guard let category = POICategory(rawValue: row.category),
              let kind = POIKind(rawValue: row.kind) else { return nil }
        return POI(
            id: row.id,
            name: row.name,
            coordinate: Coordinate(lat: row.lat, lon: row.lon),
            category: category,
            score: row.score,
            kind: kind,
            reason: row.reason
        )
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
    var clLocation: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}
