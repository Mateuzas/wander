import MapKit
import RouteEngine
import SwiftUI

/// Shown in the sheet when a bead on the map is tapped: name, category, reason,
/// and an add or remove action when there is a plan.
struct POIDetail: View {
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
    let onClose: () -> Void

    @State private var adding = false
    @State private var addMessage: String?
    @State private var connectivity = Connectivity()
    /// The matching Apple Maps place; nil until found, and stays nil if unsure.
    @State private var place: MKMapItem?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.grid * 1.5) {
            if connectivity.isOnline, let file = poi.commonsImage {
                CommonsPhotoView(fileName: file)
            }
            HStack(alignment: .top, spacing: Layout.grid * 1.5) {
                Bead(category: poi.category)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: Layout.grid / 2) {
                    Text(poi.name)
                        .font(WanderFont.heading)
                        .foregroundStyle(.ink)
                    Text(poi.category.spokenName)
                        .font(WanderFont.caption)
                        .foregroundStyle(.inkMuted)
                }
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
            .accessibilityElement(children: .contain)

            if !poi.reason.isEmpty {
                Text(poi.reason)
                    .font(WanderFont.body)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            placeInfo
            actionView
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.margin)
        .padding(.top, Layout.margin + Layout.grid)
        .onChange(of: poi.id) { addMessage = nil }
        .task(id: poi.id) { await loadPlaceInfo() }
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
