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
            workspaceVM.activeImportVM = importVM
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
            Text("Library")
                .msEyebrow()
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
            .scrollContentBackground(.hidden)
        }
        .frame(width: 220)
        .background(MSColor.canvasDeep)
    }

    private func selectAlbum(_ album: MSAlbum?) {
        selectedAlbum = album
        Task { await importVM.selectAlbum(album) }
    }

    private func albumRow(label: String, icon: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.accentColor : MSColor.inkFaint)
                .frame(width: 16)
            Text(label)
                .font(MS.Font.body.weight(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? MSColor.inkBright : MSColor.inkMuted)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(MS.Font.mono)
                .foregroundStyle(MSColor.inkFaint)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            isSelected ? MSColor.surface2 : Color.clear,
            in: RoundedRectangle(cornerRadius: MS.Radius.md, style: .continuous)
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
                    .foregroundStyle(MSColor.inkFaint)
                TextField("Search media", text: $importVM.searchText)
                    .textFieldStyle(.plain)
                    .font(MS.Font.body)
                    .frame(width: 180)
                if !importVM.searchText.isEmpty {
                    Button {
                        importVM.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: MS.Height.controlSmall)
            .background(MSColor.canvas, in: RoundedRectangle(cornerRadius: MS.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MS.Radius.md, style: .continuous)
                    .strokeBorder(MSColor.lineStrong.opacity(0.75), lineWidth: 1)
            )

            // Filter
            Picker("Filter", selection: $importVM.filterType) {
                ForEach(AssetFilterType.allCases, id: \.self) { filter in
                    Image(systemName: filter.icon)
                        .help(filter.rawValue)
                        .tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            // Sort
            Picker("Sort", selection: $importVM.sortOrder) {
                ForEach(AssetSortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button("Select All") { importVM.selectAll() }
                .buttonStyle(.ms(.ghost, size: .small))
                .help("Select All Assets (⇧⌘A)")
            if importVM.hasSelection {
                Button("Deselect") { importVM.deselectAll() }
                    .buttonStyle(.ms(.ghost, size: .small))
                    .help("Deselect All Assets (⇧⌘D)")
            }

            Rectangle().fill(MSColor.line).frame(width: 1, height: 18)

            // Import from Photos picker
            MSSecondaryButton("Open Photos", icon: "photo.stack", size: .small) {
                showPhotoPicker = true
            }
        }
        .padding(.horizontal, MS.Spacing.md)
        .frame(height: MS.Height.bar)
        .background(MSColor.surface)
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
        .background(MSColor.canvas)
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
                HStack(spacing: MS.Spacing.sm) {
                    Text("\(importVM.selectionCount) selected")
                        .font(MS.Font.body.weight(.medium))
                        .foregroundStyle(MSColor.inkBright)
                        .monospacedDigit()
                    let photos = importVM.selectedAssets.filter { $0.mediaType == .photo || $0.mediaType == .livePhoto }.count
                    let videos = importVM.selectedAssets.filter { $0.mediaType == .video }.count
                    MSBadge(text: "\(photos) photo\(photos != 1 ? "s" : "")", size: .small)
                    MSBadge(text: "\(videos) video\(videos != 1 ? "s" : "")", size: .small)
                    Spacer()
                    MSPrimaryButton("Add to Project", icon: "arrow.right") {
                        workspaceVM.addAssets(importVM.selectedAssets)
                        workspaceVM.goToStage(.analysis)
                    }
                }
                .padding(.horizontal, MS.Spacing.md)
                .frame(height: 52)
                .background(MSColor.surface)
                .overlay(alignment: .top) { MSDivider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: importVM.hasSelection)
    }
}
