import RouteEngine

/// What the walk is for: one single-select row in the plan sheet (FE-18,
/// docs/CONTRACTS.md §2 "Moods"). Each mood maps to existing engine inputs.
enum Mood: String, CaseIterable, Identifiable {
    case bestOf
    case photoSpots
    case food
    case shops
    case hiddenGems

    /// `@AppStorage` key, so the last mood survives launches.
    static let storageKey = "planMood"

    var id: Self { self }

    var title: String {
        switch self {
        case .bestOf: "Best of"
        case .photoSpots: "Photo spots"
        case .food: "Food & drink"
        case .shops: "Shops"
        case .hiddenGems: "Hidden gems"
        }
    }

    /// SF Symbol, available on iOS 17.
    var symbol: String {
        switch self {
        case .bestOf: "star"
        case .photoSpots: POICategory.photo.glyph
        case .food: POICategory.food.glyph
        case .shops: POICategory.shop.glyph
        case .hiddenGems: "sparkles"
        }
    }

    /// Categories planned and drawn as beads while a plan shows.
    var interests: Set<POICategory> {
        switch self {
        case .bestOf, .hiddenGems: Set(POICategory.allCases)
        case .photoSpots: [.photo]
        case .food: [.food]
        case .shops: [.shop]
        }
    }

    var preset: WeightPreset {
        switch self {
        case .bestOf, .food, .shops: .balanced
        case .photoSpots: .photoSpots
        case .hiddenGems: .hiddenGems
        }
    }
}
