import SwiftUI

struct MediaGridView: View {
    @Environment(WorkspaceViewModel.self) private var workspaceVM
    @State private var selectedAsset: MediaAsset? = nil
    @State private var filterType: AssetFilterType = .all
    @State private var sortOrder: AssetSortOrder = .newestFirst
    @State private var searchText = ""
    @State private var showingDetail = false
    @State private var gridSize: CGFloat = 130

    private var visibleAssets: [MediaAsset] {
        var assets = workspaceVM.assets
        if !searchText.isEmpty {
            assets = assets.filter {
                $0.filename?.localizedCaseInsensitiveContains(searchText) == true ||
                $0.eventLabel?.localizedCaseInsensitiveContains(searchText) == true
            }
        }
        switch filterType {
        case .all:       break
        case .photos:    assets = assets.filter { $0.mediaType == .photo || $0.mediaType == .livePhoto }
        case .videos:    assets = assets.filter { $0.mediaType == .video }
        case .favorites: assets = assets.filter(\.isFavorite)
        }
        switch sortOrder {
        case .newestFirst: assets.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        case .oldestFirst: assets.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        case .bestScore:   assets.sort { ($0.analysisScore ?? 0) > ($1.analysisScore ?? 0) }
        }
        return assets
    }

    private var groupedByEvent: [(String, [MediaAsset])] {
        let grouped = Dictionary(grouping: visibleAssets) { $0.eventLabel ?? "Ungrouped" }
        let order = ["Arrival & First Looks", "Golden Hour Walk", "Group Laughs", "The Quiet In-Between", "Peak Celebration", "Farewell & Reflection", "Ungrouped", "Hidden Gems"]
        let sortedKeys = grouped.keys.sorted { a, b in
            let ai = order.firstIndex(of: a) ?? 99
            let bi = order.firstIndex(of: b) ?? 99
            return ai < bi
        }
        return sortedKeys.map { ($0, grouped[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            MSDivider()

            if workspaceVM.assets.isEmpty {
                EmptyStateView(
                    icon: "photo.stack",
                    title: "No Media Yet",
                    subtitle: "Import photos and videos from Apple Photos to get started.",
                    action: ("Go to Photos", { workspaceVM.selectedTab = .photos })
                )
            } else if visibleAssets.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No Results",
                    subtitle: "Try adjusting your search or filter."
                )
            } else {
                mainGrid
            }
        }
        .sheet(item: $selectedAsset) { asset in
            AssetDetailSheet(asset: asset)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: MS.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search media...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(MS.Font.body)
            }
            .padding(.horizontal, MS.Spacing.sm)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))
            .frame(maxWidth: 200)

            Divider().frame(height: 18)

            ForEach(AssetFilterType.allCases, id: \.self) { filter in
                Button {
                    filterType = filter
                } label: {
                    Label(filter.rawValue, systemImage: filter.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(filterType == filter ? Color.accentColor : Color.secondary)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help(filter.rawValue)
            }

            Divider().frame(height: 18)

            Picker("Sort", selection: $sortOrder) {
                ForEach(AssetSortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .font(MS.Font.caption)
            .frame(width: 130)

            Spacer()

            // Grid size slider
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: $gridSize, in: 80...220, step: 10)
                    .frame(width: 80)
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Text("\(visibleAssets.count) items")
                .font(MS.Font.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, MS.Spacing.md)
        .padding(.vertical, MS.Spacing.sm)
        .background(.bar)
    }

    // MARK: - Grid

    private var mainGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MS.Spacing.lg) {
                if workspaceVM.hasScoredAssets {
                    // Group analyzed assets by OpenRouter event label.
                    ForEach(groupedByEvent, id: \.0) { eventLabel, assets in
                        eventSection(label: eventLabel, assets: assets)
                    }
                } else {
                    // Flat grid
                    flatGrid(assets: visibleAssets)
                        .padding(.horizontal, MS.Spacing.md)
                }
            }
            .padding(.bottom, MS.Spacing.xl)
            .padding(.top, MS.Spacing.md)
        }
    }

    @ViewBuilder
    private func eventSection(label: String, assets: [MediaAsset]) -> some View {
        VStack(alignment: .leading, spacing: MS.Spacing.sm) {
            HStack {
                Text(label)
                    .font(MS.Font.heading)
                MSBadge(text: "\(assets.count)", size: .small)
                Spacer()
            }
            .padding(.horizontal, MS.Spacing.md)

            flatGrid(assets: assets)
                .padding(.horizontal, MS.Spacing.md)
        }
    }

    private func flatGrid(assets: [MediaAsset]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: gridSize, maximum: gridSize + 40), spacing: MS.Spacing.sm)],
            spacing: MS.Spacing.sm
        ) {
            ForEach(assets) { asset in
                AssetGridCell(
                    asset: asset,
                    isSelected: selectedAsset?.id == asset.id,
                    size: gridSize
                ) {
                    selectedAsset = asset
                }
                .contextMenu {
                    if let score = asset.analysisScore {
                        Text("Score: \(Int(score * 100))%")
                        Divider()
                    }
                    Button("Remove from Project", role: .destructive) {
                        workspaceVM.removeAsset(asset)
                    }
                }
            }
        }
    }
}

// MARK: - AssetDetailSheet

struct AssetDetailSheet: View {
    let asset: MediaAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(asset.filename ?? "Asset")
                    .font(MS.Font.heading)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(MS.Spacing.md)
            MSDivider()

            ScrollView {
                VStack(spacing: MS.Spacing.md) {
                    // Thumbnail
                    AssetThumbnailView(asset: asset, size: 280, cornerRadius: MS.Radius.md)
                        .frame(maxWidth: .infinity)

                    // Scores
                    if let score = asset.analysisScore {
                        VStack(spacing: MS.Spacing.sm) {
                            MSSectionHeader(title: "Analysis Scores")
                            MSScoreBar(label: "Overall", value: score, color: .accentColor)
                            if let q = asset.qualityScore { MSScoreBar(label: "Quality", value: q, color: .blue) }
                            if let e = asset.emotionScore { MSScoreBar(label: "Emotion", value: e, color: .pink) }
                            if let n = asset.noveltyScore { MSScoreBar(label: "Novelty", value: n, color: .purple) }
                        }
                        .msCard()
                    }

                    // Metadata
                    VStack(spacing: MS.Spacing.sm) {
                        MSSectionHeader(title: "Metadata")
                        MSStatRow(label: "Type", value: asset.mediaType.rawValue, icon: asset.mediaType.icon)
                        if asset.duration > 0 {
                            MSStatRow(label: "Duration", value: asset.durationString, icon: "clock")
                        }
                        MSStatRow(label: "Resolution", value: "\(asset.pixelWidth)×\(asset.pixelHeight)", icon: "crop")
                        if let date = asset.creationDate {
                            MSStatRow(label: "Captured", value: DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short), icon: "calendar")
                        }
                        if let event = asset.eventLabel {
                            MSStatRow(label: "Event", value: event, icon: "tag")
                        }
                    }
                    .msCard()
                }
                .padding(MS.Spacing.md)
            }
        }
        .frame(width: 360, height: 580)
    }
}
