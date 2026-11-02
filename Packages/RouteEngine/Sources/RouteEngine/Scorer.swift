import Foundation

/// Value and cost-benefit ratio for candidates (PLAN.md section 6, step 4).
struct Scorer {
    var config: PlannerConfig
    var interests: Set<POICategory>
    var weights: SignalWeights?

    /// `Σ weight × signal × interestWeight`, using `score` when there are no
    /// weights or no signals. Interests are on/off for now, so the interest
    /// weight is 1 or 0.
    func value(_ poi: POI) -> Double {
        guard interests.contains(poi.category) else { return 0 }
        if let weights, let signals = poi.signals, let value = weights.value(of: signals) {
            return value
        }
        return Double(poi.score)
    }

    /// `value / extraTime`, with extra time floored so on-route POIs stay finite.
    func ratio(_ poi: POI, extraTime: TimeInterval) -> Double {
        value(poi) / max(extraTime, config.minExtraTimeForRatio)
    }
}
