import Foundation

/// One location fix from the phone (CoreLocation in the app).
public struct LocationFix: Hashable, Sendable {
    public var coordinate: Coordinate
    /// Metres (CLLocation.horizontalAccuracy). Nil if unknown. Fixes worse than
    /// `WalkConfig.maxFixAccuracy` are ignored.
    public var horizontalAccuracy: Double?
    /// Direction of travel in degrees from north (CLLocation.course), if valid.
    /// Only used for left/right when the route itself has no direction there.
    public var heading: Double?
    public var timestamp: Date

    public init(coordinate: Coordinate, horizontalAccuracy: Double? = nil, heading: Double? = nil, timestamp: Date) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.heading = heading
        self.timestamp = timestamp
    }
}

/// Walking-mode constants (PLAN.md section 7.4).
public struct WalkConfig: Hashable, Sendable {
    /// Metres from the route that count as off route.
    public var offRouteDistance: Double = 50
    /// Consecutive far fixes before declaring off route, to ride out GPS noise.
    public var offRouteFixes: Int = 3
    /// Metres from the route to count as back on route. Lower than
    /// `offRouteDistance` so noise near the threshold doesn't flap the state.
    public var backOnRouteDistance: Double = 30
    /// Consecutive near fixes before declaring back on route.
    public var backOnRouteFixes: Int = 3
    /// Metres. Fixes less accurate than this are ignored.
    public var maxFixAccuracy: Double = 65
    /// Metres ahead along the route at which a highlight is nudged.
    public var nudgeDistance: Double = 60
    /// Metres past a highlight before its nudge goes away.
    public var nudgePassedMargin: Double = 15
    /// Metres. Highlights closer to the route than this get no left/right.
    public var sideThreshold: Double = 8
    /// Metres from the destination that count as arrived.
    public var arrivalRadius: Double = 25
    /// Unused since BE-12 (the route filter replaced the search window); kept
    /// so existing code still compiles.
    public var searchBehind: Double = 40
    /// Metres. The step shown only goes back if progress falls this far behind
    /// its start, so GPS noise at a turn doesn't flicker the instruction.
    public var stepHysteresis: Double = 25
    /// Metres. Matches within this of the closest count as equally good; the
    /// one nearest the expected position along the route wins.
    public var continuityTolerance: Double = 10
    /// m/s, to predict where along the route the next fix should be, and the
    /// pace the route filter expects (give or take 0.5 m/s).
    public var walkingSpeed: Double = 1.35
    /// Seconds. Longer gaps between fixes don't push the prediction further.
    public var maxPredictionGap: TimeInterval = 10
    /// Unused since BE-12 (the route filter tells passes apart by how the
    /// walker moves along them); kept so existing code still compiles.
    public var directionGap: Double = 40
    /// Unused since BE-12; kept so existing code still compiles.
    public var motionWindow: Int = 20
    /// Unused since BE-12; kept so existing code still compiles.
    public var minDrift: Double = 5
    /// Unused since BE-12 (the route filter replaced the search window); kept
    /// so existing code still compiles.
    public var searchAhead: Double = 120
    /// m/s, the fastest the route filter expects the walker to move.
    public var maxSpeed: Double = 4

    public static let `default` = WalkConfig()

    public init() {}
}

/// Which side of the walker a highlight is on, relative to the route direction.
public enum Side: String, Hashable, Sendable {
    case left
    case right
}

/// "Up ahead" card content.
public struct Nudge: Hashable, Sendable {
    public var highlight: Highlight
    /// Metres along the route from the walker to the highlight (negative once passed).
    public var distanceAhead: Double
    /// Nil when the highlight is on the route itself (e.g. a waypoint).
    public var side: Side?
}

/// Something that just happened, for haptics and one-off UI.
public enum WalkEvent: Hashable, Sendable {
    /// Far from the route for `offRouteFixes` fixes in a row: time to reroute.
    case offRoute
    case backOnRoute
    case nudgeShown(Nudge)
    /// The nudge for this POI id went away because the walker passed it.
    case nudgePassed(String)
    case arrived
}

/// State after one fix.
public struct WalkUpdate: Hashable, Sendable {
    /// Metres along the route from the start.
    public var progress: Double
    public var routeLength: Double
    public var remainingDistance: Double { max(0, routeLength - progress) }
    /// Metres from the fix to the route.
    public var distanceFromRoute: Double
    /// Index into `WalkTracker.steps` of the step being walked.
    public var stepIndex: Int
    /// Next instruction to show (the next step with text), if any.
    public var nextStep: RouteStep?
    /// Metres to where `nextStep` starts, or to the destination if there is none.
    public var distanceToNextStep: Double
    public var isOffRoute: Bool
    public var hasArrived: Bool
    /// The nudge on screen, if any. At most one at a time.
    public var nudge: Nudge?
    public var events: [WalkEvent]
}

