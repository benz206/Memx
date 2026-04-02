import SwiftUI
import Photos

@main
struct MemoryStitcherApp: App {
    @State private var appViewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appViewModel)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    appViewModel.createProject()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
