import MapKit
import SwiftUI

/// Home state (FE-17): a floating "Where to?" island at the top of the map. It
/// replaces PLAN.md §7.1's bottom sheet; tapping it opens `SearchPanel`.
struct SearchIsland: View {
    static let height: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Layout.grid * 1.5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.inkMuted)
                    .accessibilityHidden(true)
                Text("Where to?")
                    .font(WanderFont.body)
                    .foregroundStyle(.inkMuted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Layout.margin)
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .background(.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            // Same lift as the map controls, so it reads as floating over the map.
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Where to?")
        .accessibilityHint("Search for a place to walk to")
    }
}

/// The island expanded (FE-17): the search field with Cancel, suggestions while
/// typing; otherwise the "Nearby" food row (FE-19) and a compact island of the
/// last few searches (FE-20). Also the offline and location-denied messages, and
/// the logo and pitch when there is nothing else to show. The panel hangs from
/// the top, only as tall as its content; the map shows dimmed below it.
struct SearchPanel: View {
    let search: SearchService
    let recents: RecentDestinations
    let locationDenied: Bool
    var offline = false
    /// The places file's `generated` date, for the "Places updated" caption (FE-15).
    var placesGenerated = ""
    /// Focus the field (and raise the keyboard) when the panel opens.
    var focusOnAppear = true
    /// Cuisines of restaurants near the user, most common first (FE-19).
    var cuisinesNearby: () -> [String] = { [] }
    let onChoose: (Destination) -> Void
    /// A "Nearby" kind, and for a restaurant the cuisine (nil means any).
    var onFood: (FoodKind, String?) -> Void = { _, _ in }
    let onCancel: () -> Void

    /// Recents shown in the island (FE-20).
    static let recentCount = 3

    @FocusState private var fieldFocused: Bool
    @State private var resolving = false
    @State private var errorMessage: String?
    /// The restaurant cuisine step; nil shows the kinds.
    @State private var cuisines: [String]?

