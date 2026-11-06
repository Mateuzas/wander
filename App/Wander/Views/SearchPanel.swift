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
/// typing, recent destinations otherwise, the offline and location-denied
/// messages, and the logo and pitch when there is nothing else to show.
struct SearchPanel: View {
    let search: SearchService
    let recents: RecentDestinations
    let locationDenied: Bool
    var offline = false
    /// The places file's `generated` date, for the "Places updated" caption (FE-15).
    var placesGenerated = ""
    /// Focus the field (and raise the keyboard) when the panel opens.
    var focusOnAppear = true
    let onChoose: (Destination) -> Void
    let onCancel: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var resolving = false
    @State private var errorMessage: String?

    private var isTyping: Bool { !search.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.margin) {
            HStack(spacing: Layout.grid * 1.5) {
                searchField
                Button("Cancel", action: cancel)
                    .font(WanderFont.body.weight(.semibold))
                    .foregroundStyle(.wander)
                    .frame(minHeight: Layout.minTouch)
            }
            ScrollView {
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
                    } else if !recents.items.isEmpty {
                        recentList
                    } else if !offline, !locationDenied, errorMessage == nil {
                        welcome
                    }
                    if !isTyping {
                        dataFooter
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Layout.margin)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .padding(.horizontal, Layout.margin)
        .padding(.top, Layout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.surface.ignoresSafeArea())
        .onChange(of: search.query) { errorMessage = nil }
        .task {
            guard focusOnAppear else { return }
            // Let the panel settle first, or the keyboard can drop the focus.
            try? await Task.sleep(for: .milliseconds(50))
            fieldFocused = true
        }
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
        .padding(.top, Layout.grid * 2)
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

    private var recentList: some View {
        VStack(alignment: .leading, spacing: Layout.grid) {
            Text("Recent")
                .font(WanderFont.heading)
                .foregroundStyle(.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(recents.items) { place in
                PlaceRow(systemImage: "clock", title: place.name, subtitle: place.subtitle) {
                    finish(with: place)
                }
            }
        }
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
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(WanderFont.caption)
                            .foregroundStyle(.inkMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Layout.minTouch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// PLAN.md §7, location denied. Shown in the search panel; the map falls back to the city.
private struct LocationDeniedMessage: View {
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
