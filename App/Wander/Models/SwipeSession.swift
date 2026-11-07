import CoreLocation
import Foundation
import Observation
import RouteEngine

/// How long the walk should be (ADR 016, "Presets"): the time sets the counter's
/// target and the circle's starting radius.
enum WalkLength: Int, CaseIterable, Identifiable {
    case halfHour = 30
    case hour = 60
    case twoHours = 120

    var id: Self { self }
    var minutes: Double { Double(rawValue) }

    /// Starting circle radius in metres.
    var radius: Double {
        switch self {
        case .halfHour: 600
        case .hour: 1000
        case .twoHours: 1600
        }
    }

    var title: String {
        switch self {
        case .halfHour: "30 min"
        case .hour: "1 h"
        case .twoHours: "2 h"
        }
    }

    var spoken: String {
        switch self {
        case .halfHour: "30 minutes"
        case .hour: "1 hour"
        case .twoHours: "2 hours"
        }
    }
}

/// One swipe walk being built (ADR 016 steps 1–3): the kinds, the area, then the
/// deck. When the deck is done, the map screen hands `mustVisit` (loved) and
/// `optional` (liked) to `PlannerModel` for the summary.
@MainActor
@Observable
final class SwipeSession {
    enum Step: Equatable {
        case kinds
        case area
        case deck
    }

    struct Swipe: Equatable {
        let poi: POI
        let reaction: Reaction
        /// The memory entry the swipe replaced, put back on undo.
        let previous: SwipeMemory.Entry?
    }

    /// Adjustable circle radius, metres (ADR 016 "Resolved").
    static let radiusRange: ClosedRange<Double> = 300...3000
    /// "Widen the area" grows the radius by this factor.
    static let widenFactor = 1.5

    var step: Step = .kinds

    // MARK: Step 1: kinds
    var kinds: Set<DeckKind> = [.sights, .hiddenGems] {
        didSet { refreshCount() }
    }

    // MARK: Step 2: area
    private(set) var length: WalkLength = .hour
    private(set) var radius: Double = WalkLength.hour.radius

    /// A preset: the time, and the circle back to its size.
    func setLength(_ length: WalkLength) {
        self.length = length
        setRadius(length.radius)
    }

    /// Dragging the circle's edge, clamped to 300 m–3 km.
    func setRadius(_ metres: Double) {
        radius = min(max(metres, Self.radiusRange.lowerBound), Self.radiusRange.upperBound)
        refreshCount()
    }

    /// The walk's start and the circle's centre: the user, a dropped pin or a dragged circle.
    private(set) var start: Coordinate?
    /// True once the start moved away from the user's location.
    private(set) var startMoved = false
    /// Nil: the walk ends at the last place. Otherwise the area is a band to it.
    private(set) var destination: Destination?
    /// Places added with "Add to walk" from a place card: loved without swiping.
    private(set) var added: [POI] = []
    /// What `deck(...)` would deal now, for "N places here".
    private(set) var placeCount = 0

    // MARK: Step 3: deck
    private(set) var cards: [POI] = []
    private(set) var index = 0
    private(set) var swipes: [Swipe] = []
    /// The last swipe, until it is undone or another one replaces it.
    private(set) var lastSwipe: Swipe?
    /// Walking minutes for the loved and liked places so far.
    private(set) var estimatedMinutes: Double = 0
    /// Each loved or liked place with the walk's estimate once it was added, for the counter's beads.
    private(set) var marks: [Mark] = []

    struct Mark: Identifiable, Equatable {
        let poi: POI
        let loved: Bool
        let minutes: Double
        var id: String { poi.id }
    }

    @ObservationIgnored private let memory: SwipeMemoryStore
    @ObservationIgnored private var pois: [POI]

    init(start: Coordinate?, startMoved: Bool = false, pois: [POI], memory: SwipeMemoryStore) {
        self.start = start
        self.startMoved = startMoved
        self.pois = pois
        self.memory = memory
        refreshCount()
    }

    // MARK: - Derived

    var end: WalkEnd {
        destination.map { .destination(Coordinate($0.coordinate)) } ?? .anywhere
    }

    var area: DeckArea? {
        guard let start else { return nil }
        if let destination {
            return .band(start: start, end: Coordinate(destination.coordinate), halfWidth: radius / 2)
        }
        return .circle(center: start, radius: radius)
    }

    var budget: TimeInterval { length.minutes * 60 }

    var loved: [POI] { added + swipes.filter { $0.reaction == .love }.map(\.poi) }
    var liked: [POI] { swipes.filter { $0.reaction == .like }.map(\.poi) }

    /// The card on top, nil when the deck has run out.
    var current: POI? { index < cards.count ? cards[index] : nil }
    var upcoming: [POI] { Array(cards.dropFirst(index + 1).prefix(2)) }
    var outOfCards: Bool { step == .deck && current == nil }
    /// The loved and liked places fill the chosen time: the deck stops dealing.
    var isFull: Bool { estimatedMinutes >= length.minutes }
    /// There is a walk to plan: something to visit, or a destination to walk to.
    var canFinish: Bool { !loved.isEmpty || !liked.isEmpty || destination != nil }
    var canWiden: Bool { radius < Self.radiusRange.upperBound }

