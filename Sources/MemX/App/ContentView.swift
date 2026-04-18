import SwiftUI

struct ContentView: View {
    @Environment(AppViewModel.self) private var appVM

    var body: some View {
        Group {
            switch appVM.navigationState {
            case .landing:
                LandingView()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .projects:
                ProjectsView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .workspace(let project):
                WorkspaceView(project: project, appVM: appVM)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: appVM.navigationState)
    }
}
