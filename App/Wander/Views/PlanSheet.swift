import RouteEngine
import SwiftUI

/// Plan state (PLAN.md §7.2) with the highlight list below it (§7.3, large detent).
struct PlanSheet: View {
    @Bindable var planner: PlannerModel
    let destination: Destination
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
            ModeControl(selection: $planner.mode).sheetRow()
            summary.sheetRow(top: Layout.grid)
            actions.sheetRow(top: Layout.grid)
            preferences.sheetRow(top: Layout.grid)
            highlightList
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

    // MARK: - Header and summary

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(destination.name)
                .font(WanderFont.title)
                .foregroundStyle(.ink)
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
            .frame(minHeight: 84, alignment: .leading)
        case .failed(let failure):
            FailureMessage(failure: failure, retry: planner.retry)
        case .ready:
            if let plan = planner.plan {
                PlanSummary(plan: plan, mode: planner.mode)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: Layout.grid) {
            Divider().padding(.bottom, Layout.grid)
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
                    if let plan = planner.plan { HandOff.openAppleMaps(for: plan, destinationName: destination.name) }
                }
                .buttonStyle(.textAction)
                .disabled(planner.plan == nil)
                if planner.plan?.waypoints.isEmpty == false {
                    Text("Opens the first stop")
                        .font(WanderFont.caption)
                        .foregroundStyle(.inkMuted)
                }
            }
        }
    }

    // MARK: - Interests and profile

    private var preferences: some View {
        VStack(alignment: .leading, spacing: Layout.grid) {
            HStack(spacing: Layout.grid) {
                ForEach(POICategory.allCases, id: \.self) { category in
                    InterestChip(category: category, isOn: Binding(
                        get: { planner.interests.contains(category) },
                        set: { on in
                            if on { planner.interests.insert(category) } else { planner.interests.remove(category) }
                        }))
                }
            }
            HStack {
                Text("Route style")
                    .font(WanderFont.body)
                    .foregroundStyle(.ink)
                Spacer()
                Menu {
                    Picker("Route style", selection: $planner.profile) {
                        ForEach(WeightPreset.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack(spacing: Layout.grid / 2) {
                        Text(planner.profile.title)
                            .font(WanderFont.body)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.wander)
                    .frame(minHeight: Layout.minTouch)
                }
            }
        }
    }

    // MARK: - Highlights

    @ViewBuilder
    private var highlightList: some View {
        if let plan = planner.plan, !plan.highlights.isEmpty {
            Text("Highlights")
                .font(WanderFont.heading)
                .foregroundStyle(.ink)
                .accessibilityAddTraits(.isHeader)
                .sheetRow(top: Layout.margin)
            ForEach(plan.highlights, id: \.poi.id) { highlight in
                HighlightRow(
                    category: highlight.poi.category,
                    name: highlight.poi.name,
                    reason: highlight.poi.reason.isEmpty ? nil : highlight.poi.reason,
                    distance: Format.distance(highlight.distanceAlongRoute))
                    .onTapGesture { onFocus(highlight.poi) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Remove from walk") { planner.remove(highlight.poi) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Remove", role: .destructive) { planner.remove(highlight.poi) }
                    }
                    .sheetRow(top: Layout.grid / 2)
            }
        }
    }
}

// MARK: - Pieces

/// "36 min" (Stat), then "12 more than direct" and "4 highlights" (§10 Plan state).
private struct PlanSummary: View {
    let plan: WanderPlan
    let mode: Mode

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.grid / 2) {
            Text("\(Format.minutes(plan.totalTime)) min")
                .font(WanderFont.stat)
                .foregroundStyle(.ink)
            Text(extraLine)
                .font(WanderFont.body)
                .foregroundStyle(.inkMuted)
            Text(highlightLine)
                .font(WanderFont.body)
                .foregroundStyle(.inkMuted)
            if plan.noDetourFit {
                Text(mode == .explorer
                     ? "Nothing interesting fits this time."
                     : "Nothing interesting fits this time. Try Explorer for a longer detour.")
                    .font(WanderFont.body)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Layout.grid / 2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var extraLine: String {
        let extra = Format.minutes(plan.extraTime)
        if mode == .direct { return "Fastest route" }
        return extra < 1 ? "Same as direct" : "\(extra) more than direct"
    }

    private var highlightLine: String {
        switch plan.highlights.count {
        case 0: "No highlights on this route"
        case 1: "1 highlight"
        case let n: "\(n) highlights"
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
