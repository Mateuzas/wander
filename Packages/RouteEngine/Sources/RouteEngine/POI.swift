import Foundation

/// POI category, matching `category` in pois.json (PLAN.md section 5.5).
public enum POICategory: String, Codable, CaseIterable, Hashable, Sendable {
    case photo
    case shop
    case food
}

/// How a POI is experienced, matching `kind` in pois.json.
public enum POIKind: String, Codable, Hashable, Sendable {
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
    public var category: POICategory
    /// 0–100.
    public var score: Int
    public var kind: POIKind
    /// Short human-readable reason. May be empty.
    public var reason: String
    /// Most specific OSM value, e.g. "mural", "museum", "cafe", "books".
    public var type: String?
    /// Raw 0–1 inputs behind `score`, for per-user weighting.
    public var signals: Signals?
    /// Food only, e.g. ["italian"].
    public var cuisine: [String]?
    /// Raw OSM `opening_hours` syntax, e.g. "Mo-Sa 10:00-20:00". Shops and food only.
    public var openingHours: String?
    /// Wikimedia Commons file name of the place's own photo (no "File:" prefix). Sights only.
    public var commonsImage: String?
    /// Original local name when `name` is a translation, e.g. "Archikatedra pw. Świętego Stanisława Kostki".
    public var localName: String?
    /// Commons category with more photos of this place (no "Category:" prefix). Sights only.
    public var commonsCategory: String?
    /// A must-see (high score or well known). Sights only; missing means false.
    public var popular: Bool?

    public init(id: String, name: String, lat: Double, lon: Double,
                category: POICategory, score: Int, kind: POIKind, reason: String = "",
                type: String? = nil, signals: Signals? = nil, cuisine: [String]? = nil,
                openingHours: String? = nil, commonsImage: String? = nil, localName: String? = nil,
                commonsCategory: String? = nil, popular: Bool? = nil) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.category = category
        self.score = score
        self.kind = kind
        self.reason = reason
        self.type = type
        self.signals = signals
        self.cuisine = cuisine
        self.openingHours = openingHours
        self.commonsImage = commonsImage
        self.localName = localName
        self.commonsCategory = commonsCategory
        self.popular = popular
    }

    public var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }

    private enum CodingKeys: String, CodingKey {
        case id, name, lat, lon, category, score, kind, reason
        case type, signals, cuisine, openingHours, commonsImage, localName, commonsCategory, popular
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        category = try c.decode(POICategory.self, forKey: .category)
        score = try c.decode(Int.self, forKey: .score)
        kind = try c.decode(POIKind.self, forKey: .kind)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type)
        signals = try c.decodeIfPresent(Signals.self, forKey: .signals)
        cuisine = try c.decodeIfPresent([String].self, forKey: .cuisine)
        openingHours = try c.decodeIfPresent(String.self, forKey: .openingHours)
        commonsImage = try c.decodeIfPresent(String.self, forKey: .commonsImage)
        localName = try c.decodeIfPresent(String.self, forKey: .localName)
        commonsCategory = try c.decodeIfPresent(String.self, forKey: .commonsCategory)
        popular = try c.decodeIfPresent(Bool.self, forKey: .popular)
    }
}

/// Raw scoring inputs from the data pipeline (PLAN.md section 5.5).
public struct Signals: Codable, Hashable, Sendable {
    /// Commons photo-density percentile in the city, 0–1.
    public var photos: Double
    /// Log-scaled Wikipedia sitelinks, 0–1.
    public var fame: Double
    /// OSM data completeness, 0–1.
    public var quality: Double
    /// No brand tag.
    public var independent: Bool

    public init(photos: Double, fame: Double, quality: Double, independent: Bool) {
        self.photos = photos
        self.fame = fame
        self.quality = quality
        self.independent = independent
    }
}

/// The whole pois.json file.
public struct POIFile: Codable, Sendable {
    public var city: String
    /// Generation date as written by the pipeline, e.g. "2026-10-20".
    public var generated: String
    /// Data attribution text, e.g. "© OpenStreetMap contributors".
    public var attribution: String?
    public var pois: [POI]

    public init(city: String, generated: String, attribution: String? = nil, pois: [POI]) {
        self.city = city
        self.generated = generated
        self.attribution = attribution
        self.pois = pois
    }
}