/// Follows a walk along a `WanderPlan` (PLAN.md section 7.4): progress, steps,
/// off-route detection, arrival and "up ahead" nudges. Feed it fixes in order.
///
/// A `RouteFilter` keeps track of where along the route the walker probably
/// is, from all fixes so far and how far a walker moves between them. Where
/// the route runs back along the same or a parallel street (out and back to a
/// stop), the passes are about equally close under GPS noise, and only that
/// history tells them apart. Each fix is then placed exactly on the route
/// near the filter's most likely position. A fix near the route but far from
/// that position (a shortcut, or a long gap) starts the filter afresh.
/// Off route means farther than `offRouteDistance` from every part of the
/// route; those fixes leave progress alone.
public struct WalkTracker: Sendable {
    /// A step placed on the route.
    public struct TrackedStep: Hashable, Sendable {
        public var step: RouteStep
        /// Metres along the route where the step starts.
        public var start: Double
    }

    public let config: WalkConfig
    public let plan: WanderPlan
    /// All steps of all legs, in order.
    public let steps: [TrackedStep]

    private let line: MeasuredPolyline
    private let destination: Coordinate
    private let highlights: [Highlight]

    private var progress: Double = 0
    private var hasFix = false
    private var lastTimestamp: Date?
    private var farFixes = 0
    private var nearFixes = 0
    private var isOffRoute = false
    private var hasArrived = false
    private var lastDistanceFromRoute: Double = 0
    /// POI ids nudged, skipped or passed: never nudged (again).
    private var done: Set<String> = []
    private var active: Nudge?
    private var lastHeading: Double?
    private var stepIndex = 0
    /// Where along the route the walker probably is.
    private var filter: RouteFilter
    /// Metres either side of the filter's most likely position searched for
    /// the exact match.
    private let matchWindow = 25.0
    /// Metres. The predicted position breaks ties only within this of the
    /// filter's most likely position.
    private let predictionAgreement = 6.0
    /// Time of the last fix the filter took.
    private var lastFiltered: Date?

    public init(plan: WanderPlan, config: WalkConfig = .default) {
        self.plan = plan
        self.config = config
        let start = plan.legs.first?.from ?? plan.baseline.from
        let projection = LocalProjection(origin: start)
        let line = MeasuredPolyline(plan.polyline, projection: projection)
        self.line = line
        filter = RouteFilter(line: line)
        destination = plan.legs.last?.to ?? plan.baseline.to
        highlights = plan.highlights.sorted { ($0.distanceAlongRoute, $0.poi.id) < ($1.distanceAlongRoute, $1.poi.id) }

        // Place each leg's steps on the measured route, scaling the provider's
        // step distances to the leg's measured length.
        var steps: [TrackedStep] = []
        var legStart = 0.0
        for leg in plan.legs {
            let legLength = MeasuredPolyline(leg.polyline, projection: projection).totalLength
            let legSteps = leg.steps.isEmpty ? [RouteStep(instruction: "", distance: legLength)] : leg.steps
            let total = legSteps.reduce(0) { $0 + max(0, $1.distance) }
            var covered = 0.0
            for (i, step) in legSteps.enumerated() {
                let fraction = total > 0 ? covered / total : Double(i) / Double(legSteps.count)
                steps.append(TrackedStep(step: step, start: legStart + fraction * legLength))
                covered += max(0, step.distance)
            }
            legStart += legLength
        }
        self.steps = steps
    }

    /// Processes the next fix.
    public mutating func update(_ fix: LocationFix) -> WalkUpdate {
        var events: [WalkEvent] = []
        if let heading = fix.heading, heading >= 0 { lastHeading = heading }
        if let accuracy = fix.horizontalAccuracy, accuracy < 0 || accuracy > config.maxFixAccuracy {
            return snapshot(events: events)
        }

        let gap = lastTimestamp.map { max(0, fix.timestamp.timeIntervalSince($0)) } ?? 0
        lastTimestamp = fix.timestamp
        let anywhere = line.nearest(to: fix.coordinate)
        var near = anywhere
        if anywhere.distance <= config.offRouteDistance {
            near = match(fix, gap: gap)
            if near.distance > config.offRouteDistance {
                // Near the route, but nowhere near where the walker was thought
                // to be (a shortcut, or the app was asleep): start afresh.
                filter.reset()
                near = match(fix, gap: gap)
            }
        }
        hasFix = true
        lastDistanceFromRoute = near.distance

        // Off route only after several far fixes in a row; back on only after
        // several clearly near ones (hysteresis on both distance and count).
        if anywhere.distance > config.offRouteDistance {
            farFixes += 1
            nearFixes = 0
        } else {
            farFixes = 0
            progress = near.along
            nearFixes = anywhere.distance <= config.backOnRouteDistance ? nearFixes + 1 : 0
        }
        if !isOffRoute && farFixes >= config.offRouteFixes {
            isOffRoute = true
            events.append(.offRoute)
        } else if isOffRoute && nearFixes >= config.backOnRouteFixes {
            isOffRoute = false
            events.append(.backOnRoute)
        }

        if !hasArrived && (fix.coordinate.distance(to: destination) <= config.arrivalRadius
                           || (!isOffRoute && progress >= line.totalLength - config.arrivalRadius)) {
            hasArrived = true
            events.append(.arrived)
        }

        updateNudge(events: &events)
        updateStep()
        return snapshot(events: events)
    }

