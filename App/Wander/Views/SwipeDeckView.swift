import RouteEngine
import SwiftUI

/// Step 3 of a swipe walk (ADR 016): a full-height stack of place cards. Drag left
/// for nope, right for like, up for love, or use the buttons below. The counter at
/// the top fills like the Wander route, a bead for each place kept; when it reaches
/// the chosen time the deck finishes by itself.
struct SwipeDeckView: View {
    let session: SwipeSession
    /// Plans the walk from the loved and liked places (the summary).
    let onDone: () -> Void
    /// Back to the area step.
    let onBack: () -> Void

    @State private var drag: CGSize = .zero
    /// True while a card flies out or back, so a second swipe can't start.
    @State private var moving = false
    @State private var finishing = false
    @State private var swipeTick = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far a card must travel to count.
    private static let sideThreshold: CGFloat = 110
    private static let upThreshold: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            WalkMeter(minutes: session.estimatedMinutes, target: session.length.minutes, marks: session.marks)
                .padding(.horizontal, Layout.margin)
                .padding(.top, Layout.grid / 2)
            stack
                .padding(.horizontal, Layout.margin)
                .padding(.top, Layout.margin)
                .frame(maxHeight: .infinity)
            controls
                .padding(.top, Layout.margin)
                .padding(.bottom, Layout.grid)
        }
        .background(Color.surface.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: swipeTick)
        .sensoryFeedback(.success, trigger: finishing) { _, new in new }
        // A place kept that fills the chosen time ends the deck.
        .onChange(of: session.marks.count) { old, new in
            if new > old, session.isFull { finishSoon() }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.ink)
                    .frame(width: Layout.minTouch, height: Layout.minTouch, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the area")
            Spacer()
            Button("Done", action: onDone)
                .buttonStyle(.textAction)
                .disabled(!session.canFinish || finishing)
                .accessibilityHint("Plans the walk from the places you loved and liked")
        }
        .padding(.horizontal, Layout.margin)
    }

    // MARK: - Cards

    @ViewBuilder
    private var stack: some View {
        if let poi = session.current {
            ZStack {
                // The next two sit behind, so their photos are loading before they show.
                ForEach(Array(session.upcoming.enumerated()).reversed(), id: \.element.id) { offset, next in
                    DeckCard(poi: next, minutesAway: session.minutesAway(next), reaction: nil, strength: 0)
                        .scaleEffect(offset == 0 ? 0.94 + 0.06 * progress : 0.88)
                        .offset(y: offset == 0 ? 14 * (1 - progress) : 28)
                        .opacity(offset == 0 ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                DeckCard(poi: poi, minutesAway: session.minutesAway(poi), reaction: dragReaction.reaction,
                         strength: dragReaction.strength)
                    .offset(drag)
                    .rotationEffect(.degrees(Double(drag.width / 22)), anchor: .bottom)
                    .gesture(dragGesture)
                    .id(poi.id)
                    .accessibilityAction(named: "Love") { commit(.love) }
                    .accessibilityAction(named: "Like") { commit(.like) }
                    .accessibilityAction(named: "Nope") { commit(.nope) }
                    .accessibilityAction(named: "Undo") { undo() }
            }
        } else {
            outOfCards
        }
    }

    /// 0 at rest, 1 once the drag would count.
    private var progress: CGFloat {
        min(1, max(abs(drag.width) / Self.sideThreshold, -drag.height / Self.upThreshold, 0))
    }

    /// What the current drag means, and how sure (0–1).
    private var dragReaction: (reaction: Reaction?, strength: Double) {
        if -drag.height > abs(drag.width), drag.height < -12 {
            return (.love, min(1, Double(-drag.height / Self.upThreshold)))
        }
        if drag.width > 12 { return (.like, min(1, Double(drag.width / Self.sideThreshold))) }
        if drag.width < -12 { return (.nope, min(1, Double(-drag.width / Self.sideThreshold))) }
        return (nil, 0)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !moving, !finishing else { return }
                drag = value.translation
            }
            .onEnded { value in
                guard !moving, !finishing else { return }
                let t = value.predictedEndTranslation
                let w = value.translation.width, h = value.translation.height
                if -h > abs(w), -h > Self.upThreshold || -t.height > Self.upThreshold * 2 {
                    commit(.love)
                } else if w > Self.sideThreshold || t.width > Self.sideThreshold * 2 {
                    commit(.like)
                } else if w < -Self.sideThreshold || t.width < -Self.sideThreshold * 2 {
                    commit(.nope)
                } else {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.35)) {
                        drag = .zero
                    }
                }
            }
    }

    /// Where a card flies for `reaction`.
    private static func exit(for reaction: Reaction) -> CGSize {
        switch reaction {
        case .like: CGSize(width: 600, height: 40)
        case .nope: CGSize(width: -600, height: 40)
        case .love: CGSize(width: 0, height: -1000)
        }
    }

    private func commit(_ reaction: Reaction) {
        guard !moving, !finishing, let poi = session.current else { return }
        swipeTick += 1
        let announce = {
            let next = session.current.map { ". Next: \($0.name)" } ?? ""
            AccessibilityNotification.Announcement("\(reaction.spoken) \(poi.name)\(next)").post()
        }
        // Reduce Motion: no fly-out, the next card just takes its place.
        guard !reduceMotion else {
            drag = .zero
            session.react(reaction)
            announce()
            return
        }
        moving = true
        withAnimation(.easeIn(duration: 0.22)) {
            drag = Self.exit(for: reaction)
        } completion: {
            var plain = Transaction()
            plain.disablesAnimations = true
            withTransaction(plain) {
                session.react(reaction)
                drag = .zero
            }
            moving = false
            announce()
        }
    }

    /// One level: the last card comes back from where it went.
    private func undo() {
        guard !moving, !finishing, let last = session.lastSwipe else { return }
        guard !reduceMotion else {
            session.undo()
            return
        }
        moving = true
        var plain = Transaction()
        plain.disablesAnimations = true
        withTransaction(plain) {
            session.undo()
            drag = Self.exit(for: last.reaction)
        }
        withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
            drag = .zero
        } completion: {
            moving = false
        }
    }

    /// The counter reached the chosen time: a subtle haptic, then the summary.
    private func finishSoon() {
        guard !finishing else { return }
        finishing = true
        AccessibilityNotification.Announcement("Your walk is full. Planning it now.").post()
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 650))
            onDone()
        }
    }

    // MARK: - Out of cards

    private var outOfCards: some View {
        VStack(alignment: .leading, spacing: Layout.margin) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.wander)
                .accessibilityHidden(true)
            Text("That's everything worth seeing here")
                .font(WanderFont.title)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(outOfCardsDetail)
                .font(WanderFont.body)
                .foregroundStyle(.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Layout.grid) {
                if session.canFinish {
                    Button("See your walk", action: onDone).buttonStyle(.primary)
                }
                if session.canWiden {
                    Button("Widen the area") { session.widen() }
                        .buttonStyle(.textAction)
                        .accessibilityHint("Deals more places from a bigger area")
                }
            }
            .padding(.top, Layout.grid)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var outOfCardsDetail: String {
        let kept = session.loved.count + session.liked.count
        if kept == 0 { return "Nothing kept yet. Widen the area for more places." }
        let minutes = Int(session.estimatedMinutes.rounded())
        return "You kept \(kept) \(kept == 1 ? "place" : "places"), about \(minutes) min of walking."
    }

    // MARK: - Buttons

    /// Nope, love and like, in the same places as their gestures; undo on the side.
    private var controls: some View {
        HStack(spacing: Layout.margin) {
            DeckButton(kind: .undo, action: undo)
                .disabled(session.lastSwipe == nil || moving)
            Spacer(minLength: 0)
            DeckButton(kind: .nope) { commit(.nope) }
            DeckButton(kind: .love) { commit(.love) }
            DeckButton(kind: .like) { commit(.like) }
            Spacer(minLength: 0)
            // Balances undo, so the three reactions sit centred.
            Color.clear.frame(width: Layout.minTouch, height: Layout.minTouch)
        }
        .padding(.horizontal, Layout.margin)
        .disabled(session.current == nil || finishing)
        .opacity(session.current == nil ? 0 : 1)
    }
}

