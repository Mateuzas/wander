import MapKit
import RouteEngine
import SwiftUI

/// Shown in the sheet when a bead on the map is tapped: name, category, reason,
/// "Directions" (the card's one primary action), and an add or remove action
/// when there is a plan. During a walk: no Directions or add/remove, only Skip.
struct POIDetail: View {
    /// Skip for a walk highlight (FE-10).
    enum WalkSkip {
        /// Still ahead: Skip stops its "Up ahead" card.
        case available(() -> Void)
        case skipped
    }

    enum Action: Equatable {
        /// No plan, so nothing to add to.
        case none
        case remove
        case add
        /// Explains why it can't be added.
        case unavailable(String)
    }

    let poi: POI
    let action: Action
    let onAdd: () async -> PlannerModel.AddResult
    let onRemove: () -> Void
    /// Plans a walk to this place, as if picked from "Where to?". Nil hides the button (while walking).
    var onDirections: (() -> Void)?
    /// Set during a walk for one of its highlights; nil hides it.
    var walkSkip: WalkSkip?
    let onClose: () -> Void
    /// Replaces the category line (food nearby, FE-19: "Coffee · 6 min walk").
    var subtitle: String?
    /// A line above the card (FE-19: "Nothing open nearby").
    var notice: String?
    /// "Next option" under Directions (FE-19); nil hides it.
    var onNext: (() -> Void)?
    /// The sheet height the card needs to show everything (FE-17).
    var onHeight: ((CGFloat) -> Void)?
    /// A square thumbnail beside the name instead of the hero photo (food nearby, FE-22).
    var compact = false

    @State private var adding = false
    @State private var addMessage: String?
    @State private var connectivity = Connectivity()
    /// The matching Apple Maps place; nil until found, and stays nil if unsure.
    @State private var place: MKMapItem?
    @State private var photoFailed = false

    /// A photo (or its placeholder) leads the card; the close button floats over it.
    private var hasPhoto: Bool { showsPhotoView && !photoFailed }

    /// The hero view is in the card: the place's own photo (tried even offline, it may be
    /// cached), or Commons photos when online. Not with a notice or in the compact layout.
    private var showsPhotoView: Bool {
        guard notice == nil, !compact else { return false }
        return poi.photo != nil
            || connectivity.isOnline && (poi.commonsImage != nil || poi.commonsCategory != nil)
    }

    /// Directions, add/remove and Skip: pinned at the bottom, always on screen.
    private var hasActions: Bool {
        onDirections != nil || onNext != nil || action != .none || walkSkip != nil
    }

    /// The small line under the pitch: the caller's subtitle, else the reason (the type)
    /// when the hook took the pitch's place, else the category.
    private var captionLine: String {
        if let subtitle { return subtitle }
        if poi.hookLine != nil, !poi.reason.isEmpty { return poi.reason }
        return poi.category.spokenName
    }

    var body: some View {
        SheetCard(hasActions: hasActions, onHeight: onHeight) {
            VStack(alignment: .leading, spacing: Layout.grid * 1.5) {
                if let notice {
                    Text(notice)
                        .font(WanderFont.title)
                        .foregroundStyle(.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.trailing, Layout.minTouch)
                        .accessibilityAddTraits(.isHeader)
                }
                if showsPhotoView {
                    PlacePhotoView(lead: poi.photo, fileName: poi.commonsImage,
                                   category: poi.commonsCategory, glyph: poi.glyph,
                                   failed: $photoFailed)
                }

                if compact { compactHeader } else { header }

                descriptionView
                placeInfo
            }
            .padding(.horizontal, Layout.margin)
            .padding(.top, Layout.margin + Layout.grid)
            .padding(.bottom, Layout.grid)
        } actions: {
            if let onDirections {
                Button("Directions", action: onDirections)
                    .buttonStyle(.primary)
                    .accessibilityLabel("Directions to \(poi.name)")
            }
            if let onNext {
                Button("Next option", action: onNext)
                    .buttonStyle(.textAction)
                    .accessibilityHint("Shows the next closest place")
            }
            actionView
            walkSkipView
        }
        .overlay(alignment: .topTrailing) { closeButton }
        .onChange(of: poi.id) { addMessage = nil }
        .task(id: poi.id) { await loadPlaceInfo() }
    }

    // MARK: - Name, hook and type (FE-22)

    /// Under the hero: the name, the hook as the card's headline line, the type as a caption.
    /// Without a hook (older data) the reason takes the pitch line, as before.
    private var header: some View {
        VStack(alignment: .leading, spacing: Layout.grid) {
            HStack(alignment: .firstTextBaseline, spacing: Layout.grid) {
                Bead(category: poi.category, glyph: poi.glyph, isPopular: poi.mapTier == 1)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 7 }
                Text(poi.name)
                    .font(WanderFont.title)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            // Room for the close button when there is no photo to float it over.
            .padding(.trailing, hasPhoto || notice != nil ? 0 : Layout.minTouch)
            pitchText
            Text(captionLine)
                .font(WanderFont.caption)
                .foregroundStyle(.inkMuted)
        }
        .accessibilityElement(children: .contain)
    }

