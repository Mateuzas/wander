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

    /// Spoken by VoiceOver before the place name ("Photo spot, Mural on Stiklių").
    var spokenName: String {
        switch self {
        case .photo: "Photo spot"
        case .shop: "Shop"
        case .food: "Food"
        }
    }
}
