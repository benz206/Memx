import SwiftUI
import Photos

public struct MemXApp: App {
    @State private var appViewModel = AppViewModel()

    public init() {}

    public var body: some Scene {
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
