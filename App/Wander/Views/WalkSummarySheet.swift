import RouteEngine
import SwiftUI

/// Step 4 of a swipe walk (ADR 016), and the "Walk here" plan: the planned walk on
/// the map above, "1 h 05 · 3 loved · 3 liked", a note when the loved places
/// stretched it, the stops in walking order, the coffee and shop add-ons, then
/// "Start walk" and the hand-offs.
struct WalkSummarySheet: View {
    let planner: PlannerModel
    let onClose: () -> Void
    let onFocus: (POI) -> Void
    let onStartWalk: (WanderPlan) -> Void
    #if DEBUG
    @Binding var debugOverlay: Bool
    #endif

    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            header.sheetRow(top: Layout.margin + Layout.grid)
            summary.sheetRow(top: Layout.grid)
            actions.sheetRow(top: Layout.margin)
            stopList
            addOnRow
            #if DEBUG
            Toggle("Debug overlay", isOn: $debugOverlay)
                .font(WanderFont.caption)
                .foregroundStyle(.inkMuted)
                .sheetRow(top: Layout.margin)
            #endif
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
    }

    private var title: String { planner.request?.title ?? "Your walk" }

    // MARK: - Header and summary

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(WanderFont.title)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Layout.grid)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.inkMuted)
                    .frame(width: Layout.minTouch, height: Layout.minTouch)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch planner.phase {
        case .loading:
            HStack(spacing: Layout.grid) {
                ProgressView()
                Text("Planning your walk")
                    .font(WanderFont.body)
                    .foregroundStyle(.inkMuted)
            }
            .frame(minHeight: 64, alignment: .leading)
        case .failed(let failure):
            FailureMessage(failure: failure, retry: planner.retry)
        case .ready:
            if let walk = planner.walk, let request = planner.request {
                WalkStats(walk: walk, request: request)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: Layout.grid) {
            Button("Start walk") {
                if let plan = planner.plan { onStartWalk(plan) }
            }
            .buttonStyle(.primary)
            .disabled(planner.plan == nil)

            Button("Open in Google Maps") {
                if let plan = planner.plan, let url = HandOff.googleMapsURL(for: plan) { openURL(url) }
            }
            .buttonStyle(.textAction)
            .disabled(planner.plan == nil)

            HStack(alignment: .firstTextBaseline, spacing: Layout.grid) {
                Button("Open in Apple Maps") {
                    if let plan = planner.plan { HandOff.openAppleMaps(for: plan, destinationName: planner.endName) }
                }
                .buttonStyle(.textAction)
                .disabled(planner.plan == nil)
                if (planner.plan?.waypoints.count ?? 0) > (planner.request?.endName == nil ? 1 : 0) {
                    Text("Opens the first stop")
                        .font(WanderFont.caption)
                        .foregroundStyle(.inkMuted)
                }
            }
        }
    }

    // MARK: - Stops

    @ViewBuilder
    private var stopList: some View {
        if let plan = planner.plan, planner.phase == .ready {
            let stops = plan.highlights.filter { $0.role == .waypoint }
            let passing = plan.highlights.filter { $0.role == .passby }
            if !stops.isEmpty {
                sectionTitle("Stops")
                ForEach(stops, id: \.poi.id) { highlight in
                    row(highlight, removable: true)
                }
            }
            if !passing.isEmpty {
                sectionTitle("On the way")
                ForEach(passing, id: \.poi.id) { highlight in
                    row(highlight, removable: false)
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(WanderFont.heading)
            .foregroundStyle(.ink)
            .accessibilityAddTraits(.isHeader)
            .sheetRow(top: Layout.margin)
    }

    private func row(_ highlight: Highlight, removable: Bool) -> some View {
        let poi = highlight.poi
        let reaction = reaction(for: poi)
        return HighlightRow(
            category: poi.category,
            glyph: poi.glyph,
            name: poi.name,
            reason: poi.pitch,
            distance: Format.distance(highlight.distanceAlongRoute))
            .overlay(alignment: .topLeading) {
                if let reaction {
                    ReactionGlyph(reaction: reaction, size: 9)
                        .foregroundStyle(.wander)
                        .padding(2)
                        .background(Color.surface, in: Capsule())
                        .offset(x: 12, y: 12)
                        .accessibilityHidden(true)
                }
            }
            .onTapGesture { onFocus(poi) }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(reaction.map { $0 == .love ? "Loved" : "Liked" } ?? "")
            .modifier(RemoveAction(enabled: removable) { planner.remove(poi) })
            .sheetRow(top: Layout.grid / 2)
    }

    private func reaction(for poi: POI) -> Reaction? {
        guard let request = planner.request else { return nil }
        if request.lovedIDs.contains(poi.id) { return .love }
        if request.likedIDs.contains(poi.id) { return .like }
        return nil
    }

    // MARK: - Add-ons

    /// "Add coffee" and "Add a shop": each puts the best open place near the route
    /// where it adds the least time, then says what it added.
    @ViewBuilder
    private var addOnRow: some View {
        if planner.phase == .ready, planner.walk != nil {
            VStack(alignment: .leading, spacing: Layout.grid / 2) {
                ForEach(PlannerModel.AddOn.allCases) { addOn in
                    AddOnButton(addOn: addOn, state: planner.addOns[addOn]) {
                        Task { await planner.add(addOn) }
                    }
                }
            }
            .sheetRow(top: Layout.margin)
        }
    }
}

// MARK: - Pieces

/// "1 h 05" (Stat), then "3 loved · 3 liked" or "Walk to Old Town Hall", and the
/// stretched note when the loved places needed more than the chosen time.
private struct WalkStats: View {
    let walk: WalkPlan
    let request: PlannerModel.Request

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.grid / 2) {
            Text(Format.duration(walk.plan.totalTime))
                .font(WanderFont.stat)
                .foregroundStyle(.ink)
            Text(detail)
                .font(WanderFont.body)
                .foregroundStyle(.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if walk.stretched {
                Text("Your loved places need \(Format.duration(walk.plan.totalTime)); walk extended.")
                    .font(WanderFont.body)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Layout.grid / 2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let ids = Set(walk.included.map(\.id))
        let loved = request.lovedIDs.intersection(ids).count
        let liked = request.likedIDs.intersection(ids).count
        let distance = Format.distance(walk.plan.totalDistance)
        guard request.swiped else {
            let passing = walk.plan.highlights.count
            return passing == 0 ? "\(distance) walk"
                : "\(distance) · \(passing) \(passing == 1 ? "place" : "places") on the way"
        }
        var parts = ["\(loved) loved", "\(liked) liked"]
        let others = walk.included.count - loved - liked
        if others > 0 { parts.append("\(others) added") }
        return parts.joined(separator: " · ") + " · \(distance)"
    }
}

/// One add-on: the action, then what it added or why nothing.
private struct AddOnButton: View {
    let addOn: PlannerModel.AddOn
    let state: PlannerModel.AddOnState?
    let action: () -> Void

    var body: some View {
        switch state {
        case nil, .failed:
            HStack(alignment: .firstTextBaseline, spacing: Layout.grid) {
                Button(action: action) {
                    Label(addOn.title, systemImage: addOn.glyph)
                }
                .buttonStyle(.textAction)
                if state == .failed {
                    Text("Couldn't add it. Try again.")
                        .font(WanderFont.caption)
                        .foregroundStyle(.inkMuted)
                }
            }
        case .working:
            HStack(spacing: Layout.grid) {
                ProgressView()
                Text(addOn == .coffee ? "Adding coffee…" : "Adding a shop…")
                    .font(WanderFont.body)
                    .foregroundStyle(.inkMuted)
            }
            .frame(minHeight: Layout.minTouch)
        case .added(let poi):
            Label("Added \(poi.name)", systemImage: "checkmark")
                .font(WanderFont.body)
                .foregroundStyle(.ink)
                .frame(minHeight: Layout.minTouch)
        case .nothing:
            Text(addOn.nothingFound)
                .font(WanderFont.body)
                .foregroundStyle(.inkMuted)
                .frame(minHeight: Layout.minTouch)
        }
    }
}

/// Swipe to remove a stop, and the same as a VoiceOver action.
private struct RemoveAction: ViewModifier {
    let enabled: Bool
    let remove: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAction(named: "Remove from walk", remove)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Remove", role: .destructive, action: remove)
                }
        } else {
            content
        }
    }
}

