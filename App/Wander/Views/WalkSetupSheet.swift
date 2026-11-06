import RouteEngine
import SwiftUI

/// Steps 1 and 2 of a swipe walk (ADR 016) in the sheet over the map: what to see,
/// then how long and where. The map above draws the area (`AreaOverlay` in MapScreen).
struct WalkSetupSheet: View {
    @Bindable var session: SwipeSession
    let locationDenied: Bool
    /// "Somewhere specific": opens "Where to?" for the destination.
    let onPickDestination: () -> Void
    /// Moves the start back to the user after a long press moved it; nil hides it.
    var onUseMyLocation: (() -> Void)?
    let onStartSwiping: () -> Void
    let onClose: () -> Void
    /// The sheet height the step needs (FE-17).
    var onHeight: ((CGFloat) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch session.step {
            case .kinds: kindsStep
            case .area, .deck: areaStep
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: session.step)
    }

    // MARK: - Step 1: kinds

    private var kindsStep: some View {
        SheetCard(hasActions: true, onHeight: onHeight) {
            VStack(alignment: .leading, spacing: Layout.grid * 1.5) {
                Text("What do you want to see?")
                    .font(WanderFont.title)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, Layout.minTouch)
                    .accessibilityAddTraits(.isHeader)
                Text("Pick one or more. You'll swipe through places of these kinds.")
                    .font(WanderFont.body)
                    .foregroundStyle(.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: Layout.grid / 2) {
                    ForEach(DeckKind.allCases, id: \.self) { kind in
                        KindRow(kind: kind, isOn: session.kinds.contains(kind)) { toggle(kind) }
                    }
                }
                .padding(.top, Layout.grid / 2)
            }
            .padding(.horizontal, Layout.margin)
            .padding(.top, Layout.margin + Layout.grid)
            .padding(.bottom, Layout.grid)
        } actions: {
            Button("Next") { session.step = .area }
                .buttonStyle(.primary)
                .disabled(session.kinds.isEmpty)
        }
        .overlay(alignment: .topTrailing) { close }
        .transition(.opacity)
    }

    private func toggle(_ kind: DeckKind) {
        if session.kinds.contains(kind) {
            session.kinds.remove(kind)
        } else {
            session.kinds.insert(kind)
        }
    }

    // MARK: - Step 2: area

    private var areaStep: some View {
        SheetCard(hasActions: true, onHeight: onHeight) {
            VStack(alignment: .leading, spacing: Layout.margin) {
                HStack(spacing: Layout.grid / 2) {
                    Button {
                        session.step = .kinds
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.ink)
                            .frame(width: Layout.minTouch, height: Layout.minTouch, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to kinds")
                    Text("How long?")
                        .font(WanderFont.title)
                        .foregroundStyle(.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.trailing, Layout.minTouch)

                PillPicker(options: WalkLength.allCases,
                           selection: Binding(get: { session.length }, set: { session.setLength($0) }),
                           title: \.title, spoken: \.spoken, label: "Walk length")

                endChoice

                placesLine
            }
            .padding(.horizontal, Layout.margin)
            .padding(.top, Layout.margin)
            .padding(.bottom, Layout.grid)
        } actions: {
            Button("Start swiping", action: onStartSwiping)
                .buttonStyle(.primary)
                .disabled(session.placeCount == 0 || session.start == nil)
        }
        .overlay(alignment: .topTrailing) { close }
        .transition(.opacity)
    }

    /// End: "Anywhere" (the walk ends at the last place) or "Somewhere specific".
    private var endChoice: some View {
        VStack(alignment: .leading, spacing: Layout.grid) {
            Text("Ends")
                .font(WanderFont.caption)
                .foregroundStyle(.inkMuted)
                .accessibilityHidden(true)
            HStack(spacing: Layout.grid / 2) {
                endOption("Anywhere", selected: session.destination == nil) {
                    session.setDestination(nil)
                }
                endOption("Somewhere specific", selected: session.destination != nil, action: onPickDestination)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Walk ends")
            if let destination = session.destination {
                Button(action: onPickDestination) {
                    HStack(spacing: Layout.grid) {
                        Image(systemName: "mappin")
                            .foregroundStyle(.wander)
                            .accessibilityHidden(true)
                        Text(destination.name)
                            .font(WanderFont.body)
                            .foregroundStyle(.ink)
                            .lineLimit(1)
                        Spacer(minLength: Layout.grid)
                        Text("Change")
                            .font(WanderFont.body.weight(.semibold))
                            .foregroundStyle(.wander)
                    }
                    .frame(minHeight: Layout.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ends at \(destination.name)")
                .accessibilityHint("Choose a different place")
            }
        }
    }

    private func endOption(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(selected ? WanderFont.body.weight(.semibold) : WanderFont.body)
                .foregroundStyle(selected ? Color.wander : Color.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, Layout.margin)
                .frame(minHeight: Layout.minTouch)
                .background(selected ? Color.surfaceRaised : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// "42 places here", plus how to change the area.
    @ViewBuilder
    private var placesLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            if locationDenied && session.start == nil {
                Text("Long-press the map to choose where the walk starts.")
                    .font(WanderFont.body)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else if session.start == nil {
                Text("Waiting for your location…")
                    .font(WanderFont.body)
                    .foregroundStyle(.inkMuted)
            } else {
                Text(countText)
                    .font(WanderFont.heading)
                    .foregroundStyle(.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy, value: session.placeCount)
                Text(session.destination == nil
                     ? "Drag the edge of the circle to resize it, or long-press the map to move it."
                     : "Places along the way to \(session.destination?.name ?? "there").")
                    .font(WanderFont.caption)
                    .foregroundStyle(.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let onUseMyLocation {
                    Button("Start from my location", action: onUseMyLocation)
                        .buttonStyle(.textAction)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var countText: String {
        switch session.placeCount {
        case 0: "No places here yet. Try a bigger area or more kinds."
        case 1: "1 place here"
        case let n: "\(n) places here"
        }
    }

    private var close: some View {
        SheetCloseButton(action: onClose)
            .padding(.top, Layout.margin)
            .padding(.trailing, Layout.margin - 6)
    }
}

/// Home's main action (FE-23): starts a swipe walk. Sits under the "Where to?"
/// island, raised like it, with the Wander mark so it reads as the app's own walk.
struct StartWalkButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Layout.grid) {
                WanderMark(ring: .surfaceRaised)
                    .frame(width: 30, height: 24)
                    .accessibilityHidden(true)
                Text("Start a walk")
                    .font(WanderFont.body.weight(.semibold))
                    .foregroundStyle(.wander)
                    .lineLimit(1)
            }
            .padding(.leading, Layout.grid * 1.5)
            .padding(.trailing, Layout.margin)
            .frame(minHeight: Layout.minTouch + 4)
            .background(.surfaceRaised, in: Capsule())
            // Same lift as the island and the map controls.
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Pick what to see and how long, then swipe through places")
    }
}