    /// Rough walking minutes from the start to `poi`, for "6 min away".
    func minutesAway(_ poi: POI) -> Int {
        guard let start else { return 0 }
        return max(1, Int(estimateWalkMinutes(start: start, end: .destination(poi.coordinate), stops: []).rounded()))
    }

    // MARK: - Area

    func setStart(_ coordinate: Coordinate, moved: Bool) {
        start = coordinate
        startMoved = moved
        refreshCount()
    }

    /// The user's location arrived or changed; follows it unless the start was moved.
    func userMoved(to coordinate: Coordinate) {
        guard !startMoved, step != .deck else { return }
        if let start, start.distance(to: coordinate) < 25 { return }
        start = coordinate
        refreshCount()
    }

    func setDestination(_ destination: Destination?) {
        self.destination = destination
        refreshCount()
    }

    func add(_ poi: POI) {
        guard !added.contains(where: { $0.id == poi.id }) else { return }
        added.append(poi)
        refreshCount()
    }

    func removeAdded(_ poi: POI) {
        added.removeAll { $0.id == poi.id }
        refreshCount()
    }

    func isAdded(_ poi: POI) -> Bool { added.contains { $0.id == poi.id } }

    /// New places arrived (FE-15) before the deck started.
    func update(pois: [POI]) {
        guard step != .deck else { return }
        self.pois = pois
        refreshCount()
    }

    // MARK: - Deck

    func beginDeck() {
        cards = dealt()
        index = 0
        swipes = []
        lastSwipe = nil
        step = .deck
        updateEstimate()
    }

    func react(_ reaction: Reaction) {
        guard let poi = current else { return }
        let swipe = Swipe(poi: poi, reaction: reaction, previous: memory.memory.entries[poi.id])
        memory.record(reaction, for: poi)
        swipes.append(swipe)
        lastSwipe = swipe
        index += 1
        if reaction != .nope { updateEstimate() }
    }

    /// One level: the last card comes back and its reaction is forgotten.
    func undo() {
        guard let swipe = lastSwipe, index > 0, cards[index - 1].id == swipe.poi.id else { return }
        memory.restore(swipe.previous, for: swipe.poi.id)
        swipes.removeLast()
        lastSwipe = nil
        index -= 1
        updateEstimate()
    }

    /// "Widen the area": a bigger circle (or band), dealing only the places not shown yet.
    func widen() {
        setRadius(radius * Self.widenFactor)
        let shown = Set(cards.prefix(index).map(\.id))
        cards = Array(cards.prefix(index)) + dealt().filter { !shown.contains($0.id) }
        lastSwipe = nil
    }

    /// Back from the deck to the area step, keeping nothing swiped.
    func backToArea() {
        step = .area
        cards = []
        index = 0
        swipes = []
        lastSwipe = nil
        estimatedMinutes = 0
        marks = []
        refreshCount()
    }

    // MARK: - Private

    private func dealt() -> [POI] {
        guard let area else { return [] }
        let addedIDs = Set(added.map(\.id))
        return deck(pois: pois, area: area, kinds: kinds, memory: memory.memory,
                    seen: memory.seen(), now: .now)
            .filter { !addedIDs.contains($0.id) }
    }

    private func refreshCount() {
        guard step != .deck else { return }
        placeCount = kinds.isEmpty ? 0 : dealt().count
    }

    private func updateEstimate() {
        guard let start else { return }
        let lovedIDs = Set(loved.map(\.id))
        let picked = added + swipes.filter { $0.reaction != .nope }.map(\.poi)
        var stops: [POI] = []
        var marks: [Mark] = []
        for poi in picked {
            stops.append(poi)
            marks.append(Mark(poi: poi, loved: lovedIDs.contains(poi.id),
                              minutes: estimateWalkMinutes(start: start, end: end, stops: stops)))
        }
        self.marks = marks
        estimatedMinutes = marks.last?.minutes ?? estimateWalkMinutes(start: start, end: end, stops: [])
    }
}

// MARK: - Words and glyphs

extension DeckKind {
    var title: String {
        switch self {
        case .sights: "Sights"
        case .food: "Food"
        case .shops: "Shops"
        case .hiddenGems: "Hidden gems"
        }
    }

    /// A short line under the chip title.
    var detail: String {
        switch self {
        case .sights: "Landmarks, views, street art"
        case .food: "Cafés, bakeries, places to eat"
        case .shops: "Independent shops"
        case .hiddenGems: "Good places few people know"
        }
    }

    /// SF Symbol, available on iOS 17.
    var glyph: String {
        switch self {
        case .sights: POICategory.photo.glyph
        case .food: POICategory.food.glyph
        case .shops: POICategory.shop.glyph
        case .hiddenGems: "sparkles"
        }
    }

    /// The bead category whose colour the glyph takes; nil for hidden gems (any category).
    var category: POICategory? {
        switch self {
        case .sights: .photo
        case .food: .food
        case .shops: .shop
        case .hiddenGems: nil
        }
    }

    /// Categories planned and drawn as beads for these kinds.
    static func categories(_ kinds: Set<DeckKind>) -> Set<POICategory> {
        if kinds.contains(.hiddenGems) { return Set(POICategory.allCases) }
        return Set(kinds.compactMap(\.category))
    }
}
