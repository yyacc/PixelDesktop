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
    @State private var showingPreview = false
    @State private var newItemName = ""
    @State private var searchText = ""
    @State private var itemToRename: StorageItem?
    @State private var itemToDelete: StorageItem?

    var filteredItems: [StorageItem] {
        if searchText.isEmpty {
            return appState.storageItems
        }
        return appState.storageItems.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

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

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter files", text: $searchText)
                    .textFieldStyle(.plain)
                    .help("Filter by filename")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.15))

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
                    onDownload: { showingSavePanel = true },
                    onPreview: {
                        showingPreview = true
                    }
                )
            }
        }
        .sheet(isPresented: $showingPreview) {
            if let item = selectedItem {
                FilePreviewView(item: item, appState: appState)
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
        VStack(alignment: .leading, spacing: 4) {
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

            // The actionable next step, shown only when the system is offline *and* knows why.
            // This is the point of ADR-017 Option C: "Offline" alone cannot tell the user whether
            // to reach for the USB cable or for the phone's Wireless Debugging toggle, and those
            // are different errands.
            if let action = statusAction {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)

                    Text(action)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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

            ForEach(filteredItems) { item in
                StorageItemRow(
                    item: item,
                    isSelected: selectedItem?.id == item.id
                ) {
                    handleItemTap(item)
                }
            }
        }
        .listStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            guard let url = url else { return }
            let filename = url.lastPathComponent
            let remotePath = currentPath + "/" + filename
            Task { await appState.uploadFile(localPath: url.path, remotePath: remotePath) }
        }
        return true
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
            // "Checking…" rather than "Offline": before the first discovery pass completes we
            // have no evidence either way, and claiming offline would be a guess.
            return appState.diagnosis?.summary ?? "Checking…"
        }
        return state.mode.displayName
    }

    /// What the user should do next, when the system is offline and the cause is known.
    private var statusAction: String? {
        guard appState.transportState == nil else { return nil }
        return appState.diagnosis?.action
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

// MARK: - File Preview

/// Quick-look style preview for a remote file.
///
/// Downloads the file to a temp location, then renders it as an image (for image formats),
/// text (for text formats), or a metadata-only fallback for unsupported types.
/// Files larger than 10 MB are not previewed.
struct FilePreviewView: View {
    let item: StorageItem
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var previewState: PreviewState = .loading

    enum PreviewState {
        case loading
        case image(NSImage)
        case text(String)
        case unavailable(String)
        case error(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.quaternary.opacity(0.1))

            Divider()

            // Content
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 500, minHeight: 400)
        .task {
            await loadPreview()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch previewState {
        case .loading:
            ProgressView("Loading preview...")
        case .image(let image):
            ScrollView {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding()
            }
        case .text(let text):
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .unavailable(let message):
            ContentUnavailableView(
                "Preview Unavailable",
                systemImage: "eye.slash",
                description: Text(message)
            )
        case .error(let message):
            ContentUnavailableView(
                "Error",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    private func loadPreview() async {
        // Don't preview files larger than 10 MB
        if item.size > 10_000_000 {
            previewState = .unavailable("File is too large to preview (\(byteCount(item.size))).")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + item.name)

        await appState.downloadFile(remotePath: item.path, localPath: tempURL.path)

        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            previewState = .error("Failed to download file for preview.")
            return
        }

        // Try image first
        if let image = NSImage(contentsOf: tempURL) {
            previewState = .image(image)
            return
        }

        // Try text (UTF-8)
        if let text = try? String(contentsOf: tempURL, encoding: .utf8), text.count < 100_000 {
            previewState = .text(text)
            return
        }

        // Try UTF-16
        if let text = try? String(contentsOf: tempURL, encoding: .utf16), text.count < 100_000 {
            previewState = .text(text)
            return
        }

        previewState = .unavailable("Preview not available for this file type.")
    }

    private func byteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
