import RouteEngine
import SwiftUI

/// Direct and Recommended (§10 Segmented control): the selected pill is
/// `surfaceRaised` with `wander` text, no heavy fills. Each option reads
/// "Direct · 22 min" and "Recommended · +14 min", wrapping to two lines when
/// the text is too wide. Until the plans are ready the options show their
/// names only, quietly, with no spinner.
struct ModeControl: View {
    @Binding var selection: Mode
    /// Direct's total walking time, once planned.
    var directTime: TimeInterval?
    /// The extra time the engine chose for Recommended, once planned.
    var recommendedExtra: TimeInterval?
    /// No stop is worth a detour, so Recommended is the same walk as Direct.
    var noDetourFit = false

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Layout.grid / 2) {
            ForEach(Mode.allCases, id: \.self) { mode in
                option(mode)
            }
        }
    }

    private func option(_ mode: Mode) -> some View {
        let selected = mode == selection
        let detail = detail(for: mode)
        return Button {
            if reduceMotion {
                selection = mode
            } else {
                withAnimation(.snappy(duration: 0.25)) { selection = mode }
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    Text(mode.title)
                        .font(WanderFont.body.weight(.semibold))
                    if let detail {
                        Text(" · \(detail)")
                            .font(WanderFont.body)
                            .monospacedDigit()
                    }
                }
                .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(WanderFont.body.weight(.semibold))
                    if let detail {
                        Text(detail)
                            .font(WanderFont.caption)
                            .monospacedDigit()
                    }
                }
            }
            .foregroundStyle(selected ? .wander : .inkMuted)
            .frame(maxWidth: .infinity, minHeight: Layout.primaryButtonHeight, alignment: .leading)
            .padding(.horizontal, Layout.grid * 1.5)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.surfaceRaised)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken(mode))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "22 min", "+14 min", "same as Direct", or nil while planning.
    private func detail(for mode: Mode) -> String? {
        switch mode {
        case .direct:
            return directTime.map { "\(Format.minutes($0)) min" }
        case .recommended:
            if noDetourFit { return "same as Direct" }
            return recommendedExtra.map { "+\(Format.minutes($0)) min" }
        }
    }

    private func spoken(_ mode: Mode) -> String {
        switch mode {
        case .direct:
            guard let directTime else { return mode.title }
            return "\(mode.title), \(Format.minutes(directTime)) minutes"
        case .recommended:
            if noDetourFit { return "\(mode.title), same as Direct" }
            guard let recommendedExtra else { return mode.title }
            return "\(mode.title), plus \(Format.minutes(recommendedExtra)) minutes"
        }
    }
}

#Preview {
    @Previewable @State var mode = Mode.recommended
    VStack(spacing: Layout.margin) {
        ModeControl(selection: $mode, directTime: 22 * 60, recommendedExtra: 14 * 60)
        ModeControl(selection: $mode, directTime: 22 * 60, noDetourFit: true)
        ModeControl(selection: $mode)
    }
    .padding(Layout.margin)
    .background(.surface)
}
