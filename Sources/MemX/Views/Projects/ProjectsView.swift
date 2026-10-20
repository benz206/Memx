import SwiftUI

struct ProjectsView: View {
    @Environment(AppViewModel.self) private var appVM
    @State private var searchText = ""
    @State private var projectToDelete: Project? = nil

    var filteredProjects: [Project] {
        if searchText.isEmpty { return appVM.projects }
        return appVM.projects.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        @Bindable var appVM = appVM

        NavigationStack {
            Group {
                if appVM.projects.isEmpty {
                    welcomeState
                } else {
                    projectsPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MSColor.canvas)
            .navigationTitle("MemX")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search projects")
        }
        .sheet(isPresented: $appVM.isNewProjectSheetPresented) {
            NewProjectSheet()
        }
        .confirmationDialog(
            "Delete “\(projectToDelete?.title ?? "")”?",
            isPresented: Binding(
                get: { projectToDelete != nil },
                set: { if !$0 { projectToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let p = projectToDelete { appVM.deleteProject(p) }
                projectToDelete = nil
            }
            Button("Cancel", role: .cancel) { projectToDelete = nil }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var projectsPage: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.lg) {
            MSPageHeader(
                title: "Projects",
                subtitle: "Beat-synced montages cut from your Photos library."
            ) {
                MSPrimaryButton("New Project", icon: "plus") {
                    appVM.isNewProjectSheetPresented = true
                }
                .help("New Project (⌘N)")
            }

            MSStatStrip(stats: [
                MSStat(label: "Projects", value: "\(appVM.projects.count)"),
                MSStat(label: "In progress", value: "\(appVM.projects.filter { $0.status != .exported && $0.status != .draft }.count)"),
                MSStat(label: "Rendered", value: "\(appVM.projects.filter { $0.status == .exported }.count)"),
                MSStat(label: "Media", value: "\(appVM.projects.reduce(0) { $0 + $1.assetIDs.count })", sub: "photos & videos"),
            ])

            if filteredProjects.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, minHeight: 240)
                    .msCard()
            } else {
                projectTable
            }
        }
        .frame(maxWidth: 1080, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, MS.Spacing.xl)
        .padding(.vertical, MS.Spacing.lg)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Project List

    private var projectTable: some View {
        @Bindable var appVM = appVM

        return Table(filteredProjects, selection: $appVM.selectedProjectID) {
            TableColumn("Name") { project in
                HStack(spacing: 10) {
                    Image(systemName: project.status.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MSColor.inkMuted)
                        .frame(width: 26, height: 26)
                        .background(MSColor.surface2, in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
                    Text(project.title)
                        .font(MS.Font.body.weight(.medium))
                        .foregroundStyle(MSColor.inkBright)
                        .lineLimit(1)
                }
                .padding(.vertical, 5)
            }
            TableColumn("Song") { project in
                Text(project.songTrack?.displayTitle ?? "—")
                    .font(MS.Font.body)
                    .foregroundStyle(project.songTrack == nil ? MSColor.inkFaint : MSColor.ink)
                    .lineLimit(1)
            }
            TableColumn("Media") { project in
                Text(project.assetIDs.isEmpty ? "—" : "\(project.assetIDs.count)")
                    .font(MS.Font.body)
                    .monospacedDigit()
                    .foregroundStyle(MSColor.ink)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(64)
            TableColumn("Updated") { project in
                Text(formatDate(project.updatedAt))
                    .font(MS.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(MSColor.inkMuted)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Status") { project in
                MSBadge(text: project.status.displayName, color: project.status.displayColor,
                        size: .small, showsDot: true)
            }
            .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let project = project(for: ids) {
                Button("Open") { appVM.openProject(project) }
                Button("Duplicate") { appVM.duplicateProject(project) }
                Divider()
                Button("Delete…", role: .destructive) { projectToDelete = project }
            }
        } primaryAction: { ids in
            if let project = project(for: ids) { appVM.openProject(project) }
        }
        .onKeyPress(.return) {
            guard let selected = selectedProject else { return .ignored }
            appVM.openProject(selected)
            return .handled
        }
        .onDeleteCommand {
            if let selected = selectedProject { projectToDelete = selected }
        }
        .frame(maxHeight: .infinity)
        .msCard(padding: 0)
    }

    private func project(for ids: Set<UUID>) -> Project? {
        guard let id = ids.first else { return nil }
        return appVM.projects.first { $0.id == id }
    }

    private var selectedProject: Project? {
        appVM.projects.first { $0.id == appVM.selectedProjectID }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func formatDate(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Welcome / Empty State

    private var welcomeState: some View {
        VStack(spacing: MS.Spacing.md) {
            EmptyStateView(
                icon: "music.note.list",
                title: "Make your first montage",
                subtitle: "Pick a song and a set of photos. MemX analyzes the track on-device and cuts your memories to the beat.",
                action: ("New Project", { appVM.isNewProjectSheetPresented = true })
            )
            .fixedSize(horizontal: false, vertical: true)
            Text("Analysis, sequencing and rendering all run locally on your Mac.")
                .font(MS.Font.caption)
                .foregroundStyle(MSColor.inkFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - New Project Sheet

struct NewProjectSheet: View {
    @Environment(AppViewModel.self) private var appVM
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MS.Spacing.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Project")
                    .font(MS.Font.title)
                    .foregroundStyle(MSColor.inkBright)
                Text("You'll pick a song and photos next.")
                    .font(MS.Font.caption)
                    .foregroundStyle(MSColor.inkMuted)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(MS.Font.caption.weight(.medium))
                    .foregroundStyle(MSColor.inkBright)
                TextField("e.g. Summer in Lisbon", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(MS.Font.body)
                    .focused($titleFieldFocused)
                    .onSubmit(create)
            }

            HStack(spacing: MS.Spacing.sm) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.ms(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Create Project", action: create)
                    .buttonStyle(.ms(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(MS.Spacing.lg)
        .frame(width: 400)
        .background(MSColor.surface)
        .task {
            // Defer by one runloop tick + small delay so the sheet window is
            // fully key before focusing; otherwise macOS silently drops
            // keyboard events targeting the TextField.
            try? await Task.sleep(nanoseconds: 120_000_000)
            titleFieldFocused = true
        }
    }

    private func create() {
        appVM.createProject(title: title.isEmpty ? "New Project" : title)
        dismiss()
        Task {
            if PhotosLibraryService.shared.authorizationStatus() == .notDetermined {
                _ = await PhotosLibraryService.shared.requestPermission()
            }
        }
    }
}
