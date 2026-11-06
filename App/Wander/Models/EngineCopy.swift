import RouteEngine

// User-facing words for RouteEngine types.

/// Route-style picker labels for the engine's presets.
extension WeightPreset: @retroactive Identifiable {
    public var id: Self { self }

    var title: String {
        switch self {
        case .balanced: "Balanced"
        case .photoSpots: "Photo spots"
        case .famousSights: "Famous"
        case .hiddenGems: "Hidden gems"
        }
    }
}

extension Mode {
    var title: String {
        switch self {
        case .direct: "Direct"
        case .recommended: "Recommended"
        }
    }
}

extension POICategory {
    /// Interest chip label.
    var chipTitle: String {
        switch self {
        case .photo: "Sights"
        case .shop: "Shops"
        case .food: "Food & drink"
        }
    }
}
