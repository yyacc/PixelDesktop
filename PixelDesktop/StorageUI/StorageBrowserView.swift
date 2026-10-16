import SwiftUI
import UniformTypeIdentifiers

/// The remote storage file browser for the Pixel 7a.
///
/// ## What this view does
///
/// Displays the contents of `/sdcard/PixelDesktop/` on the connected Pixel 7a and lets the
/// user perform file operations: browse folders, upload, download, delete, create folders,
/// and rename. All operations go through `StorageService`, which wraps ADB.
///
/// ## Connection state
///
/// The view renders the current transport state (wired/wireless/offline) and disables
/// operations when no device is connected. The storage root cannot be deleted or renamed.
///
/// ## Transfer progress
///
/// Active transfers are shown as an overlay with a progress bar. ADB does not provide
/// native progress, so `StorageService` polls the destination file size and reports
/// inferred progress.
struct StorageBrowserView: View {
    @EnvironmentObject var appState: AppState

    @State private var pathStack: [String] = []
    @State private var selectedItem: StorageItem?
    @State private var showingFileImporter = false
    @State private var showingSavePanel = false
    @State private var showingNewFolderAlert = false
    @State private var showingRenameAlert = false
    @State private var showingDeleteConfirmation = false
    @State private var newItemName = ""
    @State private var itemToRename: StorageItem?
    @State private var itemToDelete: StorageItem?

    private var currentPath: String {
        pathStack.last ?? StorageService.storageRoot
    }

    private var isAtRoot: Bool {
        pathStack.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionStatusBar
            Divider()

            if let progress = appState.storageTransferProgress, !progress.isComplete {
                StorageTransferView(progress: progress)
                Divider()
            }

            contentView
        }
        .navigationTitle("Storage")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                StorageToolbarView(
                    selectedItem: selectedItem,
                    isAtRoot: isAtRoot,
                    onUpload: { showingFileImporter = true },
                    onNewFolder: { showingNewFolderAlert = true },
                    onDelete: {
                        itemToDelete = selectedItem
                        showingDeleteConfirmation = true
                    },
                    onRename: {
                        itemToRename = selectedItem
                        showingRenameAlert = true
                    },
                    onDownload: { showingSavePanel = true }
                )
            }
        }
        .task(id: appState.selectedSerial) {
            await appState.ensureStorageRoot()
            await appState.loadStorageItems(path: currentPath)
            await appState.refreshStorageDiskSpace()
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .background(
            SavePanelPresenter(
                isPresented: $showingSavePanel,
                filename: selectedItem?.name ?? "download",
                onSave: { url in
                    if let item = selectedItem {
                        Task { await appState.downloadFile(remotePath: item.path, localPath: url.path) }
                    }
                }
            )
        )
        .alert("New Folder", isPresented: $showingNewFolderAlert) {
            TextField("Folder name", text: $newItemName)
            Button("Create") {
                createFolder()
            }
            Button("Cancel", role: .cancel) {
                newItemName = ""
            }
        } message: {
            Text("Enter a name for the new folder.")
        }
        .alert("Rename Item", isPresented: $showingRenameAlert) {
            TextField("New name", text: $newItemName)
            Button("Rename") {
                renameItem()
            }
            Button("Cancel", role: .cancel) {
                newItemName = ""
            }
        } message: {
            Text("Enter a new name for \(itemToRename?.name ?? "").")
        }
        .confirmationDialog(
            "Delete \(itemToDelete?.name ?? "item")?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteItem()
            }
            Button("Cancel", role: .cancel) {
                itemToDelete = nil
            }
        } message: {
            Text("This will permanently delete this item from the Pixel 7a. This action cannot be undone.")
        }
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        if appState.storageIsLoading {
            ProgressView("Loading...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = appState.storageError {
            errorState(error)
        } else if appState.storageItems.isEmpty {
            emptyState
        } else {
            fileList
        }
    }

    // MARK: - Connection Status Bar

    private var connectionStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption)

            Spacer()

            if let diskSpace = appState.storageDiskSpace {
                Text("Storage: \(byteCount(diskSpace.used)) of \(byteCount(diskSpace.total)) used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.2))
    }

    // MARK: - File List

    private var fileList: some View {
        List {
            if !isAtRoot {
                Button {
                    navigateUp()
                } label: {
                    HStack {
                        Image(systemName: "arrow.up")
                        Text("..")
                            .font(.body)
                    }
                }
                .buttonStyle(.plain)
            }

            ForEach(appState.storageItems) { item in
                StorageItemRow(
                    item: item,
                    isSelected: selectedItem?.id == item.id
                ) {
                    handleItemTap(item)
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            "Empty Folder",
            systemImage: "folder",
            description: Text("This folder is empty. Use the toolbar to upload files or create a new folder.")
        )
    }

    // MARK: - Error State

    private func errorState(_ error: StorageError) -> some View {
        ContentUnavailableView(
            "Storage Error",
            systemImage: "exclamationmark.triangle",
            description: Text(error.description)
        )
    }

    // MARK: - Actions

    private func handleItemTap(_ item: StorageItem) {
        if item.isDirectory {
            pathStack.append(item.path)
            selectedItem = nil
            Task { await appState.loadStorageItems(path: item.path) }
        } else {
            selectedItem = item
        }
    }

    private func navigateUp() {
        guard !isAtRoot else { return }
        pathStack.removeLast()
        selectedItem = nil
        Task { await appState.loadStorageItems(path: currentPath) }
    }

    private func createFolder() {
        let name = newItemName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let path = currentPath + "/" + name
        newItemName = ""
        Task { await appState.createStorageFolder(path: path) }
    }

    private func renameItem() {
        guard let item = itemToRename else { return }
        let name = newItemName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let parentPath = (item.path as NSString).deletingLastPathComponent
        let newPath = parentPath + "/" + name
        newItemName = ""
        let oldItem = item
        itemToRename = nil
        Task { await appState.renameStorageItem(from: oldItem.path, to: newPath) }
    }

    private func deleteItem() {
        guard let item = itemToDelete else { return }
        itemToDelete = nil
        selectedItem = nil
        Task { await appState.deleteStorageItem(path: item.path) }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let remotePath = currentPath + "/" + url.lastPathComponent
            Task { await appState.uploadFile(localPath: url.path, remotePath: remotePath) }
        case .failure(let error):
            appState.storageError = .unknown(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        appState.transportState != nil ? .green : .red
    }

    private var statusText: String {
        guard let state = appState.transportState else {
            return "Offline"
        }
        return state.mode.displayName
    }

    private func byteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Storage Item Row

struct StorageItemRow: View {
    let item: StorageItem
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.isDirectory ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)

                HStack(spacing: 12) {
                    if !item.isDirectory {
                        Text(byteCount(item.size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let date = item.modifiedDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .padding(.vertical, 2)
    }

    private func byteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Save Panel Presenter

/// Wraps `NSSavePanel` for use in SwiftUI. Presents the panel when `isPresented` becomes
/// true and calls `onSave` with the chosen URL.
struct SavePanelPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let filename: String
    let onSave: (URL) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isPresented else { return }
        isPresented = false

        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = filename
            panel.allowedContentTypes = [.item]
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    onSave(url)
                }
            }
        }
    }
}
