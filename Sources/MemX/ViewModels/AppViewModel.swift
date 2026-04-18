import Foundation
import Observation

// MARK: - NavigationState

enum NavigationState: Hashable {
    case landing
    case projects
    case workspace(Project)
}

// MARK: - AppViewModel

@Observable
final class AppViewModel {

    // MARK: Navigation
    var navigationState: NavigationState = .landing

    // MARK: Projects
    var projects: [Project] = []

    // MARK: Photos Permission
    var photosPermissionStatus = PhotosLibraryService.shared.authorizationStatus()

    init() {
        loadProjects()
    }

    // MARK: - Navigation

    func showLanding() {
        navigationState = .landing
    }

    func showProjects() {
        navigationState = .projects
    }

    func openProject(_ project: Project) {
        navigationState = .workspace(project)
    }

    func createProject(title: String = "New Project") {
        let project = Project(title: title)
        projects.insert(project, at: 0)
        navigationState = .workspace(project)
        saveProjects()
    }

    // MARK: - Project Management

    func updateProject(_ project: Project) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        }
        saveProjects()
    }

    func deleteProject(_ project: Project) {
        cleanUpProjectFiles(project)
        projects.removeAll { $0.id == project.id }
        saveProjects()
        if case .workspace(let current) = navigationState, current.id == project.id {
            navigationState = .projects
        }
    }

    private func cleanUpProjectFiles(_ project: Project) {
        let fm = FileManager.default
        // Exported video
        if let videoURL = project.exportedVideoURL {
            try? fm.removeItem(at: videoURL)
        }
        // Copied song + any other project files under App Support/MemX/Songs/{id}/
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let memxBase = base.appendingPathComponent("MemX")
            let songDir = memxBase.appendingPathComponent("Songs/\(project.id.uuidString)")
            try? fm.removeItem(at: songDir)
        }
    }

    func duplicateProject(_ project: Project) {
        var copy = project
        copy = Project(title: project.title + " Copy", settings: project.settings)
        projects.insert(copy, at: 0)
        saveProjects()
    }

    // MARK: - Persistence (simple UserDefaults; swap for Core Data as needed)

    private func saveProjects() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: "ms_projects")
    }

    private func loadProjects() {
        if let data = UserDefaults.standard.data(forKey: "ms_projects"),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        } else {
            // Seed demo project on first launch
            projects = MockDataProvider.sampleProjects()
        }
    }

    // MARK: - Photos Permission

    func requestPhotosPermission() async {
        photosPermissionStatus = await PhotosLibraryService.shared.requestPermission()
    }
}
