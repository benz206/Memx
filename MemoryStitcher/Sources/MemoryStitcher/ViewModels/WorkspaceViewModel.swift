import Foundation
import Observation

// MARK: - WorkspaceTab

enum WorkspaceTab: String, CaseIterable, Hashable {
    case importMedia  = "Import"
    case media        = "Media"
    case setup        = "Setup"
    case analysis     = "Analysis"
    case storyboard   = "Storyboard"

    var icon: String {
        switch self {
        case .importMedia: return "arrow.down.circle.fill"
        case .media:       return "photo.stack.fill"
        case .setup:       return "slider.horizontal.3"
        case .analysis:    return "cpu.fill"
        case .storyboard:  return "film.stack.fill"
        }
    }
}

// MARK: - WorkspaceViewModel

@Observable
final class WorkspaceViewModel {

    // MARK: Project
    var project: Project

    // MARK: Tabs & Navigation
    var selectedTab: WorkspaceTab = .importMedia

    // MARK: Assets (loaded from project's assetIDs + any imports)
    var assets: [MediaAsset] = []

    // MARK: Analysis
    var analysisStatus: AnalysisJobStatus
    var analysisResult: AnalysisResult?
    var isAnalyzing: Bool = false

    // MARK: Storyboard
    var montagePlan: MontagePlan?
    var isGeneratingPlan: Bool = false
    var selectedSequenceItem: MontageSequenceItem? = nil

    // MARK: Title editing
    var isEditingTitle: Bool = false

    // MARK: Services
    private let analysisService: AnalysisServiceProtocol
    private let plannerService: MontagePlannerServiceProtocol
    private let appVM: AppViewModel

    init(
        project: Project,
        appVM: AppViewModel,
        analysisService: AnalysisServiceProtocol = AnalysisService.shared,
        plannerService: MontagePlannerServiceProtocol = MontagePlannerService.shared
    ) {
        self.project = project
        self.appVM = appVM
        self.analysisService = analysisService
        self.plannerService = plannerService
        self.analysisStatus = AnalysisJobStatus(projectID: project.id)

        // Hydrate existing plan if present
        if let plan = project.montagePlan {
            self.montagePlan = plan
            self.analysisStatus = MockDataProvider.completedAnalysisStatus(for: project)
        }
    }

    // MARK: - Asset Management

    func addAssets(_ newAssets: [MediaAsset]) {
        let existingIDs = Set(assets.map(\.id))
        let toAdd = newAssets.filter { !existingIDs.contains($0.id) }
        assets.append(contentsOf: toAdd)
        project.assetIDs = assets.map(\.id)
        project.updatedAt = Date()
        project.status = .draft
        appVM.updateProject(project)
    }

    func removeAsset(_ asset: MediaAsset) {
        assets.removeAll { $0.id == asset.id }
        project.assetIDs.removeAll { $0 == asset.id }
        appVM.updateProject(project)
    }

    // MARK: - Analysis Pipeline

    func runAnalysis() async {
        guard !assets.isEmpty, !isAnalyzing else { return }
        isAnalyzing = true
        project.status = .analyzing
        appVM.updateProject(project)

        do {
            let result = try await analysisService.runAnalysis(
                for: project,
                assets: assets
            ) { [weak self] status in
                guard let self else { return }
                Task { @MainActor in
                    self.analysisStatus = status
                }
            }

            analysisResult = result

            // Update assets with scores
            let scoreMap = Dictionary(uniqueKeysWithValues: result.scoredAssets.map { ($0.id, $0) })
            assets = assets.map { scoreMap[$0.id] ?? $0 }

            // Auto-generate plan
            await generatePlan(from: result)

            project.status = .ready
            appVM.updateProject(project)
            selectedTab = .storyboard

        } catch {
            analysisStatus.error = error.localizedDescription
            project.status = .draft
            appVM.updateProject(project)
        }

        isAnalyzing = false
    }

    func generatePlan(from result: AnalysisResult? = nil) async {
        let r = result ?? analysisResult
        guard let r else { return }
        isGeneratingPlan = true

        let plan = await plannerService.buildPlan(
            title: project.title,
            settings: project.settings,
            analysisResult: r
        )

        montagePlan = plan
        project.montagePlan = plan
        appVM.updateProject(project)
        isGeneratingPlan = false
    }

    // MARK: - Settings

    func updateSettings(_ settings: MontageSettings) {
        project.settings = settings
        project.updatedAt = Date()
        appVM.updateProject(project)
    }

    func updateTitle(_ title: String) {
        guard !title.isEmpty else { return }
        project.title = title
        project.updatedAt = Date()
        appVM.updateProject(project)
    }

    // MARK: - Storyboard Editing

    func moveSequenceItem(from source: IndexSet, to destination: Int) {
        montagePlan?.sequence.move(fromOffsets: source, toOffset: destination)
        if let plan = montagePlan {
            project.montagePlan = plan
            appVM.updateProject(project)
        }
    }

    func removeSequenceItem(_ item: MontageSequenceItem) {
        montagePlan?.sequence.removeAll { $0.id == item.id }
        if let plan = montagePlan {
            project.montagePlan = plan
            appVM.updateProject(project)
        }
    }

    func updateTransition(for item: MontageSequenceItem, to transition: TransitionType) {
        guard let idx = montagePlan?.sequence.firstIndex(where: { $0.id == item.id }) else { return }
        montagePlan?.sequence[idx].transitionType = transition
    }

    // MARK: - Computed

    var totalAssetCount: Int { assets.count }
    var photoCount: Int { assets.filter { $0.mediaType == .photo || $0.mediaType == .livePhoto }.count }
    var videoCount: Int { assets.filter { $0.mediaType == .video }.count }
    var canAnalyze: Bool { !assets.isEmpty && !isAnalyzing }
    var hasAnalysisResult: Bool { analysisResult != nil || project.montagePlan != nil }
}