    /// Food nearby: a square photo beside the name, the pitch and "Coffee · 6 min walk".
    private var compactHeader: some View {
        HStack(alignment: .top, spacing: Layout.grid * 1.5) {
            PlaceThumbnail(poi: poi, size: 72)
            VStack(alignment: .leading, spacing: Layout.grid / 2) {
                Text(poi.name)
                    .font(WanderFont.heading)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let pitch = poi.pitch {
                    Text(pitch)
                        .font(WanderFont.body)
                        .foregroundStyle(.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(captionLine)
                    .font(WanderFont.caption)
                    .foregroundStyle(.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, notice != nil ? 0 : Layout.minTouch)
        .accessibilityElement(children: .contain)
    }

    /// The hook in the emphasised body style, or the reason in plain body for older data.
    @ViewBuilder
    private var pitchText: some View {
        if let hook = poi.hookLine {
            Text(hook)
                .font(WanderFont.hook)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
        } else if !poi.reason.isEmpty {
            Text(poi.reason)
                .font(WanderFont.body)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 44 × 44 pt hit area with a small material disc, readable on any photo.
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.ink)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .frame(width: Layout.minTouch, height: Layout.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        // Sits inside the photo's corner, or in the card's corner without one.
        .padding(.top, Layout.margin + Layout.grid - (hasPhoto ? 2 : 0))
        .padding(.trailing, hasPhoto ? Layout.grid : Layout.margin - 6)
    }

    // MARK: - Description (FE-17)

    /// The longer description from the data, under the hook. Wikipedia text is
    /// CC BY-SA, so it carries a "From Wikipedia" link to the article. Nothing
    /// shows when the place has no description.
    @ViewBuilder
    private var descriptionView: some View {
        if let text = poi.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            VStack(alignment: .leading, spacing: Layout.grid / 2) {
                Text(text)
                    .font(WanderFont.body)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if poi.descriptionSource == "wikipedia",
                   let link = poi.descriptionUrl.flatMap(URL.init(string:)) {
                    Link(destination: link) {
                        Text("From Wikipedia")
                            .font(WanderFont.caption)
                            .foregroundStyle(.inkMuted)
                            .underline()
                            .frame(minHeight: Layout.minTouch, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("From Wikipedia")
                    .accessibilityHint("Opens the article in Safari")
                }
            }
        }
    }

    // MARK: - Photos and reviews

    private func loadPlaceInfo() async {
        place = nil
        let match = await PlaceInfoService.shared.place(for: poi)
        guard !Task.isCancelled else { return }
        place = match
    }

    /// Nothing is shown while looking up, offline, or on iOS 17. Never a spinner.
    @ViewBuilder
    private var placeInfo: some View {
        if connectivity.isOnline, let place {
            if #available(iOS 18, *) {
                PlaceCardRow(item: place, placeName: poi.name)
            }
        }
    }

    @ViewBuilder
    private var walkSkipView: some View {
        switch walkSkip {
        case .available(let skip):
            Button("Skip", action: skip)
                .buttonStyle(.textAction)
                .accessibilityLabel("Skip \(poi.name)")
                .accessibilityHint("No Up ahead card for this place")
        case .skipped:
            Text("Skipped. No Up ahead card for this one.")
                .font(WanderFont.body)
                .foregroundStyle(.inkMuted)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch action {
        case .none:
            EmptyView()
        case .remove:
            Button("Remove from walk", action: onRemove).buttonStyle(.textAction)
        case .add:
            if let addMessage {
                Text(addMessage)
                    .font(WanderFont.body)
                    .foregroundStyle(.inkMuted)
            } else {
                HStack(spacing: Layout.grid) {
                    Button("Add to walk") {
                        adding = true
                        Task {
                            let result = await onAdd()
                            adding = false
                            switch result {
                            case .added: break
                            case .doesntFit: addMessage = "Doesn't fit this walk once real streets are counted."
                            case .failed: addMessage = "Couldn't add this stop. Try again in a moment."
                            }
                        }
                    }
                    .buttonStyle(.textAction)
                    .disabled(adding)
                    if adding { ProgressView() }
                }
            }
        case .unavailable(let reason):
            Text(reason)
                .font(WanderFont.body)
                .foregroundStyle(.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Photos & reviews": opens Apple's place card (photos, ratings, hours).
@available(iOS 18, *)
private struct PlaceCardRow: View {
    let item: MKMapItem
    let placeName: String
    @State private var showCard = false

    var body: some View {
        Button { showCard = true } label: {
            HStack(spacing: Layout.grid) {
                Image(systemName: "photo.on.rectangle")
                Text("Photos & reviews")
                    .font(WanderFont.body.weight(.semibold))
                Spacer(minLength: Layout.grid)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.inkMuted)
            }
            .foregroundStyle(.wander)
            .padding(.horizontal, Layout.grid * 1.5)
            .frame(maxWidth: .infinity, minHeight: Layout.minTouch, alignment: .leading)
            .background(.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photos and reviews for \(placeName)")
        .accessibilityHint("Opens the Apple Maps place card")
        .mapItemDetailSheet(isPresented: $showCard, item: item, displaysMap: false)
    }
}
