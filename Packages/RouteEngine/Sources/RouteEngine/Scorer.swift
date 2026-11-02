import Foundation

/// Value and cost-benefit ratio for candidates (PLAN.md section 6, step 4).
struct Scorer {
    var config: PlannerConfig
    var interests: Set<POICategory>
    var weights: SignalWeights?
    /// POI ids already shown to the walker.
    var seen: Set<String> = []

    /// `Σ weight × signal × interestWeight`, using `score` when there are no
    /// weights or no signals, times `seenFactor` for places already shown.
    /// Interests are on/off for now, so the interest weight is 1 or 0.
    func value(_ poi: POI) -> Double {
        guard interests.contains(poi.category) else { return 0 }
        var value = Double(poi.score)
        if let weights, let signals = poi.signals, let weighted = weights.value(of: signals) {
            value = weighted
        }
        return seen.contains(poi.id) ? value * config.seenFactor : value
    }

    /// `value / extraTime`, with extra time floored so on-route POIs stay finite.
    func ratio(_ poi: POI, extraTime: TimeInterval) -> Double {
        value(poi) / max(extraTime, config.minExtraTimeForRatio)
    }
}