// MARK: - Card

/// One deck card: the photo (or its placeholder), the name with its bead, the hook,
/// and the kind with "6 min away". A stamp shows what the current drag means.
private struct DeckCard: View {
    let poi: POI
    let minutesAway: Int
    let reaction: Reaction?
    let strength: Double

    private static let corner: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlaceImage(poi: poi, placeholder: .surface, glyphSize: 44)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) { creditLine }
                .clipped()
            VStack(alignment: .leading, spacing: Layout.grid) {
                HStack(alignment: .firstTextBaseline, spacing: Layout.grid) {
                    Bead(category: poi.category, glyph: poi.glyph, isPopular: poi.mapTier == 1)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 7 }
                    Text(poi.name)
                        .font(WanderFont.title)
                        .foregroundStyle(.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let pitch = poi.pitch {
                    Text(pitch)
                        .font(WanderFont.hook)
                        .foregroundStyle(.ink)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("\(kindLine) · \(minutesAway) min away")
                    .font(WanderFont.caption)
                    .foregroundStyle(.inkMuted)
            }
            .padding(Layout.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .background(Color.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(alignment: stampAlignment) {
            if let reaction {
                Stamp(reaction: reaction)
                    .opacity(strength)
                    .scaleEffect(0.9 + 0.1 * strength)
                    .padding(Layout.margin + 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(poi.name)
        .accessibilityValue([poi.pitch, "\(kindLine), \(minutesAway) minutes away"].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint("Swipe up or down to choose love, like, nope or undo.")
    }

    /// The type when the hook took the pitch line, else the category.
    private var kindLine: String {
        if poi.hookLine != nil, !poi.reason.isEmpty { return poi.reason }
        return poi.category.spokenName
    }

    private var stampAlignment: Alignment {
        switch reaction {
        case .like: .topLeading
        case .nope: .topTrailing
        case .love, nil: .bottom
        }
    }

    @ViewBuilder
    private var creditLine: some View {
        if let photo = poi.photo {
            Text(photo.creditLine)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .padding(Layout.grid)
                .accessibilityHidden(true)
        }
    }
}

/// The ✕ / ♥ / ♥♥ mark on a card being dragged.
private struct Stamp: View {
    let reaction: Reaction

    var body: some View {
        HStack(spacing: Layout.grid * 0.75) {
            ReactionGlyph(reaction: reaction, size: 20)
            Text(reaction.title)
                .font(WanderFont.heading)
        }
        .foregroundStyle(reaction == .nope ? Color.ink : Color.white)
        .padding(.horizontal, Layout.margin)
        .frame(minHeight: 44)
        .background(reaction == .nope ? Color.surfaceRaised : Color.wander, in: Capsule())
        .rotationEffect(.degrees(reaction == .like ? -8 : reaction == .nope ? 8 : 0))
        .accessibilityHidden(true)
    }
}

/// ✕, ♥ or ♥♥ (two hearts, overlapping).
struct ReactionGlyph: View {
    let reaction: Reaction
    var size: CGFloat = 22

    var body: some View {
        switch reaction {
        case .nope:
            Image(systemName: "xmark").font(.system(size: size, weight: .bold))
        case .like:
            Image(systemName: "heart.fill").font(.system(size: size, weight: .semibold))
        case .love:
            HStack(spacing: -size * 0.3) {
                Image(systemName: "heart.fill").font(.system(size: size * 0.8, weight: .semibold))
                Image(systemName: "heart.fill").font(.system(size: size * 0.8, weight: .semibold))
            }
        }
    }
}

extension Reaction {
    var title: String {
        switch self {
        case .love: "Love"
        case .like: "Like"
        case .nope: "Nope"
        }
    }

    /// For the VoiceOver announcement after a swipe.
    var spoken: String {
        switch self {
        case .love: "Loved"
        case .like: "Liked"
        case .nope: "Noped"
        }
    }
}

// MARK: - Buttons

private struct DeckButton: View {
    enum Kind { case undo, nope, like, love }

    let kind: Kind
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            label
                .frame(width: diameter, height: diameter)
                .background(fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(name)
    }

    @ViewBuilder
    private var label: some View {
        switch kind {
        case .undo:
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.inkMuted)
        case .nope:
            ReactionGlyph(reaction: .nope).foregroundStyle(.ink)
        case .like:
            ReactionGlyph(reaction: .like).foregroundStyle(.wander)
        case .love:
            ReactionGlyph(reaction: .love, size: 26).foregroundStyle(.white)
        }
    }

    private var diameter: CGFloat {
        switch kind {
        case .undo: Layout.minTouch
        case .nope, .like: 60
        case .love: 72
        }
    }

    private var fill: Color {
        switch kind {
        case .undo: .clear
        case .nope, .like: .surfaceRaised
        case .love: .wander
        }
    }

    private var name: String {
        switch kind {
        case .undo: "Undo last swipe"
        case .nope: "Nope"
        case .like: "Like"
        case .love: "Love"
        }
    }
}

private struct PressScale: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Counter

/// "38 of 60 min" over a short Wander route that fills toward the chosen time,
/// with a bead for each place kept (loved beads are larger). The deck's one
/// memorable element, echoing the route on the map.
struct WalkMeter: View {
    let minutes: Double
    let target: Double
    let marks: [SwipeSession.Mark]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: Int { Int(minutes.rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.grid) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.grid / 2) {
                Text("\(shown)")
                    .font(WanderFont.stat)
                    .foregroundStyle(.ink)
                    .contentTransition(.numericText(value: Double(shown)))
                Text("of \(Int(target)) min")
                    .font(WanderFont.heading)
                    .foregroundStyle(.inkMuted)
            }
            .monospacedDigit()
            track
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: shown)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Walk so far")
        .accessibilityValue("\(shown) of \(Int(target)) minutes, \(marks.count) \(marks.count == 1 ? "place" : "places")")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fill = width * min(1, minutes / max(target, 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.inkMuted.opacity(0.18)).frame(height: 4)
                Capsule().fill(Color.wander).frame(width: max(fill, 0), height: 6)
                ForEach(marks) { mark in
                    let size: CGFloat = mark.loved ? 16 : 12
                    Circle()
                        .fill(mark.poi.category.color)
                        .overlay(Circle().strokeBorder(Color.surface, lineWidth: 2))
                        .frame(width: size, height: size)
                        .position(x: min(width - size / 2, max(size / 2, width * min(1, mark.minutes / max(target, 1)))),
                                  y: 8)
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                }
            }
            .frame(height: 16)
        }
        .frame(height: 16)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.3), value: marks)
    }
}
