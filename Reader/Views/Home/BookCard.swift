import SwiftUI

struct BookCard: View {
    let book: Book
    let processingStatus: BookProcessingStatus?
    let onOpen: () -> Void
    let onProcess: () -> Void
    let onDelete: () -> Void
    let onToggleFinished: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover with hover overlays
            ZStack(alignment: .topTrailing) {
                coverView
                    .frame(height: 260)
                    .clipped()

                // Top Toolbar (Process + Status)
                HStack(alignment: .top) {
                    // LEFT: Process Button
                    Button {
                        onProcess()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.base)
                            .frame(width: 32, height: 32)
                            .background(theme.rose)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered && !book.processedFully && processingStatus == nil ? 1 : 0)
                    .scaleEffect(isHovered && !book.processedFully && processingStatus == nil ? 1 : 0.8)

                    Spacer()

                    // RIGHT: Status area
                    HStack(spacing: 8) {
                        // Subtle "Processed" indicator
                        if book.processedFully && !isHovered {
                            Image(systemName: "sparkles.rectangle.stack.fill")
                                .font(.system(size: 12))
                                .foregroundColor(theme.rose)
                                .shadow(color: .black.opacity(0.4), radius: 2)
                        }
                        
                        // The "Finished" Toggle Button
                        Button {
                            onToggleFinished()
                        } label: {
                            Image(systemName: book.isFinished ? "checkmark.seal.fill" : "checkmark.seal")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(book.isFinished ? theme.foam : theme.base)
                                .frame(width: 32, height: 32)
                                .background(
                                    book.isFinished ? theme.foam.opacity(0.2) : theme.rose
                                )
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(book.isFinished ? 0 : 0.2), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .opacity(book.isFinished || isHovered ? 1 : 0)
                        .scaleEffect(book.isFinished || isHovered ? 1 : 0.8)
                    }
                }
                .padding(8)

                // BOTTOM-LEADING: Active Processing Badge
                if let processingStatus {
                    processingBadge(status: processingStatus)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }

            // Info section unchanged
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.text)
                    .lineLimit(2)

                HStack {
                    Text(book.author)
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    if book.isFinished {
                        Text("FINISHED")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(theme.foam)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(theme.foam.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                // Progress
                HStack(spacing: 8) {
                    ProgressView(value: book.isFinished ? 1.0 : book.progressPercent)
                        .tint(book.isFinished ? theme.foam : theme.rose)
                        .scaleEffect(y: 0.6)

                    Text(book.isFinished ? "100%" : book.displayProgress)
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
                .stroke(isHovered ? (book.isFinished ? theme.foam : theme.rose).opacity(0.5) : theme.overlay, lineWidth: 1)
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .shadow(
            color: isHovered ? (book.isFinished ? theme.foam : theme.rose).opacity(0.2) : .clear,
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
            
            Button(book.isFinished ? "Mark as Unread" : "Mark as Finished") {
                onToggleFinished()
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
