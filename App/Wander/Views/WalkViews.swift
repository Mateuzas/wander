import RouteEngine
import SwiftUI

/// Walking state, top card: next turn and distance (PLAN.md §7.4, §10 wireframe).
/// Always visible while walking.
struct TurnCard: View {
    let walk: WalkModel

    var body: some View {
        HStack(alignment: .top, spacing: Layout.grid * 1.5) {
            Image(systemName: content.glyph)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.ink)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Layout.grid / 2) {
                Text(content.title)
                    .font(WanderFont.heading)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = content.detail {
                    Text(detail)
                        .font(WanderFont.caption)
                        .foregroundStyle(.inkMuted)
                }
            }
            Spacer(minLength: 0)
            if walk.isRerouting { ProgressView() }
        }
        .padding(Layout.margin)
        .background(.surfaceRaised, in: RoundedRectangle(cornerRadius: Layout.margin, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var content: (glyph: String, title: String, detail: String?) {
        guard let update = walk.update else {
            return ("location", "Finding your location", nil)
        }
        if walk.isRerouting {
            return ("arrow.triangle.branch", "Finding a new route", nil)
        }
        if update.isOffRoute {
            return ("arrow.uturn.backward", "Off route. Head back to the violet line.",
                    walk.rerouteFailed ? "No connection to plan a new route" : nil)
        }
        let distance = Format.distance(update.distanceToNextStep)
        guard let step = update.nextStep else {
            return ("mappin", "Continue to \(walk.destinationName)", distance)
        }
        return (Self.glyph(for: step.instruction), step.instruction, distance)
    }

    /// MapKit gives text only, so the arrow comes from the instruction's words.
    static func glyph(for instruction: String) -> String {
        let text = instruction.lowercased()
        if text.contains("arrive") || text.contains("destination") { return "mappin" }
        if text.contains("slight left") || text.contains("bear left") { return "arrow.up.left" }
        if text.contains("slight right") || text.contains("bear right") { return "arrow.up.right" }
        if text.contains("u-turn") || text.contains("turn around") { return "arrow.uturn.backward" }
        if text.contains("left") { return "arrow.turn.up.left" }
        if text.contains("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }
}

/// Sheet content while walking: time and distance left and End walk (peek), or
/// the arrival / ended state with Done.
struct WalkSheet: View {
    let walk: WalkModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.grid) {
            switch walk.phase {
            case .walking:
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(max(1, Format.minutes(walk.remainingTime))) min left")
                            .font(WanderFont.heading)
                            .foregroundStyle(.ink)
                        Text("\(Format.distance(walk.remainingDistance)) to \(walk.destinationName)")
                            .font(WanderFont.caption)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: Layout.grid)
                    Button("End walk", action: walk.end)
                        .buttonStyle(.textAction)
                }
            case .arrived:
                finished("You've arrived at \(walk.destinationName).")
            case .ended:
                finished("Walk ended")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.margin)
        .padding(.top, Layout.margin + Layout.grid)
    }

    private func finished(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: Layout.margin) {
            Text(title)
                .font(WanderFont.title)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Button("Done", action: onDone)
                .buttonStyle(.primary)
        }
    }
}

/// The "Up ahead" card for the current nudge, with Skip.
struct UpAheadCard: View {
    let nudge: Nudge
    let onSkip: () -> Void

    var body: some View {
        let poi = nudge.highlight.poi
        let position = WalkModel.position(of: nudge)
        NudgeCard(
            category: poi.category,
            glyph: poi.glyph,
            poi: poi,
            title: poi.name,
            pitch: poi.pitch,
            // With a hook, the type joins the position line; without one the reason is the pitch.
            detail: poi.hookLine != nil && !poi.reason.isEmpty ? "\(poi.reason) · \(position)" : position,
            action: onSkip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([WalkModel.spoken(nudge), poi.hookLine].compactMap { $0 }.joined(separator: ". "))
            .accessibilityAction(named: "Skip", onSkip)
    }
}
