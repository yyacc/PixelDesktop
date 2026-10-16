import SwiftUI

/// Displays the progress of an active file transfer.
///
/// ADB does not provide native progress reporting, so `StorageService` polls the
/// destination file size and reports inferred progress. This view renders that
/// progress as a bar with a percentage label.
struct StorageTransferView: View {
    let progress: StorageTransferProgress

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: progress.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(progress.direction == .upload ? .blue : .green)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(height: 6)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(progress.direction == .upload ? .blue : .green)
                            .frame(width: geometry.size.width * progress.fractionCompleted, height: 6)
                    }
                }
                .frame(height: 6)
            }

            Text(percentageText)
                .font(.caption)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var title: String {
        progress.direction == .upload ? "Uploading..." : "Downloading..."
    }

    private var percentageText: String {
        "\(Int(progress.fractionCompleted * 100))%"
    }
}
