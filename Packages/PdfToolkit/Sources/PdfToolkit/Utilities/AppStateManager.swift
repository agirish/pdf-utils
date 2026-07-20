import Foundation

@MainActor
public final class AppStateManager: ObservableObject {
    public static let shared = AppStateManager()
    
    @Published public private(set) var activeOperations: Set<String> = []
    
    public var hasPendingOperations: Bool {
        !activeOperations.isEmpty
    }
    
    public func beginOperation(_ name: String) {
        activeOperations.insert(name)
        // A DEBUG breadcrumb marking the operation's start. It pairs with the INFO "saved" / ERROR
        // "failed" line that ends the operation, so at the "Everything" level a run that hangs or is
        // force-quit shows as a start with no matching finish. Emitted here — the one point every
        // tool and the batch runner already funnel through — rather than repeated at each run site.
        ActivityLog.shared.debug("\(name): started")
    }
    
    public func endOperation(_ name: String) {
        activeOperations.remove(name)
    }
    
    public var pendingOperationsDescription: String {
        return activeOperations.sorted().joined(separator: ", ")
    }
}
