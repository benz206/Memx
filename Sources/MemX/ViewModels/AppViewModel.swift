import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "app")

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
        logger.info("AppViewModel init — \(self.projects.count) projects loaded")
    }

    // MARK: - Navigation

    func showLanding() {
        navigationState = .landing
        logger.debug("navigation → landing")
    }

    func showProjects() {
        navigationState = .projects
        logger.debug("navigation → projects")
        Task.detached {
            PhotosLibraryService.shared.cleanupTemporaryFiles()
        }
    }

    func openProject(_ project: Project) {
        navigationState = .workspace(project)
        logger.debug("navigation → workspace \(project.id): \(project.title)")
    }

    func createProject(title: String = "New Project") {
        let project = Project(title: title)
        projects.insert(project, at: 0)
        navigationState = .workspace(project)
        saveProjects()
        logger.info("created project \(project.id): \(title)")
    }

    // MARK: - Project Management

    func updateProject(_ project: Project) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        }
        saveProjects()
        logger.debug("updated project \(project.id)")
    }

    func deleteProject(_ project: Project) {
        logger.info("deleted project \(project.id): \(project.title)")
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
        logger.debug("cleaning up files for project \(project.id)")
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
        logger.info("duplicated project \(project.id) → \(copy.id)")
    }

    // MARK: - Persistence

    private func saveProjects() {
        ProjectStore.shared.save(projects)
        logger.debug("persisted \(self.projects.count) projects")
    }

    private func loadProjects() {
        migrateFromUserDefaultsIfNeeded()
        let loaded = ProjectStore.shared.load()
        projects = loaded
        logger.info("loaded \(self.projects.count) projects from disk")
    }

    private func migrateFromUserDefaultsIfNeeded() {
        let key = "ms_projects"
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([Project].self, from: data) {
            ProjectStore.shared.save(decoded)
            logger.info("migrated \(decoded.count) projects from UserDefaults")
        } else {
            logger.warning("UserDefaults migration: failed to decode legacy data")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Photos Permission

    func requestPhotosPermission() async {
        logger.info("photos permission requested")
        photosPermissionStatus = await PhotosLibraryService.shared.requestPermission()
        logger.info("photos permission result: \(String(describing: self.photosPermissionStatus))")
    }
}
