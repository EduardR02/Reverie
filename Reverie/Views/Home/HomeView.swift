import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var books: [Book] = []
    @State private var showImportSheet = false
    @State private var dragOver = false

    // Process full book
    @State private var bookToProcess: Book?

    // Live streaming state for expanded progress card
    @State private var liveSummaryCount = 0
    @State private var liveInsightCount = 0
    @State private var liveQuizCount = 0
    @State private var liveImageCount = 0
    @State private var liveWordsPerInsight = 0
    @State private var processingStartTime: Date?
    @State private var summaryPhase = ""
    @State private var insightPhase = ""
    @State private var liveInputTokens = 0
    @State private var liveOutputTokens = 0

    // Import error handling
    @State private var importError: String?
    @State private var showImportError = false

    // Delete confirmation
    @State private var bookToDelete: Book?
    @State private var showDeleteConfirmation = false

    // Expanded cards grid (first row)
    private let expandedColumns = [
        GridItem(.adaptive(minimum: 160, maximum: 180), spacing: 24, alignment: .top)
    ]

    // Compact cards grid (remaining rows) - Tighter for focused look
    private let compactColumns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 12)
    ]

    var body: some View {
        ZStack {
            // Background
            theme.base.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header (always visible)
                header
                    .zIndex(10)

                // Content
                if books.isEmpty {
                    emptyState
                } else {
                    bookGrid
                }
            }

            // Drag overlay
            if dragOver {
                dragOverlay
            }
        }
        .onDrop(of: [.epub], isTargeted: $dragOver) { providers in
            handleDrop(providers)
            return true
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSheet(onImport: { url in
                Task { await importBook(url) }
            })
        }
        .sheet(item: $bookToProcess) { book in
            ProcessBookView(
                book: book,
                isProcessing: appState.isProcessingBook,
                progress: appState.processingProgress,
                currentChapter: appState.processingChapter,
                onStart: { range, includeContext in
                    startProcessing(book, range: range, includeContext: includeContext)
                },
                onClose: {
                    bookToProcess = nil
                },
                onStop: {
                    cancelProcessing()
                }
            )
        }
        .task {
            await loadBooks()
        }
        .onChange(of: appState.libraryRefreshTrigger) { _, _ in
            Task {
                await loadBooks()
            }
        }
        .alert("Import Error", isPresented: $showImportError) {
            Button("OK") { }
        } message: {
            Text(importError ?? "Unknown error")
        }
        .alert("Delete Book", isPresented: $showDeleteConfirmation, presenting: bookToDelete) { book in
            Button("Delete", role: .destructive) {
                deleteBook(book)
            }
            Button("Cancel", role: .cancel) {
                bookToDelete = nil
            }
        } message: { book in
            Text("Are you sure you want to delete '\(book.title)'? This will remove all associated data, including insights and images, and cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.text)

                    Text("\(books.count) books")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.muted)
                }

                Spacer()

                // AI Processing toggle
                AIProcessingToggle(
                    isEnabled: appState.settings.autoAIProcessingEnabled,
                    action: {
                        appState.settings.autoAIProcessingEnabled.toggle()
                        appState.settings.save()
                    }
                )

                // Stats button
                Button(action: { appState.openStats() }) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(theme.subtle)
                        .frame(width: 36, height: 36)
                        .background(theme.surface)
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("View reading stats")

                // Settings button
                Button(action: { appState.openSettings() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(theme.subtle)
                        .frame(width: 36, height: 36)
                        .background(theme.surface)
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)

                // Import button
                Button(action: { showImportSheet = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                        Text("Add Book")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.base)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(theme.rose)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
    }

    // MARK: - Book Grid

    private var bookGrid: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width - 64 // Account for horizontal padding
            let cardWidth: CGFloat = 160 // Use minimum to ensure row fills
            let spacing: CGFloat = 24
            let expandedCount = max(1, Int((availableWidth + spacing) / (cardWidth + spacing)))

            let displayBooks = books.filter { $0.id != appState.processingBookId }
            let expandedBooks = Array(displayBooks.prefix(expandedCount))
            let compactBooks = Array(displayBooks.dropFirst(expandedCount))

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Processing card at top when active
                    if appState.isProcessingBook,
                       let processingBook = books.first(where: { $0.id == appState.processingBookId }) {
                        processingCard(for: processingBook)
                            .padding(.horizontal, 32)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)),
                                removal: .opacity
                            ))
                    }

                    // First row: Expanded vertical cards
                    if !expandedBooks.isEmpty {
                        LazyVGrid(columns: expandedColumns, alignment: .leading, spacing: 24) {
                            ForEach(expandedBooks) { book in
                                bookCard(for: book, variant: .expanded)
                            }
                        }
                        .padding(.horizontal, 32)
                    }

                    // Remaining rows: Compact horizontal cards
                    if !compactBooks.isEmpty {
                        LazyVGrid(columns: compactColumns, alignment: .leading, spacing: 12) {
                            ForEach(compactBooks) { book in
                                bookCard(for: book, variant: .compact)
                            }
                        }
                        .padding(.horizontal, 32)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appState.isProcessingBook)
            }
        }
    }

    private func bookCard(for book: Book, variant: CardVariant) -> some View {
        BookCard(
            book: book,
            variant: variant
        ) {
            appState.openBook(book)
        } onProcess: {
            handleProcessRequest(book)
        } onDelete: {
            bookToDelete = book
            showDeleteConfirmation = true
        } onToggleFinished: {
            appState.toggleBookFinished(book)
            Task { await loadBooks() }
        }
    }

    // MARK: - Processing Card

    private func processingCard(for book: Book) -> some View {
        ExpandedProcessingCard(
            book: book,
            status: processingStatus(for: book) ?? BookProcessingStatus(progress: 0, completedChapters: 0, totalChapters: 0),
            summariesCompleted: liveSummaryCount,
            totalChapters: appState.processingTotalChapters,
            liveInsightCount: liveInsightCount,
            liveQuizCount: liveQuizCount,
            liveImageCount: liveImageCount,
            wordsPerInsight: liveWordsPerInsight,
            summaryPhase: summaryPhase,
            insightPhase: insightPhase,
            liveInputTokens: liveInputTokens,
            liveOutputTokens: liveOutputTokens,
            startTime: processingStartTime,
            onCancel: { cancelProcessing() },
            processingCost: appState.processingCostEstimate
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            // Icon
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.surface)
                .frame(width: 80, height: 80)
                .overlay {
                    Image(systemName: "book.closed")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(theme.rose)
                }

            VStack(spacing: 8) {
                Text("No books yet")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(theme.text)

                Text("Drop an EPUB file or click Add Book")
                    .font(.system(size: 14))
                    .foregroundColor(theme.muted)
            }

            Button(action: { showImportSheet = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("Add Book")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.base)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(theme.rose)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: - Drag Overlay

    private var dragOverlay: some View {
        ZStack {
            theme.base.opacity(0.9)

            VStack(spacing: 16) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(theme.rose)

                Text("Drop EPUB to import")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(theme.text)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Actions

    private func loadBooks() async {
        do {
            books = try appState.database.fetchAllBooks()
        } catch {
            print("Failed to load books: \(error)")
        }
    }

    private func processingStatus(for book: Book) -> BookProcessingStatus? {
        guard appState.isProcessingBook,
              let bookId = book.id,
              bookId == appState.processingBookId else {
            return nil
        }

        return BookProcessingStatus(
            progress: appState.processingProgress,
            completedChapters: appState.processingCompletedChapters,
            totalChapters: appState.processingTotalChapters
        )
    }

    private func handleProcessRequest(_ book: Book) {
        if appState.isProcessingBook {
            if let activeId = appState.processingBookId,
               let activeBook = books.first(where: { $0.id == activeId }) {
                bookToProcess = activeBook
            } else {
                bookToProcess = book
            }
            return
        }

        bookToProcess = book
    }

    private func startProcessing(_ book: Book, range: ClosedRange<Int>? = nil, includeContext: Bool = false) {
        guard !appState.isProcessingBook else { return }
        bookToProcess = nil  // Close sheet immediately
        
        let processor = BookProcessor(
            appState: appState,
            book: book,
            range: range,
            includeContext: includeContext,
            isSimulation: appState.settings.useSimulationMode
        )
        
        // Setup telemetry
        processor.onSummaryCountUpdate = { liveSummaryCount = $0 }
        processor.onInsightCountUpdate = { liveInsightCount = $0 }
        processor.onQuizCountUpdate = { liveQuizCount = $0 }
        processor.onImageCountUpdate = { liveImageCount = $0 }
        processor.onWordsPerInsightUpdate = { liveWordsPerInsight = $0 }
        processor.onUsageUpdate = { input, output in
            liveInputTokens = input
            liveOutputTokens = output
        }
        processor.onPhaseUpdate = { summary, insight in
            summaryPhase = summary
            insightPhase = insight
        }
        processor.onCostUpdate = { _ in } // appState.processingCostEstimate is updated by processor
        
        processingStartTime = Date()
        
        let previousTask = appState.processingTask
        previousTask?.cancel()
        appState.processingTask = Task { [previousTask] in
            if let previousTask {
                await previousTask.value
            }
            await processor.process()
            
            // Cleanup on finish
            processingStartTime = nil
            liveSummaryCount = 0
            liveInsightCount = 0
            liveQuizCount = 0
            liveImageCount = 0
            liveWordsPerInsight = 0
            liveInputTokens = 0
            liveOutputTokens = 0
            summaryPhase = ""
            insightPhase = ""
        }
    }

    private func cancelProcessing() {
        // Immediately hide the processing UI
        appState.isProcessingBook = false
        appState.processingBookId = nil
        // Cancel the task - it will finish in-flight requests silently
        appState.processingTask?.cancel()
    }

    private func deleteBook(_ book: Book) {
        do {
            guard let bookId = book.id else { return }

            // 1. Delete from database (cascade deletes chapters, annotations, etc.)
            try appState.database.deleteBook(book)

            // 2. Delete all physical assets
            let fileManager = FileManager.default
            
            // EPUB
            try? fileManager.removeItem(at: LibraryPaths.bookURL(for: bookId))
            
            // Cover
            if let coverPath = book.coverPath {
                try? fileManager.removeItem(atPath: coverPath)
            }

            // Publication extracted HTML
            try? fileManager.removeItem(at: LibraryPaths.publicationDirectory(for: bookId))

            // AI Generated Images folder
            try? fileManager.removeItem(at: LibraryPaths.imagesDirectory(for: bookId))

            // Reload books list
            Task {
                await loadBooks()
            }
        } catch {
            print("Failed to delete book: \(error)")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.epub.identifier) { url, error in
                guard let url = url else { return }

                // Copy to temp location (the provided URL is only valid during callback)
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: tempURL)

                Task { @MainActor in
                    await importBook(tempURL)
                }
            }
        }
    }

    private func importBook(_ url: URL) async {
        importError = nil

        // Start accessing security-scoped resource
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            // Validate file exists and is readable
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ImportError.fileNotFound
            }

            // Validate it's an EPUB (check for ZIP signature)
            let handle = try FileHandle(forReadingFrom: url)
            let header = handle.readData(ofLength: 4)
            try handle.close()

            guard header.count >= 4,
                  header[0] == 0x50, header[1] == 0x4B else {
                throw ImportError.notValidEPUB
            }

            try LibraryPaths.ensureDirectory(LibraryPaths.booksDirectory)
            try LibraryPaths.ensureDirectory(LibraryPaths.coversDirectory)
            try LibraryPaths.ensureDirectory(LibraryPaths.publicationsDirectory)

            let tempExtractDir = LibraryPaths.publicationsDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            var didMoveExtract = false
            defer {
                if !didMoveExtract {
                    try? FileManager.default.removeItem(at: tempExtractDir)
                }
            }

            let parser = EPUBParser()
            let (metadata, opfPath) = try await parser.parseMetadata(epubURL: url, destinationURL: tempExtractDir)

            // 1. Save initial book record to get ID
            var book = Book(
                title: metadata.title,
                author: metadata.author,
                coverPath: nil,
                epubPath: "", // Will update after moving
                chapterCount: metadata.chapters.count,
                importStatus: .metadataOnly
            )
            try appState.database.saveBook(&book)

            guard let bookId = book.id else {
                throw ImportError.bookSaveFailed
            }

            // 2. Move EPUB to app storage using ID
            let fileManager = FileManager.default
            let destURL = LibraryPaths.bookURL(for: bookId)

            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: url, to: destURL)
            
            // 3. Update book record with final path
            book.epubPath = destURL.path
            try appState.database.saveBook(&book)

            // 4. Move extracted publication
            let finalExtractDir = LibraryPaths.publicationDirectory(for: bookId)
            if fileManager.fileExists(atPath: finalExtractDir.path) {
                try fileManager.removeItem(at: finalExtractDir)
            }
            try fileManager.moveItem(at: tempExtractDir, to: finalExtractDir)
            didMoveExtract = true

            // 5. Save cover using ID
            if let cover = metadata.cover {
                let fileExtension = coverFileExtension(for: cover)
                let coverURL = LibraryPaths.coverURL(for: bookId, fileExtension: fileExtension)
                try cover.data.write(to: coverURL)
                book.coverPath = coverURL.path
                try appState.database.saveBook(&book)
            }

            // Reload UI immediately so card appears
            await loadBooks()
            
            // 6. Background chapter processing
            let finalBook = book
            Task.detached(priority: .userInitiated) {
                await appState.finalizeChapterImport(book: finalBook, metadata: metadata, opfPath: opfPath)
            }

        } catch let error as ImportError {
            importError = error.message
            showImportError = true
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
            showImportError = true
        }
    }

    enum ImportError: Error {
        case fileNotFound
        case notValidEPUB
        case bookSaveFailed

        var message: String {
            switch self {
            case .fileNotFound: return "File not found or inaccessible"
            case .notValidEPUB: return "Not a valid EPUB file"
            case .bookSaveFailed: return "Failed to save book to database"
            }
        }
    }

    private func coverFileExtension(for cover: EPUBParser.Cover) -> String {
        if let mediaType = cover.mediaType?.lowercased() {
            switch mediaType {
            case "image/jpeg": return "jpg"
            case "image/png": return "png"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/bmp": return "bmp"
            case "image/svg+xml": return "svg"
            default: break
            }
        }

        if cover.data.isJpeg() { return "jpg" }
        if cover.data.isPng() { return "png" }
        if cover.data.isGif() { return "gif" }
        if cover.data.isWebp() { return "webp" }
        if cover.data.isBmp() { return "bmp" }
        if cover.data.isSvg() { return "svg" }

        return "jpg"
    }

}

// MARK: - EPUB UTType Extension

extension UTType {
    static var epub: UTType {
        UTType(filenameExtension: "epub") ?? .data
    }
}
