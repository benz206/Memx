import SwiftUI

struct ContentView: View {
    @Environment(AppViewModel.self) private var appVM

    var body: some View {
        Group {
            switch appVM.navigationState {
            case .landing:
                LandingView()
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            case .projects:
                ProjectsView()
                    .transition(.opacity)
            case .workspace(let project):
                WorkspaceView(project: project)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: appVM.navigationState)
    }
}
