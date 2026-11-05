import CoreLocation
import SwiftUI

/// A point the user long-pressed on the map (FE-7). One at a time.
struct DroppedPin: Equatable {
    static let fallbackName = "Dropped pin"

    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    /// Filled in by reverse geocoding when it arrives; nil until then or on failure.
    var place: ReverseGeocoder.Place?

    var title: String { place?.name ?? Self.fallbackName }
    var subtitle: String { place?.detail ?? coordinateText }

    /// "51.75924, 19.45598": five decimals is about a metre.
    var coordinateText: String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    /// As picked from "Where to?". Recents show "Dropped pin" under the name,
    /// or the coordinates when there is no name either.
    var destination: Destination {
        Destination(name: title, subtitle: place == nil ? coordinateText : Self.fallbackName,
                    coordinate: coordinate)
    }

    static func == (lhs: DroppedPin, rhs: DroppedPin) -> Bool {
        lhs.id == rhs.id && lhs.place == rhs.place
    }
}

/// Sheet card for a dropped pin: name or coordinates, and "Directions".
struct DroppedPinCard: View {
    let pin: DroppedPin
    /// Plans a walk to the pin. Nil hides the button.
    var onDirections: (() -> Void)?
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.grid * 1.5) {
                HStack(alignment: .top, spacing: Layout.grid * 1.5) {
                    PinGlyph()
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: Layout.grid / 2) {
                        Text(pin.title)
                            .font(WanderFont.heading)
                            .foregroundStyle(.ink)
                            .contentTransition(.opacity)
                        Text(pin.subtitle)
                            .font(WanderFont.caption)
                            .foregroundStyle(.inkMuted)
                            .contentTransition(.opacity)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: pin.place)
                    Spacer(minLength: 0)
                }
                // Room for the close button.
                .padding(.trailing, Layout.minTouch)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(.isHeader)

                if let onDirections {
                    Button("Directions", action: onDirections)
                        .buttonStyle(.primary)
                        .accessibilityLabel("Directions to \(pin.title)")
                }
            }
            .padding(.horizontal, Layout.margin)
            .padding(.top, Layout.margin + Layout.grid)
            .padding(.bottom, Layout.margin)
        }
        .scrollBounceBehavior(.basedOnSize)
        .overlay(alignment: .topTrailing) { closeButton }
    }

    private var accessibilityLabel: String {
        pin.place == nil
            ? "Dropped pin, \(pin.subtitle)"
            : "Dropped pin, \(pin.title), \(pin.subtitle)"
    }

    /// Same as the place card's close button (no-photo variant).
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
        .accessibilityLabel("Remove pin")
        .padding(.top, Layout.margin + Layout.grid)
        .padding(.trailing, Layout.margin - 6)
    }
}

/// Bead-sized ink disc with a pin glyph, so the card lines up with the place card.
private struct PinGlyph: View {
    var body: some View {
        Image(systemName: "mappin")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.surface)
            .frame(width: Layout.bead, height: Layout.bead)
            .background(.ink, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The pin on the map: an ink head on a short stem, anchored at the stem's foot.
/// Ink rather than violet, so it doesn't compete with the route or the destination.
struct DroppedPinMarker: View {
    static let head: CGFloat = 28
    static let stem: CGFloat = 10
    static var height: CGFloat { head + stem }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "mappin")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.surface)
                .frame(width: Self.head, height: Self.head)
                .background(.ink, in: Circle())
                .overlay(Circle().strokeBorder(.surface, lineWidth: 2))
            Capsule()
                .fill(.ink)
                .frame(width: 3, height: Self.stem)
        }
        .frame(height: Self.height)
    }
}
