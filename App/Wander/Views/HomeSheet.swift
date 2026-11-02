import MapKit
import SwiftUI

/// Bottom sheet on the home screen: "Where to?" search, suggestions while typing,
/// recent destinations otherwise, and the location-denied message (PLAN.md §7).
struct HomeSheet: View {
    let search: SearchService
    let recents: RecentDestinations
    let locationDenied: Bool
    @Binding var detent: PresentationDetent
    let onChoose: (Destination) -> Void

    @FocusState private var fieldFocused: Bool
    @State private var resolving = false
    @State private var errorMessage: String?

    private var isTyping: Bool { !search.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.margin) {
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.margin) {
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
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .padding(.horizontal, Layout.margin)
        .padding(.top, Layout.margin + Layout.grid)
        .onChange(of: fieldFocused) { _, focused in
            if focused { detent = .large }
        }
        .onChange(of: search.query) { errorMessage = nil }
    }

    // MARK: - Pieces

    private var searchField: some View {
        HStack(spacing: Layout.grid) {
            Image(systemName: "magnifyingglass")
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
        .padding(.leading, Layout.grid * 1.5)
        .frame(minHeight: Layout.minTouch)
        .background(.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

/// PLAN.md §7, location denied. Shown in the sheet; the map falls back to the city.
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
