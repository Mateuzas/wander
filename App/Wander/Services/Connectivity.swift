import Network
import Observation

/// Whether the phone has a network path. Routes need one (PLAN.md §7, Offline).
@MainActor
@Observable
final class Connectivity {
    private(set) var isOnline = true

    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "wander.connectivity", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }
}
