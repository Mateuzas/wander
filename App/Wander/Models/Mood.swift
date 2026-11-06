import Foundation
import RouteEngine

/// What the walk is for: one single-select row in the plan sheet (FE-18,
/// docs/CONTRACTS.md §2 "Moods"). Each mood maps to existing engine inputs.
/// Food isn't a mood: it has its own "Nearby" flow in the search panel (FE-19).
enum Mood: String, CaseIterable, Identifiable {
    case bestOf
    case photoSpots
    case shops
    case hiddenGems

    /// `@AppStorage` key, so the last mood survives launches.
    static let storageKey = "planMood"

    /// FE-19 removed Food & drink: a stored "food" mood becomes Best of. Call
    /// before `@AppStorage` reads the key.
    static func migrateStored(in defaults: UserDefaults = .standard) {
        if let raw = defaults.string(forKey: storageKey), Mood(rawValue: raw) == nil {
            defaults.set(Mood.bestOf.rawValue, forKey: storageKey)
        }
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .bestOf: "Best of"
        case .photoSpots: "Photo spots"
        case .shops: "Shops"
        case .hiddenGems: "Hidden gems"
        }
    }

    /// SF Symbol, available on iOS 17.
    var symbol: String {
        switch self {
        case .bestOf: "star"
        case .photoSpots: POICategory.photo.glyph
        case .shops: POICategory.shop.glyph
        case .hiddenGems: "sparkles"
        }
    }

    /// Categories planned and drawn as beads while a plan shows.
    var interests: Set<POICategory> {
        switch self {
        case .bestOf, .hiddenGems: Set(POICategory.allCases)
        case .photoSpots: [.photo]
        case .shops: [.shop]
        }
    }

    var preset: WeightPreset {
        switch self {
        case .bestOf, .shops: .balanced
        case .photoSpots: .photoSpots
        case .hiddenGems: .hiddenGems
        }
    }
}
