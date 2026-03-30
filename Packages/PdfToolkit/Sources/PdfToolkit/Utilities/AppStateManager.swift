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
    }
    
    public func endOperation(_ name: String) {
        activeOperations.remove(name)
    }
    
    public var pendingOperationsDescription: String {
        return activeOperations.sorted().joined(separator: ", ")
    }
}
