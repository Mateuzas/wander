import SwiftUI

/// A sheet card (place or dropped pin, FE-17): its body scrolls, its actions stay
/// pinned at the bottom on the sheet's surface, and it reports the sheet height it
/// needs to show everything, so the sheet can open at that height.
struct SheetCard<Content: View, Actions: View>: View {
    let hasActions: Bool
    /// The full height the card needs: body, pinned actions and the home-indicator area.
    var onHeight: ((CGFloat) -> Void)?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    @State private var contentHeight: CGFloat = 0
    @State private var actionsHeight: CGFloat = 0
    @State private var bottomInset: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    contentHeight = $0
                    report()
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasActions {
                VStack(alignment: .leading, spacing: Layout.grid) {
                    actions()
                }
                .padding(.horizontal, Layout.margin)
                .padding(.top, Layout.grid * 1.5)
                .padding(.bottom, Layout.grid)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surface)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    actionsHeight = $0
                    report()
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: {
            bottomInset = $0
            report()
        }
        .onChange(of: hasActions) { report() }
    }

    private func report() {
        onHeight?(contentHeight + (hasActions ? actionsHeight : 0) + bottomInset)
    }
}
