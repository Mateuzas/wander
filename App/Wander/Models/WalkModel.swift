import CoreLocation
import Observation
import RouteEngine
import SwiftUI
import UIKit

/// Walking mode (PLAN.md §7.4): feeds location fixes to RouteEngine's
/// WalkTracker, reacts to its events, reroutes when off route, and keeps the
/// screen awake until the walk ends or arrives.
@MainActor
@Observable
final class WalkModel {
    enum Phase: Equatable {
        case walking
        case arrived
        case ended
    }

    /// Seconds between reroute attempts while still off route after a failure.
    static let rerouteRetryInterval: TimeInterval = 30

    let destinationName: String
    private(set) var plan: WanderPlan
    private(set) var update: WalkUpdate?
    private(set) var phase: Phase = .walking
    private(set) var isRerouting = false
    /// Last reroute failed (usually no connection); retried while still off route.
    private(set) var rerouteFailed = false

    /// The "Up ahead" card, if one is showing.
    var nudge: Nudge? { phase == .walking ? update?.nudge : nil }

    /// Seconds left at walking speed, from the remaining route distance.
    var remainingTime: TimeInterval {
        (update?.remainingDistance ?? plan.totalDistance) / WalkConfig.default.walkingSpeed
    }

    var remainingDistance: Double { update?.remainingDistance ?? plan.totalDistance }

    var destination: Coordinate { plan.legs.last?.to ?? plan.baseline.to }

    @ObservationIgnored private var tracker: WalkTracker
    @ObservationIgnored private let provider: WalkingTimeProvider
    @ObservationIgnored private let pois: [POI]
    @ObservationIgnored private let interests: Set<POICategory>
    /// POIs already nudged, skipped or passed; not nudged again after a reroute.
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var lastFix: LocationFix?
    @ObservationIgnored private var lastRerouteAttempt: Date?
    @ObservationIgnored private let haptic = UIImpactFeedbackGenerator(style: .light)

    init(plan: WanderPlan, destinationName: String, provider: WalkingTimeProvider,
         pois: [POI], interests: Set<POICategory>) {
        self.plan = plan
        self.destinationName = destinationName
        self.provider = provider
        self.pois = pois
        self.interests = interests
        tracker = WalkTracker(plan: plan)
        UIApplication.shared.isIdleTimerDisabled = true
        haptic.prepare()
    }

    // MARK: - Input

    func handle(_ location: CLLocation) {
        handle(LocationFix(
            coordinate: Coordinate(location.coordinate),
            horizontalAccuracy: location.horizontalAccuracy,
            heading: location.course >= 0 ? location.course : nil,
            timestamp: location.timestamp))
    }

    func handle(_ fix: LocationFix) {
        guard phase == .walking else { return }
        lastFix = fix
        apply(tracker.update(fix), at: fix)
    }

    func skipNudge() {
        if let id = update?.nudge?.highlight.poi.id { seen.insert(id) }
        tracker.skipNudge()
        update?.nudge = nil
    }

    func end() {
        finish(.ended)
    }

    /// Releases the screen-awake lock without changing the phase, e.g. when the view goes away.
    func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Events

    private func apply(_ update: WalkUpdate, at fix: LocationFix) {
        self.update = update
        for event in update.events {
            switch event {
            case .nudgeShown(let nudge):
                seen.insert(nudge.highlight.poi.id)
                haptic.impactOccurred()
                AccessibilityNotification.Announcement(Self.spoken(nudge)).post()
                haptic.prepare()
            case .nudgePassed(let id):
                seen.insert(id)
            case .offRoute:
                reroute(from: fix.coordinate)
            case .backOnRoute:
                rerouteFailed = false
            case .arrived:
                finish(.arrived)
            }
        }
        // Still off route after a failed reroute: try again now and then.
        if update.isOffRoute, rerouteFailed, !isRerouting,
           Date().timeIntervalSince(lastRerouteAttempt ?? .distantPast) >= Self.rerouteRetryInterval {
            reroute(from: fix.coordinate)
        }
    }

    private func finish(_ phase: Phase) {
        guard self.phase == .walking else { return }
        self.phase = phase
        update?.nudge = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Reroute

    /// Plans a new route from `start` through the stops still ahead to the destination.
    private func reroute(from start: Coordinate) {
        guard !isRerouting, phase == .walking else { return }
        isRerouting = true
        lastRerouteAttempt = Date()
        let progress = update?.progress ?? 0
        let ahead = Set(plan.highlights.filter { $0.role == .waypoint && $0.distanceAlongRoute > progress }.map(\.poi.id))
        let remaining = plan.waypoints.filter { ahead.contains($0.id) }
        let old = plan, destination = self.destination, provider = self.provider

        Task {
            defer { isRerouting = false }
            do {
                let stops = [start] + remaining.map(\.coordinate) + [destination]
                var legs: [Leg] = []
                for i in 1..<stops.count {
                    legs.append(try await provider.leg(from: stops[i - 1], to: stops[i]))
                }
                guard phase == .walking else { return }
                let total = legs.reduce(0) { $0 + $1.duration }
                var rerouted = WanderPlan(
                    baseline: old.baseline, waypoints: remaining, legs: legs, totalTime: total,
                    extraTime: total - old.baseline.duration, highlights: [], noDetourFit: false,
                    candidates: old.candidates)
                rerouted.highlights = PlanEditor.highlights(
                    along: rerouted.polyline, waypoints: remaining, pois: pois, interests: interests)
                    .filter { !seen.contains($0.poi.id) || $0.role == .waypoint }
                plan = rerouted
                tracker = WalkTracker(plan: rerouted)
                rerouteFailed = false
                if let lastFix { apply(tracker.update(lastFix), at: lastFix) }
            } catch {
                rerouteFailed = true
            }
        }
    }

    // MARK: - Copy

    /// "on your right, 40 m" or "40 m ahead".
    static func position(of nudge: Nudge) -> String {
        let distance = Format.distance(max(0, nudge.distanceAhead))
        switch nudge.side {
        case .left: return "on your left, \(distance)"
        case .right: return "on your right, \(distance)"
        case nil: return "\(distance) ahead"
        }
    }

    /// VoiceOver: "Photo spot, Mural on Stiklių, 40 metres ahead on your right".
    static func spoken(_ nudge: Nudge) -> String {
        let poi = nudge.highlight.poi
        let metres = Int((max(0, nudge.distanceAhead) / 10).rounded()) * 10
        var text = "\(poi.category.spokenName), \(poi.name), \(metres) metres ahead"
        switch nudge.side {
        case .left: text += " on your left"
        case .right: text += " on your right"
        case nil: break
        }
        return text
    }
}
