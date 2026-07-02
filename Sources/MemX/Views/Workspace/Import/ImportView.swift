import SwiftUI
import PhotosUI
import Photos

struct ImportView: View {
    @Environment(WorkspaceViewModel.self) private var workspaceVM
    @State private var importVM = ImportViewModel()
    @State private var showPhotoPicker = false
    @State private var selectedAlbum: MSAlbum? = nil
    @State private var photosPickerItems: [PhotosPickerItem] = []

    var body: some View {
        HStack(spacing: 0) {
            albumSidebar

            MSVerticalDivider()
                .frame(maxHeight: .infinity)

            // Main content
            VStack(spacing: 0) {
                importToolbar
                MSDivider()
                mainContent
            }
        }
        .task {
            await importVM.loadRecents()
            await importVM.loadAlbums()
        }
        .onChange(of: photosPickerItems) { _, items in
            let ids = items.compactMap { $0.itemIdentifier }
            Task { await importVM.handlePickerSelection(ids) }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photosPickerItems,
            maxSelectionCount: 500,
            matching: .any(of: [.images, .videos])
        )
        .safeAreaInset(edge: .bottom) {
            importBar
        }
    }

    // MARK: - Album Sidebar

    private var albumSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Albums")
                .font(MS.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, MS.Spacing.md)
                .padding(.top, MS.Spacing.md)
                .padding(.bottom, MS.Spacing.xs)

            List {
                // Recents row
                albumRow(
                    label: "Recents",
                    icon: "clock.fill",
                    count: importVM.recentAssets.count,
                    isSelected: selectedAlbum == nil
                ) {
                    selectAlbum(nil)
                }

                if importVM.isLoadingAlbums {
                    ForEach(0..<5, id: \.self) { _ in
                        MSSkeletonBlock(height: 14).padding(.leading, 8)
                    }
                } else {
                    ForEach(importVM.albums) { album in
                        albumRow(
                            label: album.title,
                            icon: album.type.icon,
                            count: album.count,
                            isSelected: selectedAlbum == album
                        ) {
                            selectAlbum(album)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 200)
    }

    private func selectAlbum(_ album: MSAlbum?) {
        selectedAlbum = album
        Task { await importVM.selectAlbum(album) }
    }

    private func albumRow(label: String, icon: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: MS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(label)
                .font(MS.Font.body)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(MS.Font.micro)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, MS.Spacing.sm)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: MS.Radius.xs, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Toolbar

    private var importToolbar: some View {
        HStack(spacing: MS.Spacing.sm) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search...", text: $importVM.searchText)
                    .textFieldStyle(.plain)
                    .font(MS.Font.body)
                    .frame(width: 160)
            }
            .padding(.horizontal, MS.Spacing.sm)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: MS.Radius.sm, style: .continuous))

            Divider().frame(height: 18)

            // Filter
            ForEach(AssetFilterType.allCases, id: \.self) { filter in
                Button {
                    importVM.filterType = filter
                } label: {
                    Image(systemName: filter.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(importVM.filterType == filter ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(filter.rawValue)
            }

            Divider().frame(height: 18)

            // Sort
            Picker("Sort", selection: $importVM.sortOrder) {
                ForEach(AssetSortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
            .font(MS.Font.caption)
            .frame(width: 120)

            Spacer()

            // Import from Photos picker
            MSSecondaryButton("Open Photos", icon: "photo.stack") {
                showPhotoPicker = true
            }

            if importVM.hasSelection {
                Text("\(importVM.selectionCount) selected")
                    .font(MS.Font.caption)
                    .foregroundStyle(.secondary)
                MSSecondaryButton("All") { importVM.selectAll() }
                MSSecondaryButton("None") { importVM.deselectAll() }
            }
        }
        .padding(.horizontal, MS.Spacing.md)
        .padding(.vertical, MS.Spacing.sm)
        .background(.bar)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        if importVM.isLoadingRecents && importVM.recentAssets.isEmpty {
            loadingGrid
        } else if importVM.visibleAssets.isEmpty {
            let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if authStatus == .denied || authStatus == .restricted {
                EmptyStateView(
                    icon: "photo.stack",
                    title: "Photos Access Denied",
                    subtitle: "Open Settings to grant MemX access to your Photos library.",
                    action: ("Open Settings", {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                    })
                )
            } else {
                EmptyStateView(
                    icon: "photo.stack",
                    title: "No Media Found",
                    subtitle: "No media match these filters.",
                    action: ("Open Photos", { showPhotoPicker = true })
                )
            }
        } else {
            assetGrid
        }
    }

    // MARK: - Asset Grid

    private var assetGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: MS.Spacing.sm)],
                spacing: MS.Spacing.sm
            ) {
                ForEach(importVM.visibleAssets) { asset in
                    AssetGridCell(
                        asset: asset,
                        isSelected: importVM.selectedAssetIDs.contains(asset.id),
                        size: 130
                    ) {
                        importVM.toggleSelection(asset)
                    }
                }
            }
            .padding(MS.Spacing.md)
        }
    }

    // MARK: - Skeleton Loading Grid

    private var loadingGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: MS.Spacing.sm)],
                spacing: MS.Spacing.sm
            ) {
                ForEach(0..<20, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 5) {
                        MSSkeletonBlock(height: 130, radius: MS.Radius.sm)
                        MSSkeletonBlock(width: 80, height: 10)
                        MSSkeletonBlock(width: 50, height: 8)
                    }
                }
            }
            .padding(MS.Spacing.md)
        }
    }

    // MARK: - Import Bar

    private var importBar: some View {
        Group {
            if importVM.hasSelection {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(importVM.selectionCount) asset\(importVM.selectionCount == 1 ? "" : "s") selected")
                            .font(MS.Font.heading)
                        let photos = importVM.selectedAssets.filter { $0.mediaType == .photo || $0.mediaType == .livePhoto }.count
                        let videos = importVM.selectedAssets.filter { $0.mediaType == .video }.count
                        Text("\(photos) photo\(photos != 1 ? "s" : ""), \(videos) video\(videos != 1 ? "s" : "")")
                            .font(MS.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    MSPrimaryButton("Add to Project", icon: "arrow.right.circle.fill") {
                        workspaceVM.addAssets(importVM.selectedAssets)
                        workspaceVM.goToStage(.analysis)
                    }
                }
                .padding(.horizontal, MS.Spacing.lg)
                .padding(.vertical, MS.Spacing.md)
                .background(.bar)
                .overlay(alignment: .top) { MSDivider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: importVM.hasSelection)
    }
}
