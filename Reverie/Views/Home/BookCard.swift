import SwiftUI

enum CardVariant {
    case expanded  // First row - tall vertical cards with full covers
    case compact   // Remaining rows - small horizontal cards
}

struct BookCard: View {
    let book: Book
    let variant: CardVariant
    let onOpen: () -> Void
    let onProcess: () -> Void
    let onDelete: () -> Void
    let onToggleFinished: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    init(
        book: Book,
        variant: CardVariant = .expanded,
        onOpen: @escaping () -> Void,
        onProcess: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onToggleFinished: @escaping () -> Void
    ) {
        self.book = book
        self.variant = variant
        self.onOpen = onOpen
        self.onProcess = onProcess
        self.onDelete = onDelete
        self.onToggleFinished = onToggleFinished
    }

    private var accentColor: Color {
        book.isFinished ? theme.foam : theme.rose
    }

    var body: some View {
        Group {
            switch variant {
            case .expanded:
                expandedCard
            case .compact:
                compactCard
            }
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: variant == .expanded ? 10 : 8))
        .overlay {
            RoundedRectangle(cornerRadius: variant == .expanded ? 10 : 8)
                .stroke(
                    isHovered ? accentColor.opacity(0.4) : theme.overlay,
                    lineWidth: 1
                )
        }
        .shadow(
            color: isHovered ? accentColor.opacity(0.15) : .black.opacity(0.08),
            radius: isHovered ? 16 : 4,
            y: isHovered ? 6 : 2
        )
        .zIndex(isHovered ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onOpen)
        .contextMenu { contextMenuContent }
    }

    // MARK: - Expanded Card (First Row)

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover area with fixed 2:3 aspect ratio
            coverContainer

            // Info section
            VStack(alignment: .leading, spacing: 6) {
                // Title
                Text(book.title)
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundColor(theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 36, alignment: .topLeading)

                // Author + finished badge
                HStack(spacing: 6) {
                    Text(book.author)
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if book.isFinished {
                        finishedBadge
                    }
                }

                // Progress bar
                progressBar
            }
            .padding(12)
        }
    }

    private var coverContainer: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay {
                ZStack {
                    // Cover image
                    BookCoverView(coverURL: book.coverURL, title: book.title)

                    // Hover overlay with action buttons
                    if isHovered {
                        LinearGradient(
                            colors: [.black.opacity(0.4), .clear, .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                        .allowsHitTesting(false)
                    }

                    // Top toolbar
                    VStack {
                        HStack(alignment: .top, spacing: 6) {
                            if !book.processedFully {
                                processButton
                                    .opacity(isHovered ? 1 : 0)
                            }

                            Spacer()

                            HStack(spacing: 6) {
                                if book.processedFully && !isHovered {
                                    processedIndicator
                                }
                                finishedButton
                                    .opacity(book.isFinished || isHovered ? 1 : 0)
                            }
                        }
                        .padding(8)

                        Spacer()
                    }
                }
            }
            .clipped()
    }

    // MARK: - Compact Card (Remaining Rows)

    private var compactCard: some View {
        HStack(spacing: 0) {
            // Small cover
            BookCoverView(coverURL: book.coverURL, title: book.title, isCompact: true)
                .frame(width: 52)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Title - allows 2 lines
                Text(book.title)
                    .font(.system(size: 13, weight: .medium, design: .serif))
                    .foregroundColor(theme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Author
                Text(book.author)
                    .font(.system(size: 11))
                    .foregroundColor(theme.muted)
                    .lineLimit(1)

                Spacer(minLength: 4)

                // Progress row
                HStack(spacing: 8) {
                    // Thin progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(theme.overlay)

                            Capsule()
                                .fill(accentColor.opacity(0.8))
                                .frame(width: geo.size.width * (book.isFinished ? 1.0 : book.progressPercent))
                                .animation(.easeOut(duration: 0.6), value: book.progressPercent)
                                .animation(.easeOut(duration: 0.6), value: book.isFinished)
                        }
                    }
                    .frame(height: 3)

                    // Status indicators
                    HStack(spacing: 4) {
                        if book.processedFully {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(theme.subtle)
                        }

                        if book.isFinished {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(theme.foam)
                        }
                    }
                    .frame(width: 24, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(height: 76)
    }

    // MARK: - Shared Components

    @ViewBuilder
    private var contextMenuContent: some View {
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

    private var processButton: some View {
        Button {
            onProcess()
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var processedIndicator: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(accentColor)
            .frame(width: 18, height: 18)
            .background(.ultraThinMaterial.opacity(0.6))
            .clipShape(Circle())
    }

    private var finishedButton: some View {
        Button {
            onToggleFinished()
        } label: {
            Image(systemName: book.isFinished ? "checkmark.seal.fill" : "checkmark.seal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var finishedBadge: some View {
        Text("DONE")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundColor(theme.foam)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(theme.foam.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.overlay)

                    Capsule()
                        .fill(accentColor)
                        .frame(width: geo.size.width * (book.isFinished ? 1.0 : book.progressPercent))
                        .animation(.easeOut(duration: 0.6), value: book.progressPercent)
                        .animation(.easeOut(duration: 0.6), value: book.isFinished)
                }
            }
            .frame(height: 4)

            Text(book.isFinished ? "100%" : book.displayProgress)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(theme.subtle)
                .frame(width: 32, alignment: .trailing)
        }
    }
}

// MARK: - Stable Cover View

struct BookCoverView: View {
    let coverURL: URL?
    let title: String
    var isCompact: Bool = false
    
    @Environment(\.theme) private var theme
    @State private var image: NSImage?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            theme.overlay

            if let image {
                GeometryReader { geo in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                // Placeholder
                VStack(spacing: isCompact ? 4 : 8) {
                    Image(systemName: "book.closed")
                        .font(.system(size: isCompact ? 18 : 28, weight: .light))
                        .foregroundColor(theme.muted)

                    if !isCompact {
                        Text(title)
                            .font(.system(size: 11, weight: .medium, design: .serif))
                            .foregroundColor(theme.subtle)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 12)
                    }
                }
            }
        }
        .task(id: coverURL) {
            // Only load if the URL actually changed or we don't have an image
            guard coverURL != loadedURL || image == nil else { return }
            
            if let url = coverURL {
                // Load off-thread to keep UI responsive
                if let loaded = await Task.detached(priority: .userInitiated, operation: {
                    NSImage(contentsOf: url)
                }).value {
                    await MainActor.run {
                        self.image = loaded
                        self.loadedURL = url
                    }
                }
            }
        }
    }
}