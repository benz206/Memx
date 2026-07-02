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
                } else if filteredProjects.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    projectList
                }
            }
            .navigationTitle("MemX")
            .navigationSubtitle("\(appVM.projects.count) project\(appVM.projects.count == 1 ? "" : "s")")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appVM.isNewProjectSheetPresented = true
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .help("New Project (⌘N)")
                }
            }
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

    // MARK: - Project List

    private var projectList: some View {
        @Bindable var appVM = appVM

        return List(selection: $appVM.selectedProjectID) {
            ForEach(filteredProjects) { project in
                ProjectRowView(project: project)
                    .tag(project.id)
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            appVM.openProject(project)
                        }
                    )
                    .contextMenu {
                        Button("Open") { appVM.openProject(project) }
                        Button("Duplicate") { appVM.duplicateProject(project) }
                        Divider()
                        Button("Delete…", role: .destructive) { projectToDelete = project }
                    }
            }
        }
        .listStyle(.inset)
        .onKeyPress(.return) {
            guard let selected = selectedProject else { return .ignored }
            appVM.openProject(selected)
            return .handled
        }
        .onDeleteCommand {
            if let selected = selectedProject { projectToDelete = selected }
        }
    }

    private var selectedProject: Project? {
        appVM.projects.first { $0.id == appVM.selectedProjectID }
    }

    // MARK: - Welcome / Empty State

    private var welcomeState: some View {
        VStack(spacing: MS.Spacing.lg) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: MS.Spacing.sm) {
                Text("Welcome to MemX")
                    .font(MS.Font.displayMedium)
                Text("Pick a song and a set of photos. MemX analyzes the track on-device and cuts your memories into a beat-synchronized montage.")
                    .font(MS.Font.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button {
                appVM.isNewProjectSheetPresented = true
            } label: {
                Label("New Project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Text("Everything — analysis, sequencing, rendering — runs locally on your Mac.")
                .font(MS.Font.caption)
                .foregroundStyle(.tertiary)
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
            Text("New Project")
                .font(MS.Font.title)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(MS.Font.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. Summer in Lisbon", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(MS.Font.body)
                    .focused($titleFieldFocused)
                    .onSubmit(create)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(MS.Spacing.lg)
        .frame(width: 380)
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

// MARK: - ProjectRowView

struct ProjectRowView: View {
    let project: Project

    var body: some View {
        HStack(spacing: MS.Spacing.md) {
            Image(systemName: project.status.icon)
                .font(.system(size: 15))
                .foregroundStyle(project.status.displayColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.title)
                    .font(MS.Font.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(formatDate(project.updatedAt))
                    if !project.assetIDs.isEmpty {
                        Text("·")
                        Text("\(project.assetIDs.count) asset\(project.assetIDs.count == 1 ? "" : "s")")
                    }
                    if let song = project.songTrack {
                        Text("·")
                        Text(song.displayTitle).lineLimit(1)
                    }
                }
                .font(MS.Font.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            MSBadge(
                text: project.status.displayName,
                color: project.status.displayColor,
                size: .small
            )
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func formatDate(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
