import SwiftUI

/// One single-select row of moods (FE-18). Chips wrap onto a second line rather
/// than scrolling. The selected chip uses the §10 selected style: `surfaceRaised`
/// with `wander` text; the others are quiet, with no fill. VoiceOver reads the
/// row as one adjustable control: "Mood, Best of, selected, 1 of 5".
struct MoodRow: View {
    @Binding var selection: Mood

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let moods = Mood.allCases

    var body: some View {
        FlowRow(spacing: Layout.grid / 2, lineSpacing: Layout.grid / 2) {
            ForEach(moods) { chip($0) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mood")
        .accessibilityValue(spokenValue)
        .accessibilityAdjustableAction { direction in
            guard let index = moods.firstIndex(of: selection) else { return }
            switch direction {
            case .increment where index + 1 < moods.count: select(moods[index + 1])
            case .decrement where index > 0: select(moods[index - 1])
            default: break
            }
        }
    }

    private func chip(_ mood: Mood) -> some View {
        let selected = mood == selection
        return Button { select(mood) } label: {
            HStack(spacing: Layout.grid * 0.75) {
                Image(systemName: mood.symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(mood.title)
                    .font(selected ? WanderFont.body.weight(.semibold) : WanderFont.body)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.wander : Color.inkMuted)
            .padding(.horizontal, Layout.grid * 1.5)
            .frame(minHeight: Layout.minTouch)
            .background {
                if selected {
                    Capsule()
                        .fill(.surfaceRaised)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func select(_ mood: Mood) {
        guard mood != selection else { return }
        if reduceMotion {
            selection = mood
        } else {
            withAnimation(.snappy(duration: 0.25)) { selection = mood }
        }
    }

    private var spokenValue: String {
        let position = (moods.firstIndex(of: selection) ?? 0) + 1
        return "\(selection.title), selected, \(position) of \(moods.count)"
    }
}

/// Lays children out left to right, starting a new line when the next one
/// doesn't fit. Leading-aligned (§10 Layout).
struct FlowRow: SwiftUI.Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let fitted = CGSize(width: min(size.width, bounds.width), height: size.height)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - fitted.height) / 2),
                                      proposal: ProposedViewSize(fitted))
                x += fitted.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let itemWidth = min(size.width, maxWidth)
            let needed = row.indices.isEmpty ? itemWidth : row.width + spacing + itemWidth
            if !row.indices.isEmpty && needed > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? itemWidth : row.width + spacing + itemWidth
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

#Preview {
    @Previewable @State var mood = Mood.bestOf
    MoodRow(selection: $mood)
        .padding(Layout.margin)
        .background(.surface)
}
