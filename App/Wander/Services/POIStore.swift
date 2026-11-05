import Foundation
import MapKit
import Observation
import RouteEngine

/// Loads the bundled `pois-<city>.json` (PLAN.md §5.5) into RouteEngine POIs.
@MainActor
@Observable
final class POIStore {
    /// The app's city slug; matches the file name produced by Data/score.py.
    nonisolated static let pilotCity = "vilnius"
    /// Opening hours are read in the city's time zone, not the phone's.
    nonisolated static let timeZones = ["vilnius": "Europe/Vilnius"]

    let timeZone: TimeZone

    private(set) var city = ""
    private(set) var attribution = ""
    private(set) var pois: [POI] = []
    /// Region covering every POI; the map's fallback when there is no location.
    /// Nil without a data file, and the map then falls back to MapKit's default.
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
            // A missing or unreadable file leaves an empty store: no beads, no crash.
            loadError = error
            #if DEBUG
            print("POIStore: no POIs for \(city): \(error)")
            #endif
        }
    }

    /// The beads to draw for `region` on a map `viewSize` points big (FE-1).
    ///
    /// Popular places (a couple of dozen per city) always show. Ordinary POIs are
    /// thinned with a screen-space grid of `cell`-point squares: at most one per
    /// cell, the best score wins, and a cell holding a popular place stays empty.
    /// The grid is anchored to the map, not the screen, so panning doesn't
    /// reshuffle it. Beads in `shown` (the previous result) are kept first when
    /// more than `limit` cells are filled, so zooming doesn't swap the middle of
    /// the map for its corners.
    func beads(in region: MKCoordinateRegion, viewSize: CGSize, keeping shown: Set<String>,
               cell: CGFloat = 44, limit: Int) -> [POI] {
        let latSpan = region.span.latitudeDelta / 2, lonSpan = region.span.longitudeDelta / 2
        let c = region.center
        let inView = pois
            .filter { abs($0.coordinate.lat - c.latitude) <= latSpan && abs($0.coordinate.lon - c.longitude) <= lonSpan }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        let popular = inView.filter { $0.popular == true }

        // Map points per screen point; Mercator keeps both axes at the same scale.
        let west = MKMapPoint(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude - lonSpan))
        let east = MKMapPoint(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude + lonSpan))
        let width = viewSize.width > 0 ? Double(viewSize.width) : 390
        let cellSize = max(abs(east.x - west.x) / width * Double(cell), 1)

        struct Cell: Hashable { let x: Int; let y: Int }
        func cellOf(_ poi: POI) -> Cell {
            let p = MKMapPoint(poi.coordinate.clLocation)
            return Cell(x: Int((p.x / cellSize).rounded(.down)), y: Int((p.y / cellSize).rounded(.down)))
        }

        var taken = Set(popular.map(cellOf))
        var winners: [POI] = []  // best score first, one per free cell
        for poi in inView where poi.popular != true && taken.insert(cellOf(poi)).inserted {
            winners.append(poi)
        }
        if winners.count > limit {
            // Over the cap: keep what is already on screen, then the best of the rest.
            let kept = winners.filter { shown.contains($0.id) }
            let fresh = winners.filter { !shown.contains($0.id) }
            winners = Array((kept + fresh).prefix(limit))
        }
        return popular + winners
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
