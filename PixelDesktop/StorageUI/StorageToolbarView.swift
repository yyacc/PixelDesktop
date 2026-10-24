import SwiftUI

/// Toolbar for the storage browser.
///
/// Provides the primary actions for file management: upload, new folder, delete,
/// rename, and download. Buttons are enabled/disabled based on the current selection
/// and navigation state.
struct StorageToolbarView: View {
    let selectedItem: StorageItem?
    let isAtRoot: Bool
    let onUpload: () -> Void
    let onNewFolder: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void
    let onDownload: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onUpload) {
                Label("Upload", systemImage: "arrow.up.doc")
            }
            .help("Upload a file to the current folder (⌘U)")
            .keyboardShortcut("u", modifiers: .command)

            Button(action: onNewFolder) {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("Create a new folder (⌘N)")
            .keyboardShortcut("n", modifiers: .command)

            Divider()
                .frame(height: 20)

            Button(action: onDownload) {
                Label("Download", systemImage: "arrow.down.doc")
            }
            .disabled(selectedItem == nil || selectedItem?.isDirectory == true)
            .help("Download the selected file (⌘D)")
            .keyboardShortcut("d", modifiers: .command)

            Button(action: onPreview) {
                Label("Preview", systemImage: "eye")
            }
            .disabled(selectedItem == nil || selectedItem?.isDirectory == true)
            .help("Preview the selected file (⌘P)")
            .keyboardShortcut("p", modifiers: .command)

            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(selectedItem == nil)
            .help("Rename the selected item")
            .keyboardShortcut("r", modifiers: .command)

            Button(action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedItem == nil)
            .help("Delete the selected item (⌘⌫)")
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }
}
