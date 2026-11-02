import Foundation

/// Value and cost-benefit ratio for candidates (PLAN.md section 6, step 4).
struct Scorer {
    var config: PlannerConfig
    var interests: Set<POICategory>

    /// `score × interestWeight`. Interests are on/off for now, so the weight is 1 or 0.
    func value(_ poi: POI) -> Double {
        interests.contains(poi.category) ? Double(poi.score) : 0
    }

    /// `value / extraTime`, with extra time floored so on-route POIs stay finite.
    func ratio(_ poi: POI, extraTime: TimeInterval) -> Double {
        value(poi) / max(extraTime, config.minExtraTimeForRatio)
    }
}