    private var isTyping: Bool { !search.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ZStack(alignment: .top) {
            // The map below, dimmed; a tap there closes the panel.
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: cancel)
                .accessibilityHidden(true)
            panel
        }
        .onChange(of: search.query) { errorMessage = nil }
        .task {
            guard focusOnAppear else { return }
            // Let the panel settle first, or the keyboard can drop the focus.
            try? await Task.sleep(for: .milliseconds(50))
            fieldFocused = true
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Layout.margin) {
            HStack(spacing: Layout.grid * 1.5) {
                searchField
                Button("Cancel", action: cancel)
                    .font(WanderFont.body.weight(.semibold))
                    .foregroundStyle(.wander)
                    .frame(minHeight: Layout.minTouch)
            }
            // As tall as the content; scrolls only when it doesn't fit (FE-20).
            ViewThatFits(in: .vertical) {
                panelContent
                ScrollView { panelContent }
                    .scrollDismissesKeyboard(.immediately)
            }
        }
        .padding(.horizontal, Layout.margin)
        .padding(.top, Layout.margin)
        .padding(.bottom, Layout.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous)
                .fill(Color.surface)
                .ignoresSafeArea(edges: [.top, .horizontal])
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: Layout.margin) {
            if offline {
                Text("No connection. Routes need internet; saved places still show.")
                    .font(WanderFont.body)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if locationDenied {
                LocationDeniedMessage()
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(WanderFont.body)
                    .foregroundStyle(.ink)
            }
            if isTyping {
                suggestions
            } else {
                if let cuisines {
                    cuisineStep(cuisines)
                } else {
                    nearbyRow
                }
                if !recents.items.isEmpty {
                    recentIsland
                } else if !offline, !locationDenied, errorMessage == nil {
                    welcome
                }
                dataFooter
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pieces

    /// First run, nothing searched yet: the brand logo and the pitch (docs/BRAND.md).
    private var welcome: some View {
        VStack(alignment: .leading, spacing: Layout.grid) {
            Image("WanderLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 32)
                .accessibilityLabel("Wander")
            Text("Get where you're going, but walk past the good stuff.")
                .font(WanderFont.body)
                .foregroundStyle(.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Layout.grid)
    }

    /// Bottom of the empty state (FE-15): how fresh the places are, and the data credit.
    private var dataFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let updated = DataFeed.relativeDate(placesGenerated) {
                Text("Places updated \(updated)")
            }
            Text("© OpenStreetMap contributors · Wikimedia")
        }
        .font(WanderFont.caption)
        .foregroundStyle(.inkMuted)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var searchField: some View {
        HStack(spacing: Layout.grid) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.inkMuted)
                .accessibilityHidden(true)
            TextField("Where to?", text: Binding(get: { search.query }, set: { search.query = $0 }))
                .font(WanderFont.body)
                .foregroundStyle(.ink)
                .focused($fieldFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit(submitText)
            if resolving {
                ProgressView()
            } else if isTyping {
                Button {
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.inkMuted)
                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, Layout.margin)
        .frame(minHeight: SearchIsland.height)
        .background(.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var suggestions: some View {
        if search.suggestions.isEmpty {
            Text("No places match yet. Keep typing or check the spelling.")
                .font(WanderFont.body)
                .foregroundStyle(.inkMuted)
        } else {
            VStack(alignment: .leading, spacing: Layout.grid) {
                ForEach(search.suggestions) { suggestion in
                    PlaceRow(systemImage: "mappin", title: suggestion.title, subtitle: suggestion.subtitle) {
                        resolve { try await search.place(for: suggestion) }
                    }
                }
            }
        }
    }

    /// The last few searches on one raised island, one line each (FE-20).
    private var recentIsland: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(recents.items.prefix(Self.recentCount)) { place in
                PlaceRow(systemImage: "clock", title: place.name, subtitle: place.subtitle, compact: true) {
                    finish(with: place)
                }
            }
        }
        .padding(.horizontal, Layout.margin)
        .padding(.vertical, Layout.grid / 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent")
    }

    // MARK: - Nearby (FE-19)

    /// "Nearby" and the four kinds on one line; wraps when the text is large.
    private var nearbyRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Layout.grid) {
                nearbyLabel
                HStack(spacing: Layout.grid / 2) { kindChips }
            }
            VStack(alignment: .leading, spacing: Layout.grid / 2) {
                nearbyLabel
                FlowRow(spacing: Layout.grid / 2, lineSpacing: Layout.grid / 2) { kindChips }
            }
        }
    }

    private var nearbyLabel: some View {
        Text("Nearby")
            .font(WanderFont.caption)
            .foregroundStyle(.inkMuted)
            .lineLimit(1)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var kindChips: some View {
        ForEach(FoodKind.allCases) { kind in
            FoodChip(title: kind.title, glyph: kind.glyph) { pick(kind) }
                .accessibilityLabel("\(kind.title) nearby")
                .accessibilityHint(kind == .restaurant ? "Choose a cuisine" : "Shows the closest open place")
        }
    }

    /// Restaurant → a cuisine, or Any.
    private func cuisineStep(_ cuisines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Layout.grid / 2) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { self.cuisines = nil }
            } label: {
                HStack(spacing: Layout.grid / 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Restaurant")
                        .font(WanderFont.caption)
                }
                .foregroundStyle(.inkMuted)
                .frame(minHeight: Layout.minTouch)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to nearby kinds")
            FlowRow(spacing: Layout.grid / 2, lineSpacing: Layout.grid / 2) {
                FoodChip(title: "Any", glyph: FoodKind.restaurant.glyph) { food(.restaurant, nil) }
                    .accessibilityLabel("Any restaurant")
                ForEach(cuisines, id: \.self) { cuisine in
                    FoodChip(title: FoodPick.cuisineTitle(cuisine), glyph: nil) { food(.restaurant, cuisine) }
                }
            }
        }
    }

    private func pick(_ kind: FoodKind) {
        guard kind == .restaurant else { return food(kind, nil) }
        let nearby = cuisinesNearby()
        // No cuisines to offer (no location, or none tagged): straight to any restaurant.
        guard !nearby.isEmpty else { return food(.restaurant, nil) }
        withAnimation(.snappy(duration: 0.2)) { cuisines = nearby }
    }

    private func food(_ kind: FoodKind, _ cuisine: String?) {
        fieldFocused = false
        search.clear()
        cuisines = nil
        onFood(kind, cuisine)
    }

    // MARK: - Actions

    private func submitText() {
        let text = search.query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let first = search.suggestions.first {
            resolve { try await search.place(for: first) }
        } else {
            resolve { try await search.place(forText: text) }
        }
    }

    private func resolve(_ lookup: @escaping () async throws -> MKMapItem) {
        resolving = true
        errorMessage = nil
        Task {
            defer { resolving = false }
            do {
                finish(with: Destination(try await lookup()))
            } catch {
                errorMessage = "Couldn't find that place. Try a different search."
            }
        }
    }

    private func finish(with place: Destination) {
        fieldFocused = false
        search.clear()
        onChoose(place)
    }

    private func cancel() {
        fieldFocused = false
        search.clear()
        errorMessage = nil
        onCancel()
    }
}

/// One tappable place: glyph, name, optional subtitle. Separated by spacing, not dividers.
private struct PlaceRow: View {
    let systemImage: String
    let title: String
    let subtitle: String
    /// One line each for the title and subtitle (the recents island, FE-20).
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.grid * 1.5) {
                Image(systemName: systemImage)
                    .foregroundStyle(.inkMuted)
                    .frame(width: Layout.bead)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(WanderFont.body)
                        .foregroundStyle(.ink)
                        .lineLimit(compact ? 1 : nil)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(WanderFont.caption)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(compact ? 1 : nil)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, compact ? Layout.grid * 0.75 : 0)
            .frame(minHeight: Layout.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small raised chip in the "Nearby" row and the cuisine step (FE-19).
private struct FoodChip: View {
    let title: String
    /// The kind's bead glyph, in the food colour; nil for a cuisine.
    let glyph: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Layout.grid / 2) {
                if let glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.food)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(WanderFont.body)
                    .foregroundStyle(.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, Layout.grid)
            .frame(minHeight: Layout.minTouch)
            .background(.surfaceRaised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// PLAN.md §7, location denied. Shown in the search panel and the food card; the map falls back to the city.
struct LocationDeniedMessage: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.grid) {
            Text("Wander needs your location to start from where you are. You can still pick a start point on the map.")
                .font(WanderFont.body)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(WanderFont.body.weight(.semibold))
            .foregroundStyle(.wander)
            .frame(minHeight: Layout.minTouch)
        }
    }
}
