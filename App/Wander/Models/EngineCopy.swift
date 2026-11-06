import RouteEngine

// User-facing words for RouteEngine types.

extension Mode {
    var title: String {
        switch self {
        case .direct: "Direct"
        case .recommended: "Recommended"
        }
    }
}
