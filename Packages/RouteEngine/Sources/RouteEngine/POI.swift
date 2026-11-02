import Foundation

/// POI category, matching `category` in pois.json (PLAN.md section 5.5).
public enum Category: String, Codable, CaseIterable, Hashable, Sendable {
    case photo
    case shop
    case food
}

/// How a POI is experienced, matching `kind` in pois.json.
public enum Kind: String, Codable, Hashable, Sendable {
    /// Visible from the street, costs no dwell time (landmarks, murals, viewpoints).
    case passby
    /// Shops and food; optional to enter.
    case stop
}

/// One point of interest, decoded from pois.json (PLAN.md section 5.5).
public struct POI: Codable, Hashable, Identifiable, Sendable {
    /// Stable id, e.g. "osm:node:123".
    public var id: String
    public var name: String
    public var lat: Double
    public var lon: Double
    public var category: Category
    /// 0–100.
    public var score: Int
    public var kind: Kind
    /// Short human-readable reason. May be empty.
    public var reason: String

    public init(id: String, name: String, lat: Double, lon: Double,
                category: Category, score: Int, kind: Kind, reason: String = "") {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.category = category
        self.score = score
        self.kind = kind
        self.reason = reason
    }

    public var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }

    private enum CodingKeys: String, CodingKey {
        case id, name, lat, lon, category, score, kind, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        category = try c.decode(Category.self, forKey: .category)
        score = try c.decode(Int.self, forKey: .score)
        kind = try c.decode(Kind.self, forKey: .kind)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

/// The whole pois.json file.
public struct POIFile: Codable, Sendable {
    public var city: String
    /// Generation date as written by the pipeline, e.g. "2026-10-20".
    public var generated: String
    public var pois: [POI]

    public init(city: String, generated: String, pois: [POI]) {
        self.city = city
        self.generated = generated
        self.pois = pois
    }
}
