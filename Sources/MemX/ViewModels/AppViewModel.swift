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
        Task.detached {
            PhotosLibraryService.shared.cleanupTemporaryFiles()
        }
    }

    // MARK: - Navigation

    func showLanding() {
        navigationState = .landing
    }

    func showProjects() {
        navigationState = .projects
        Task.detached {
            PhotosLibraryService.shared.cleanupTemporaryFiles()
        }
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
            Task.detached {
                PhotosLibraryService.shared.cleanupTemporaryFiles()
            }
        }
    }

    private func cleanUpProjectFiles(_ project: Project) {
        let fm = FileManager.default
        if let videoURL = project.exportedVideoURL {
            try? fm.removeItem(at: videoURL)
        }
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

    // MARK: - Persistence

    private func saveProjects() {
        ProjectStore.shared.save(projects)
    }

    private func loadProjects() {
        migrateFromUserDefaultsIfNeeded()
        let loaded = ProjectStore.shared.load()
        projects = loaded
    }

    private func migrateFromUserDefaultsIfNeeded() {
        let key = "ms_projects"
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([Project].self, from: data) {
            ProjectStore.shared.save(decoded)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Photos Permission

    func requestPhotosPermission() async {
        photosPermissionStatus = await PhotosLibraryService.shared.requestPermission()
    }
}
