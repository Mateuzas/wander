import SwiftUI
import UIKit

extension View {
    /// Reports a long press on the map at its location in `space` (FE-7).
    /// `onPressing` is true from the moment the press is recognized until the
    /// finger lifts, so a tap handler can ignore the lift.
    func onMapLongPress(in space: NamedCoordinateSpace, minimumDuration: TimeInterval = 0.5,
                        onPressing: @escaping (Bool) -> Void,
                        perform action: @escaping (CGPoint) -> Void) -> some View {
        modifier(MapLongPressModifier(space: space, minimumDuration: minimumDuration,
                                      onPressing: onPressing, action: action))
    }
}

private struct MapLongPressModifier: ViewModifier {
    let space: NamedCoordinateSpace
    let minimumDuration: TimeInterval
    let onPressing: (Bool) -> Void
    let action: (CGPoint) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            // Fires while the finger is still down, like Maps, and at the exact press point.
            content.gesture(LongPressRecognizer(space: space, minimumDuration: minimumDuration,
                                                onPressing: onPressing, action: action))
        } else {
            // iOS 17 has no way to read a long press's location, so the press is
            // followed by a zero-distance drag and the pin drops when the finger lifts.
            content.simultaneousGesture(
                LongPressGesture(minimumDuration: minimumDuration)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: space))
                    .onEnded { value in
                        guard case .second(true, let drag?) = value else { return }
                        onPressing(true)
                        action(drag.startLocation)
                        onPressing(false)
                    })
        }
    }
}

@available(iOS 18, *)
private struct LongPressRecognizer: UIGestureRecognizerRepresentable {
    let space: NamedCoordinateSpace
    let minimumDuration: TimeInterval
    let onPressing: (Bool) -> Void
    let action: (CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = minimumDuration
        // Leave the map's own pan, pinch and annotation taps alone.
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            onPressing(true)
            action(context.converter.location(in: space))
        case .ended, .cancelled, .failed:
            onPressing(false)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
