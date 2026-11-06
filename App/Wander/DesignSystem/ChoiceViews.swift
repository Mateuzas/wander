import RouteEngine
import SwiftUI

/// A multi-select row for the walk's kinds (FE-23): a bead-like glyph, the title and
/// a short line, and a check. Selected rows sit on `surfaceRaised` with a `wander`
/// check (§10 selection); the others are quiet, with no fill.
struct KindRow: View {
    let kind: DeckKind
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Layout.grid * 1.5) {
                Circle()
                    .fill(kind.category?.color ?? Color.wander)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: kind.glyph)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(WanderFont.heading)
                        .foregroundStyle(.ink)
                    Text(kind.detail)
                        .font(WanderFont.caption)
                        .foregroundStyle(.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Layout.grid)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isOn ? Color.wander : Color.inkMuted.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Layout.grid * 1.5)
            .padding(.vertical, Layout.grid * 1.25)
            .frame(maxWidth: .infinity, minHeight: Layout.minTouch + 12, alignment: .leading)
            .background(isOn ? Color.surfaceRaised : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// A single-select row of pills (§10 segmented control): the selected pill is
/// `surfaceRaised` with `wander` text, no heavy fills.
struct PillPicker<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var spoken: (Value) -> String = { _ in "" }
    /// VoiceOver name for the whole control.
    let label: String

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Layout.grid / 2) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(selected ? WanderFont.body.weight(.semibold) : WanderFont.body)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.wander : Color.inkMuted)
                        .padding(.horizontal, Layout.margin)
                        .frame(maxWidth: .infinity, minHeight: Layout.minTouch)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.surfaceRaised)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Layout.grid / 2)
        .background(Color.inkMuted.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken(selection))
        .accessibilityAdjustableAction { direction in
            guard let index = options.firstIndex(of: selection) else { return }
            switch direction {
            case .increment where index + 1 < options.count: selection = options[index + 1]
            case .decrement where index > 0: selection = options[index - 1]
            default: break
            }
        }
    }
}

/// The ✕ in a sheet's top corner: a 44 pt target with a small material disc.
struct SheetCloseButton: View {
    var label = "Close"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.ink)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .frame(width: Layout.minTouch, height: Layout.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
