import RouteEngine

// TEMPORARY stand-in for RouteEngine's POI type (Milestone 2, Agent A's API PR).
// Delete this file when rebasing onto that PR. POIStore.makePOI and
// POICategory+Style are then the only places to retarget.

enum POICategory: String, Codable, CaseIterable, Hashable, Sendable {
    case photo, shop, food
}

enum POIKind: String, Codable, Hashable, Sendable {
    case passby, stop
}

struct POI: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let coordinate: Coordinate
    let category: POICategory
    let score: Double
    let kind: POIKind
    let reason: String?
}
