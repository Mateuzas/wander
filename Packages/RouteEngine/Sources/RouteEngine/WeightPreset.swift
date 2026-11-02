import Foundation

/// Profiles for the app's profile picker. Each maps to the `weights` of a
/// `PlanRequest`; values stay on the 0–100 scale (see `SignalWeights`).
public enum WeightPreset: String, CaseIterable, Codable, Hashable, Sendable {
    /// The curated default: each POI's `score`, which also carries the manual
    /// curation boosts that signals alone don't have.
    case balanced
    /// Places people photograph a lot.
    case photoSpots
    /// Well-known landmarks.
    case famousSights
    /// Well-mapped independent places that aren't famous.
    case hiddenGems

    /// Weights for `PlanRequest.weights`. Nil means "use `score`".
    public var weights: SignalWeights? {
        switch self {
        case .balanced:
            nil
        case .photoSpots:
            SignalWeights(photos: 0.7, fame: 0.2, quality: 0.1)
        case .famousSights:
            SignalWeights(photos: 0.2, fame: 0.7, quality: 0.1)
        case .hiddenGems:
            // Fame counts against: a famous place scores lower than an unknown
            // one with the same quality.
            SignalWeights(fame: -0.2, quality: 0.4, independent: 0.4)
        }
    }
}