/// §7 error and empty states for planning.
private struct FailureMessage: View {
    let failure: PlannerModel.Failure
    let retry: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.grid) {
            Text(message)
                .font(WanderFont.body)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
            switch failure {
            case .noLocation:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.textAction)
            case .offline, .other:
                Button("Try again", action: retry).buttonStyle(.textAction)
            case .noRoute:
                EmptyView()
            }
        }
    }

    private var message: String {
        switch failure {
        case .noLocation: "Wander needs your location to start from where you are."
        case .noRoute: "Couldn't find a walking route to this place. Try a different destination."
        case .offline: "No connection. Routes need internet; saved places still show."
        case .other: "Couldn't plan this walk. Try again in a moment."
        }
    }
}

enum Format {
    /// Whole minutes, rounded.
    static func minutes(_ seconds: TimeInterval) -> Int { Int((seconds / 60).rounded()) }

    /// "45 min" or "1 h 05".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(1, minutes(seconds))
        guard total >= 60 else { return "\(total) min" }
        return String(format: "%d h %02d", total / 60, total % 60)
    }

    /// "350 m" or "1.2 km".
    static func distance(_ metres: Double) -> String {
        if metres < 1000 { return "\(Int((metres / 10).rounded()) * 10) m" }
        return String(format: "%.1f km", metres / 1000)
    }
}

extension View {
    /// A list row that looks like plain sheet content: no separator, no background,
    /// 16 pt side margins, spacing instead of dividers (§10 Layout).
    func sheetRow(top: CGFloat = Layout.margin) -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: top, leading: Layout.margin, bottom: 0, trailing: Layout.margin))
    }
}
