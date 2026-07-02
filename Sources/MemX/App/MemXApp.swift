import SwiftUI
import Photos

public struct MemXApp: App {
    @State private var appViewModel = AppViewModel()
    @State private var showPrivacySettings = false

    public init() {}

    /// The workspace VM backing menu commands, only while a workspace is open.
    private var workspaceVM: WorkspaceViewModel? {
        guard case .workspace = appViewModel.navigationState else { return nil }
        return appViewModel.activeWorkspaceVM
    }

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appViewModel)
                .frame(minWidth: 1100, minHeight: 720)
                .sheet(isPresented: $showPrivacySettings) {
                    PrivacySettingsView()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    appViewModel.requestNewProject()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Select All Assets") {
                    workspaceVM?.activeImportVM?.selectAll()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(workspaceVM?.selectedTab != .photos)

                Button("Deselect All Assets") {
                    workspaceVM?.activeImportVM?.deselectAll()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspaceVM?.selectedTab != .photos)
            }

            CommandMenu("Project") {
                Button("Run Pipeline") {
                    guard let vm = workspaceVM else { return }
                    Task { await vm.runPipeline() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(workspaceVM?.canRunPipeline != true)

                Button("Export Video") {
                    guard let vm = workspaceVM else { return }
                    Task { await vm.renderVideo() }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(workspaceVM?.hasPlan != true || workspaceVM?.isRendering == true)

                Button("Stop") {
                    workspaceVM?.cancelPipeline()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(workspaceVM?.isCancellable != true)
            }

            CommandMenu("Go") {
                Button("Projects") {
                    appViewModel.showProjects()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(workspaceVM == nil
                          || workspaceVM?.isProcessing == true
                          || workspaceVM?.isRendering == true)

                Divider()

                ForEach(WorkspaceTab.allCases, id: \.self) { tab in
                    Button(tab.rawValue) {
                        workspaceVM?.goToStage(tab)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(tab.stepNumber)")), modifiers: .command)
                    .disabled(workspaceVM?.canOpenStage(tab) != true)
                }

                Divider()

                Button("Next Stage") {
                    workspaceVM?.goToNextStage()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(workspaceVM == nil)

                Button("Previous Stage") {
                    workspaceVM?.goToPreviousStage()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(workspaceVM == nil)
            }

            CommandGroup(after: .appSettings) {
                Button("Privacy Settings…") {
                    showPrivacySettings = true
                }
            }
        }
    }
}
