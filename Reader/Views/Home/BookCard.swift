import SwiftUI

struct BookCard: View {
    let book: Book
    let processingStatus: BookProcessingStatus?
    let onOpen: () -> Void
    let onProcess: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover with hover overlay
            ZStack(alignment: .topTrailing) {
                coverView
                    .frame(height: 260)
                    .clipped()

                // Process button overlay (appears on hover)
                if isHovered && !book.processedFully {
                    Button {
                        onProcess()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10, weight: .semibold))
                            Text(processingStatus == nil ? "Process" : "View Progress")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(theme.base)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(theme.rose)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                if let processingStatus {
                    processingBadge(status: processingStatus)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .transition(.opacity)
                }

                // Processed badge
                if book.processedFully {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(theme.foam)
                        .padding(8)
                        .transition(.opacity)
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.text)
                    .lineLimit(2)

                Text(book.author)
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
                    .lineLimit(1)

                // Progress
                HStack(spacing: 8) {
                    ProgressView(value: book.progressPercent)
                        .tint(theme.rose)
                        .scaleEffect(y: 0.6)

                    Text(book.displayProgress)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.subtle)
                }
            }
            .padding(12)
            .background(theme.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovered ? theme.rose.opacity(0.5) : theme.overlay, lineWidth: 1)
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .shadow(
            color: isHovered ? theme.rose.opacity(0.2) : .clear,
            radius: 12,
            y: 4
        )
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .zIndex(isHovered ? 1 : 0)  // Bring hovered card above siblings
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Open") { onOpen() }

            if !book.processedFully {
                Button("Process Full Book") { onProcess() }
            }

            Divider()

            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    private func processingBadge(status: BookProcessingStatus) -> some View {
        let percent = Int(status.progress * 100)
        let detail = status.totalChapters > 0
            ? "\(status.completedChapters)/\(status.totalChapters)"
            : "\(percent)%"
        return HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
            Text("Processing \(detail)")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(theme.base)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.rose)
        .clipShape(Capsule())
        .shadow(color: theme.rose.opacity(0.3), radius: 6, y: 2)
    }

    // MARK: - Cover View

    @ViewBuilder
    private var coverView: some View {
        if let coverURL = book.coverURL,
           let image = NSImage(contentsOf: coverURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // Placeholder
            ZStack {
                theme.overlay

                VStack(spacing: 8) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(theme.muted)

                    Text(book.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.subtle)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 12)
                }
            }
        }
    }
}
