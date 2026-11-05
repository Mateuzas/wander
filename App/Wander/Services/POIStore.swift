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

    /// The beads to draw for `region` on a map `viewSize` points big (FE-1, FE-13).
    ///
    /// Zoom layering (ADR 012 §3): `zoom` picks which tiers are eligible for the
    /// region's latitude span, and the grid cell to thin them on. Only places in
    /// `interests` are drawn, at every zoom. Tier 1 places always show in their
    /// range. Other eligible POIs are thinned with a screen-space grid: at most
    /// one per cell, the best score wins, and a cell holding a tier 1 place stays
    /// empty. The grid is anchored to the map, not the screen, so panning doesn't
    /// reshuffle it. Beads in `shown` (the previous result) are kept first when
    /// more than `zoom.limit` cells are filled, so zooming doesn't swap the
    /// middle of the map for its corners.
    func beads(in region: MKCoordinateRegion, viewSize: CGSize, keeping shown: Set<String>,
               interests: Set<POICategory>, zoom: ZoomTiers = .standard) -> [POI] {
        let latSpan = region.span.latitudeDelta / 2, lonSpan = region.span.longitudeDelta / 2
        let c = region.center
        let maxTier = zoom.maxTier(latitudeSpan: region.span.latitudeDelta)
        let inView = pois
            .filter { $0.mapTier <= maxTier && interests.contains($0.category) }
            .filter { abs($0.coordinate.lat - c.latitude) <= latSpan && abs($0.coordinate.lon - c.longitude) <= lonSpan }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        let top = inView.filter { $0.mapTier == 1 }
        guard let cell = zoom.cell(latitudeSpan: region.span.latitudeDelta) else { return top }

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

        var taken = Set(top.map(cellOf))
        var winners: [POI] = []  // best score first, one per free cell
        for poi in inView where poi.mapTier != 1 && taken.insert(cellOf(poi)).inserted {
            winners.append(poi)
        }
        if winners.count > zoom.limit {
            // Over the cap: keep what is already on screen, then the best of the rest.
            let kept = winners.filter { shown.contains($0.id) }
            let fresh = winners.filter { !shown.contains($0.id) }
            winners = Array((kept + fresh).prefix(zoom.limit))
        }
        return top + winners
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

/// Zoom layering thresholds (ADR 012 §3, "Zoom layering"), in one place for
/// tuning on the phone. The spans are the map's visible latitude span in
/// degrees; 0.01° of latitude is about 1.1 km.
struct ZoomTiers {
    static let standard = ZoomTiers()

    /// Wider than this (≈ 4.5 km tall): tier 1 only, no grid (ADR 012).
    var tier1Above = 0.04
    /// Narrower than this (≈ 1.7 km tall): all tiers (ADR 012).
    var allTiersBelow = 0.015
    /// Grid cell in screen points between the two spans, for tiers 1 and 2 (ADR 012).
    var midCell: CGFloat = 64
    /// Grid cell in screen points close up, for all tiers (ADR 012, FE-1).
    var closeCell: CGFloat = 44
    /// Most non-tier-1 beads drawn at once, for performance (ADR 012, FE-1).
    var limit = 60

    /// The highest tier drawn at this latitude span.
    func maxTier(latitudeSpan: Double) -> Int {
        latitudeSpan > tier1Above ? 1 : latitudeSpan >= allTiersBelow ? 2 : 3
    }

    /// The grid cell for this span; nil when only tier 1 shows, which is never thinned.
    func cell(latitudeSpan: Double) -> CGFloat? {
        switch maxTier(latitudeSpan: latitudeSpan) {
        case 1: nil
        case 2: midCell
        default: closeCell
        }
    }
}

extension POI {
    /// The map tier (ADR 012): 1 must-see, 2 notable, 3 the rest. Files from
    /// before tiers have only `popular`, which maps to tier 1, the rest to 3.
    var mapTier: Int { popular == true ? 1 : 3 }
}

extension Coordinate {
    init(_ c: CLLocationCoordinate2D) { self.init(lat: c.latitude, lon: c.longitude) }

    var clLocation: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}
