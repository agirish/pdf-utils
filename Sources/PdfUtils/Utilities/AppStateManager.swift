import Foundation

@MainActor
final class AppStateManager: ObservableObject {
    static let shared = AppStateManager()
    
    @Published private(set) var activeOperations: Set<String> = []
    
    var hasPendingOperations: Bool {
        !activeOperations.isEmpty
    }
    
    func beginOperation(_ name: String) {
        activeOperations.insert(name)
    }
    
    func endOperation(_ name: String) {
        activeOperations.remove(name)
    }
    
    var pendingOperationsDescription: String {
        return activeOperations.sorted().joined(separator: ", ")
    }
}
