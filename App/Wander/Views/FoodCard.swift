import RouteEngine
import SwiftUI

/// The food-nearby result in the sheet (FE-19): the usual place card with
/// "N min walk", Directions and "Next option"; "Nothing open nearby" with the
/// nearest closed place; or a short status while it looks.
struct FoodCard: View {
    let finder: FoodFinder
    let request: FoodFinder.Request
    let onDirections: (POI) -> Void
    let onClose: () -> Void
    var onHeight: ((CGFloat) -> Void)?

    var body: some View {
        switch finder.phase {
        case .found(let result):
            POIDetail(
                poi: result.poi, action: .none, onAdd: { .failed }, onRemove: {},
                onDirections: { onDirections(result.poi) },
                onClose: onClose,
                subtitle: "\(kindLine(for: result.poi)) · \(result.minutes) min walk",
                onNext: finder.hasNext ? { finder.next() } : nil,
                onHeight: onHeight)
            .id(result.poi.id)
            .transition(.opacity)
        case .nothingOpen(let closed?):
            POIDetail(
                poi: closed, action: .none, onAdd: { .failed }, onRemove: {},
                onDirections: { onDirections(closed) },
                onClose: onClose,
                subtitle: closedLine(for: closed),
                notice: "Nothing open nearby",
                onHeight: onHeight)
        case .nothingOpen(nil):
            status(heading: "Nothing open nearby") {
                Text("No \(request.cuisine == nil ? request.title.lowercased() : request.title) places within a short walk.")
                    .font(WanderFont.body)
                    .foregroundStyle(.inkMuted)
            }
        case .searching:
            status(heading: request.title) {
                progress("Looking for the closest open place…")
            }
        case .locating:
            status(heading: request.title) {
                progress("Waiting for your location…")
            }
        case .noLocation:
            status(heading: request.title) {
                LocationDeniedMessage()
            }
        }
    }

    /// The kind, or for a restaurant the chosen cuisine, else the place's own.
    private func kindLine(for poi: POI) -> String {
        if request.cuisine == nil, request.kind == .restaurant, let own = poi.cuisine?.first {
            return FoodPick.cuisineTitle(own)
        }
        return request.title
    }

    private func closedLine(for poi: POI) -> String {
        guard let hours = poi.openingHours, !hours.isEmpty else { return "Closed now" }
        return "Closed now · Hours \(hours)"
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Layout.grid) {
            ProgressView()
            Text(text)
                .font(WanderFont.body)
                .foregroundStyle(.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }

    private func status<Content: View>(heading: String, @ViewBuilder content: () -> Content) -> some View {
        let content = content()
        return SheetCard(hasActions: false, onHeight: onHeight) {
            VStack(alignment: .leading, spacing: Layout.grid * 1.5) {
                Text(heading)
                    .font(WanderFont.title)
                    .foregroundStyle(.ink)
                    .padding(.trailing, Layout.minTouch)
                    .accessibilityAddTraits(.isHeader)
                content
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.margin)
            .padding(.top, Layout.margin + Layout.grid)
            .padding(.bottom, Layout.grid)
        } actions: {
            EmptyView()
        }
        .overlay(alignment: .topTrailing) {
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
            .padding(.top, Layout.margin)
            .padding(.trailing, Layout.margin - 6)
        }
    }
}
