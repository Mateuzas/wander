import RouteEngine

/// What the user wants more of; maps to RouteEngine signal weights.
///
/// RouteEngine has `SignalWeights` but no named presets yet, so the presets live
/// here. Move them into the engine if it grows its own.
enum RouteProfile: String, CaseIterable, Identifiable, Hashable {
    case balanced
    case photoSpots
    case famousSights
    case hiddenGems

    var id: Self { self }

    var title: String {
        switch self {
        case .balanced: "Balanced"
        case .photoSpots: "Photo spots"
        case .famousSights: "Famous sights"
        case .hiddenGems: "Hidden gems"
        }
    }

    /// Nil uses each POI's curated `score`.
    var weights: SignalWeights? {
        switch self {
        case .balanced: nil
        case .photoSpots: SignalWeights(photos: 1, fame: 0.3, quality: 0.1)
        case .famousSights: SignalWeights(photos: 0.3, fame: 1, quality: 0.1)
        case .hiddenGems: SignalWeights(photos: 0.3, fame: -0.5, quality: 0.4, independent: 1)
        }
    }
}

extension Mode {
    var title: String {
        switch self {
        case .direct: "Direct"
        case .relaxed: "Relaxed"
        case .explorer: "Explorer"
        }
    }

    var budgetLabel: String { "+\(extraMinutes) min" }
}

extension POICategory {
    /// Interest chip label.
    var chipTitle: String {
        switch self {
        case .photo: "Sights"
        case .shop: "Shops"
        case .food: "Food"
        }
    }
}