    private mutating func updateStep() {
        var index = 0
        while index + 1 < steps.count && steps[index + 1].start <= progress { index += 1 }
        if index < stepIndex && progress > steps[stepIndex].start - config.stepHysteresis { return }
        stepIndex = index
    }

    /// Matches a fix near the route: the filter picks the most likely
    /// position, then the fix is placed exactly on the route near it. Where
    /// the route passes by twice within that stretch (right at a turnaround),
    /// the match nearest the predicted position wins, so progress doesn't
    /// jump back and forth between the two; the prediction only counts while
    /// it agrees with the filter, so one bad match can't carry over.
    private mutating func match(_ fix: LocationFix, gap: TimeInterval) -> (distance: Double, along: Double) {
        let sigma = min(max(fix.horizontalAccuracy ?? 15, 8), 30)
        let filterGap = lastFiltered.map { max(0, fix.timestamp.timeIntervalSince($0)) } ?? gap
        lastFiltered = fix.timestamp
        let likely = min(line.totalLength, filter.update(line.point(fix.coordinate), sigma: sigma,
                                                          gap: filterGap, config: config))
        let window = max(0, likely - matchWindow)...min(line.totalLength, likely + matchWindow)
        var expected = progress + config.walkingSpeed * min(gap, config.maxPredictionGap)
        if !hasFix || abs(expected - likely) > predictionAgreement { expected = likely }
        return line.nearest(to: fix.coordinate, within: window, near: expected,
                            tolerance: config.continuityTolerance)
    }

    /// Dismisses the current nudge. It won't come back.
    public mutating func skipNudge() {
        active = nil
    }

    private mutating func updateNudge(events: inout [WalkEvent]) {
        if let current = active {
            if current.highlight.distanceAlongRoute - progress < -config.nudgePassedMargin {
                events.append(.nudgePassed(current.highlight.poi.id))
                active = nil
            } else {
                return
            }
        }
        guard !isOffRoute, !hasArrived else { return }
        for highlight in highlights where !done.contains(highlight.poi.id) {
            let ahead = highlight.distanceAlongRoute - progress
            if ahead < -config.nudgePassedMargin {
                done.insert(highlight.poi.id)   // passed without a nudge; don't show it late
                continue
            }
            guard ahead <= config.nudgeDistance else { break }   // sorted by distance along
            done.insert(highlight.poi.id)
            let nudge = Nudge(highlight: highlight, distanceAhead: ahead, side: side(of: highlight))
            active = nudge
            events.append(.nudgeShown(nudge))
            return
        }
    }

    /// Left or right of the route direction at the highlight; the walker's
    /// heading is used only where the route has no direction.
    private func side(of highlight: Highlight) -> Side? {
        guard highlight.distanceFromRoute >= config.sideThreshold else { return nil }
        let position = line.position(at: highlight.distanceAlongRoute)
        var direction = position.direction
        if direction == nil, let heading = lastHeading {
            let radians = heading * .pi / 180
            direction = SIMD2(sin(radians), cos(radians))   // x east, y north
        }
        guard let direction else { return nil }
        let offset = line.point(highlight.poi.coordinate) - position.point
        let cross = direction.x * offset.y - direction.y * offset.x
        return cross > 0 ? .left : .right
    }

    private func snapshot(events: [WalkEvent]) -> WalkUpdate {
        let index = stepIndex
        let next = steps.dropFirst(index + 1).first { !$0.step.instruction.isEmpty }
        var nudge = active
        nudge?.distanceAhead = (active?.highlight.distanceAlongRoute ?? 0) - progress
        return WalkUpdate(
            progress: progress, routeLength: line.totalLength,
            distanceFromRoute: lastDistanceFromRoute, stepIndex: index,
            nextStep: next?.step,
            distanceToNextStep: max(0, (next?.start ?? line.totalLength) - progress),
            isOffRoute: isOffRoute, hasArrived: hasArrived, nudge: nudge, events: events)
    }
}

extension WalkTracker {
    /// Turns a stream of fixes into a stream of updates.
    public func updates<S: AsyncSequence & Sendable>(for fixes: S) -> AsyncThrowingStream<WalkUpdate, Error>
        where S.Element == LocationFix {
        let initial = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var tracker = initial
                do {
                    for try await fix in fixes {
                        continuation.yield(tracker.update(fix))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
