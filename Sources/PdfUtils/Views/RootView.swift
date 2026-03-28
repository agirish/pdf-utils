import SwiftUI



struct RootView: View {
    var body: some View {
        NavigationStack {
            DashboardView()
        }
        .frame(minWidth: 960, minHeight: 640)
    }
}
