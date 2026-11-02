import RouteEngine

// User-facing words for RouteEngine types.

/// Route-style picker labels for the engine's presets.
extension WeightPreset: Identifiable {
    public var id: Self { self }

    var title: String {
        switch self {
        case .balanced: "Balanced"
        case .photoSpots: "Photo spots"
        case .famousSights: "Famous sights"
        case .hiddenGems: "Hidden gems"
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
