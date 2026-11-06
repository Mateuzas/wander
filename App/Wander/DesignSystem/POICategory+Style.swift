import RouteEngine
import SwiftUI

// How each category looks and reads (PLAN.md §10, Bead and Accessibility).
extension POICategory {
    var color: Color {
        switch self {
        case .photo: .sights
        case .shop: .shops
        case .food: .food
        }
    }

    /// White SF Symbol drawn on the bead.
    var glyph: String {
        switch self {
        case .photo: "camera"
        case .shop: "bag"
        case .food: "fork.knife"
        }
    }

    /// Every glyph a bead or kind row can show, checked in debug builds (a missing SF Symbol renders blank).
    static let allGlyphs: [String] = POICategory.allCases.map(\.glyph) + POI.foodGlyphs.map(\.glyph) + [POI.foodFallbackGlyph]
        + DeckKind.allCases.map(\.glyph) + ["heart.fill", "arrow.uturn.backward"]

    /// Spoken by VoiceOver before the place name ("Photo spot, Mural on Stiklių").
    var spokenName: String {
        switch self {
        case .photo: "Photo spot"
        case .shop: "Shop"
        case .food: "Food"
        }
    }
}

// Colour = category, glyph = kind (PLAN.md §10, FE-11).
extension POI {
    /// Food kinds by OSM `type`, each with an SF Symbol available on iOS 17.
    /// There is no ice cream symbol, so a snowflake stands in for it.
    static let foodGlyphs: [(types: Set<String>, glyph: String)] = [
        (["restaurant"], "fork.knife"),
        // Coffee-like places, bakeries and sweets share the cup (FE-17).
        (["cafe", "coffee", "tea", "bakery", "pastry", "confectionery", "chocolate"], "cup.and.saucer"),
        (["bar", "pub", "biergarten"], "wineglass"),
        (["ice_cream"], "snowflake"),
    ]
    /// Other food (deli, fast food, anything new in the data).
    static let foodFallbackGlyph = "takeoutbag.and.cup.and.straw"

    /// The bead glyph: by kind for food, by category for shops and photo spots.
    var glyph: String {
        guard category == .food else { return category.glyph }
        guard let type else { return Self.foodFallbackGlyph }
        return Self.foodGlyphs.first { $0.types.contains(type) }?.glyph ?? Self.foodFallbackGlyph
    }
}
