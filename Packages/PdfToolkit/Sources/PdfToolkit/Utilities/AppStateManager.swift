import Foundation

@MainActor
public final class AppStateManager: ObservableObject {
    public static let shared = AppStateManager()

    /// Live operations keyed by display name, **counted**: two windows can run the same tool at
    /// once, and a plain `Set` collapsed them — the first to finish removed the shared entry, the
    /// quit warning went quiet, and ⌘Q aborted the still-running twin's save mid-write.
    @Published public private(set) var activeOperations: [String: Int] = [:]

    public var hasPendingOperations: Bool {
        !activeOperations.isEmpty
    }

    public func beginOperation(_ name: String) {
        activeOperations[name, default: 0] += 1
        // A DEBUG breadcrumb marking the operation's start. It pairs with the INFO "saved" / ERROR
        // "failed" line that ends the operation, so at the "Everything" level a run that hangs or is
        // force-quit shows as a start with no matching finish. Emitted here — the one point every
        // tool and the batch runner already funnel through — rather than repeated at each run site.
        ActivityLog.shared.debug("\(name): started")
    }

    public func endOperation(_ name: String) {
        guard let count = activeOperations[name] else { return }
        activeOperations[name] = count > 1 ? count - 1 : nil
    }

    public var pendingOperationsDescription: String {
        return activeOperations.keys.sorted().joined(separator: ", ")
    }
}
