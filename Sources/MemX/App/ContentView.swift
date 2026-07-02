import SwiftUI

struct ContentView: View {
    @Environment(AppViewModel.self) private var appVM

    var body: some View {
        Group {
            switch appVM.navigationState {
            case .projects:
                ProjectsView()
                    .transition(.opacity)
            case .workspace(let project):
                WorkspaceView(project: project, appVM: appVM)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appVM.navigationState)
    }
}
