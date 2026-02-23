import Foundation
import Network

/// Monitors network reachability and transport type changes.
/// Reports changes via callback, debounced to avoid rapid-fire events.
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    enum Transport: String {
        case wifi
        case cellular
        case wired
        case none
    }

    struct State: Equatable {
        let isReachable: Bool
        let transport: Transport
    }

    private var monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.termopus.network-monitor")
    private var lastState: State?
    private var isRunning = false

    /// Called on main thread when network state changes.
    var onStateChange: ((State) -> Void)?

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true

        monitor = NWPathMonitor()  // Create fresh monitor (cancel() is terminal)

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let transport: Transport
            if path.usesInterfaceType(.wifi) {
                transport = .wifi
            } else if path.usesInterfaceType(.cellular) {
                transport = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                transport = .wired
            } else {
                transport = .none
            }

            let newState = State(
                isReachable: path.status == .satisfied,
                transport: transport
            )

            // Only fire if state actually changed
            if newState != self.lastState {
                self.lastState = newState
                DispatchQueue.main.async {
                    self.onStateChange?(newState)
                }
            }
        }

        monitor.start(queue: queue)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitor.cancel()
    }

    /// Current state snapshot.
    var currentState: State {
        lastState ?? State(isReachable: false, transport: .none)
    }
}
