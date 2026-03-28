import SwiftUI

@main
struct PdfUtilsApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Toggle Full Screen") {
                    FullScreenSupport.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }
        }
    }
}
