import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.memx.app", category: "app")

// MARK: - NavigationState

enum NavigationState: Hashable {
    case projects
    case workspace(Project)
}

// MARK: - AppViewModel

@Observable
final class AppViewModel {

    // MARK: Navigation
    var navigationState: NavigationState = .projects

    /// Project selected in the projects list; targeted by menu commands
    /// (Open, Duplicate, Delete).
    var selectedProjectID: UUID? = nil

    /// Presented from the projects screen; menu ⌘N routes here.
    var isNewProjectSheetPresented = false

    // MARK: Projects
    var projects: [Project] = []
    weak var activeWorkspaceVM: WorkspaceViewModel?

    // MARK: Photos Permission
    var photosPermissionStatus = PhotosLibraryService.shared.authorizationStatus()

    init() {
        loadProjects()
        cleanUpStaleProjectData()
        Task.detached {
            PhotosLibraryService.shared.cleanupTemporaryFiles()
        }
        logger.info("AppViewModel init — \(self.projects.count) projects loaded")
    }

    // MARK: - Navigation

    func showProjects() {
        navigationState = .projects
        logger.debug("navigation → projects")
        Task.detached {
            PhotosLibraryService.shared.cleanupTemporaryFiles()
        }
    }

    /// Menu-bar New Project: return to the projects screen and open the sheet.
    func requestNewProject() {
        navigationState = .projects
        isNewProjectSheetPresented = true
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
        if activeWorkspaceVM?.project.id == project.id {
            activeWorkspaceVM?.cancelPipeline()
            activeWorkspaceVM = nil
        }
        cleanUpProjectFiles(project)
        projects.removeAll { $0.id == project.id }
        saveProjects()
        if case .workspace(let current) = navigationState, current.id == project.id {
            navigationState = .projects
        }
        Task.detached {
            PhotosLibraryService.shared.cleanupTemporaryFiles()
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
            let exportFile = memxBase.appendingPathComponent("Exports/\(project.id.uuidString).mp4")
            try? fm.removeItem(at: exportFile)
        }
    }

    private func cleanUpStaleProjectData() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let memxBase = base.appendingPathComponent("MemX")
        let validIDs = Set(projects.map { $0.id.uuidString })

        let songsDir = memxBase.appendingPathComponent("Songs")
        if let songSubdirs = try? fm.contentsOfDirectory(atPath: songsDir.path) {
            for dirname in songSubdirs where !validIDs.contains(dirname) {
                let stale = songsDir.appendingPathComponent(dirname)
                try? fm.removeItem(at: stale)
                logger.info("removed stale song directory: \(dirname)")
            }
        }

        let exportsDir = memxBase.appendingPathComponent("Exports")
        if let exportFiles = try? fm.contentsOfDirectory(atPath: exportsDir.path) {
            for filename in exportFiles {
                let stem = (filename as NSString).deletingPathExtension
                if !validIDs.contains(stem) {
                    let stale = exportsDir.appendingPathComponent(filename)
                    try? fm.removeItem(at: stale)
                    logger.info("removed stale export: \(filename)")
                }
            }
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
