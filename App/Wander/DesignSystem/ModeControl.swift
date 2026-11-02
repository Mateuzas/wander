import RouteEngine
import SwiftUI

/// Direct / Relaxed / Explorer with their extra minutes (§10 Segmented control):
/// the selected pill is `surfaceRaised` with `wander` text, no heavy fills.
struct ModeControl: View {
    @Binding var selection: Mode

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Layout.grid / 2) {
            ForEach(Mode.allCases, id: \.self) { mode in
                let selected = mode == selection
                Button {
                    if reduceMotion {
                        selection = mode
                    } else {
                        withAnimation(.snappy(duration: 0.25)) { selection = mode }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title)
                            .font(WanderFont.body.weight(.semibold))
                        Text(mode.budgetLabel)
                            .font(WanderFont.caption)
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
                .accessibilityLabel("\(mode.title), plus \(mode.extraMinutes) minutes")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

#Preview {
    @Previewable @State var mode = Mode.relaxed
    ModeControl(selection: $mode)
        .padding(Layout.margin)
        .background(.surface)
}
