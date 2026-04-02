import SwiftUI

struct ProjectsView: View {
    @Environment(AppViewModel.self) private var appVM
    @State private var showNewProjectSheet = false
    @State private var newProjectTitle = ""
    @State private var searchText = ""
    @State private var projectToDelete: Project? = nil

    var filteredProjects: [Project] {
        if searchText.isEmpty { return appVM.projects }
        return appVM.projects.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            MSGradientBackground()

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Projects")
                            .font(MS.Font.displayMedium)
                        Text("\(appVM.projects.count) montage project\(appVM.projects.count == 1 ? "" : "s")")
                            .font(MS.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: MS.Spacing.sm) {
                        Button {
                            appVM.showLanding()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Back to Home")

                        MSPrimaryButton("New Project", icon: "plus") {
                            newProjectTitle = ""
                            showNewProjectSheet = true
                        }
                    }
                }
                .padding(.horizontal, MS.Spacing.xl)
                .padding(.top, MS.Spacing.xl)
                .padding(.bottom, MS.Spacing.md)

                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                    TextField("Search projects...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(MS.Font.body)
                }
                .padding(MS.Spacing.sm + 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
                .padding(.horizontal, MS.Spacing.xl)
                .padding(.bottom, MS.Spacing.md)

                if filteredProjects.isEmpty {
                    EmptyStateView(
                        icon: "film.stack",
                        title: searchText.isEmpty ? "No Projects Yet" : "No Results",
                        subtitle: searchText.isEmpty
                            ? "Create your first montage project to get started."
                            : "Try a different search term.",
                        action: searchText.isEmpty ? ("Create Project", { showNewProjectSheet = true }) : nil
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: MS.Spacing.sm) {
                            ForEach(filteredProjects) { project in
                                ProjectRowView(project: project)
                                    .onTapGesture { appVM.openProject(project) }
                                    .contextMenu {
                                        Button("Open") { appVM.openProject(project) }
                                        Button("Duplicate") { appVM.duplicateProject(project) }
                                        Divider()
                                        Button("Delete", role: .destructive) { projectToDelete = project }
                                    }
                            }
                        }
                        .padding(.horizontal, MS.Spacing.xl)
                        .padding(.bottom, MS.Spacing.xl)
                    }
                }
            }
        }
        .sheet(isPresented: $showNewProjectSheet) {
            newProjectSheet
        }
        .confirmationDialog(
            "Delete \"\(projectToDelete?.title ?? "")\"?",
            isPresented: .constant(projectToDelete != nil),
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

    // MARK: - New Project Sheet

    private var newProjectSheet: some View {
        VStack(spacing: MS.Spacing.lg) {
            Text("New Project")
                .font(MS.Font.title)

            VStack(alignment: .leading, spacing: 6) {
                Text("Project Title")
                    .font(MS.Font.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. Summer in Lisbon", text: $newProjectTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(MS.Font.body)
            }

            HStack(spacing: MS.Spacing.sm) {
                MSSecondaryButton("Cancel") { showNewProjectSheet = false }
                MSPrimaryButton("Create", icon: "sparkles") {
                    appVM.createProject(title: newProjectTitle.isEmpty ? "New Project" : newProjectTitle)
                    showNewProjectSheet = false
                }
            }
        }
        .padding(MS.Spacing.xl)
        .frame(width: 360)
    }
}

// MARK: - ProjectRowView

struct ProjectRowView: View {
    let project: Project
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: MS.Spacing.md) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous)
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(project.title)
                        .font(MS.Font.heading)
                        .lineLimit(1)
                    Spacer()
                    Text(formatDate(project.updatedAt))
                        .font(MS.Font.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: MS.Spacing.sm) {
                    MSBadge(text: project.status.rawValue, color: statusColor, size: .small)
                    if !project.assetIDs.isEmpty {
                        MSBadge(text: "\(project.assetIDs.count) assets", size: .small)
                    }
                    MSBadge(text: project.settings.vibe.rawValue, size: .small)
                    MSBadge(text: project.settings.targetDuration.label, size: .small)
                    Spacer()
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(MS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MS.Radius.md, style: .continuous)
                .fill(isHovered ? Color.secondary.opacity(0.08) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .msCard()
    }

    private var statusColor: Color {
        switch project.status {
        case .draft:     return .secondary
        case .importing: return .blue
        case .analyzing: return .orange
        case .ready:     return .green
        case .exported:  return .purple
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
