import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var books: [Book] = []
    @State private var isLoading = false
    @State private var showImportSheet = false
    @State private var dragOver = false

    // Process full book
    @State private var bookToProcess: Book?

    // Live streaming state for expanded progress card
    @State private var liveSummaryCount = 0
    @State private var liveInsightCount = 0
    @State private var liveQuizCount = 0
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
        let previousTask = appState.processingTask
        previousTask?.cancel()
        appState.processingTask = Task { [previousTask] in
            if let previousTask {
                await previousTask.value
            }
            await processFullBook(book, range: range, includeContext: includeContext)
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
        isLoading = true
        importError = nil

        // Start accessing security-scoped resource
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
            isLoading = false
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
        case noChaptersFound
        case bookSaveFailed

        var message: String {
            switch self {
            case .fileNotFound: return "File not found or inaccessible"
            case .notValidEPUB: return "Not a valid EPUB file"
            case .noChaptersFound: return "No chapters found in EPUB"
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

        if isJpegData(cover.data) { return "jpg" }
        if isPngData(cover.data) { return "png" }
        if isGifData(cover.data) { return "gif" }
        if isWebpData(cover.data) { return "webp" }
        if isBmpData(cover.data) { return "bmp" }
        if isSvgData(cover.data) { return "svg" }

        return "jpg"
    }

    private func isJpegData(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(3))
        return bytes.count == 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
    }

    private func isPngData(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(8))
        return bytes.count == 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47
    }

    private func isGifData(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(4))
        return bytes.count == 4 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38
    }

    private func isWebpData(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        return bytes.count == 12
            && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46
            && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50
    }

    private func isBmpData(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(2))
        return bytes.count == 2 && bytes[0] == 0x42 && bytes[1] == 0x4D
    }

    private func isSvgData(_ data: Data) -> Bool {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        return text?.range(of: "<svg", options: .caseInsensitive) != nil
    }

    private struct InsightWorkItem {
        let chapter: Chapter
        let blocks: [ContentBlock]
        let contentWithBlocks: String
        let rollingSummary: String?
    }

    private func appendRollingSummary(_ existing: String?, summary: String) -> String? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        if let existing, !existing.isEmpty {
            return existing + "\n\n" + trimmed
        }
        return trimmed
    }

    private func processFullBook(_ book: Book, range: ClosedRange<Int>? = nil, includeContext: Bool = false) async {
        let isSimulation = false // Set to true to test UI without using tokens
        
        appState.isProcessingBook = true
        appState.processingBookId = book.id
        appState.processingProgress = 0
        appState.processingCompletedChapters = 0
        appState.processingTotalChapters = 0
        appState.processingChapter = "Preparing..."
        appState.processingCostEstimate = 0

        // Initialize streaming state
        liveSummaryCount = 0
        liveInsightCount = 0
        liveQuizCount = 0
        liveInputTokens = 0
        liveOutputTokens = 0
        summaryPhase = ""
        insightPhase = ""
        processingStartTime = Date()

        defer {
            appState.isProcessingBook = false
            appState.processingTask = nil
            appState.processingBookId = nil
            appState.processingChapter = ""
            // Reset streaming state
            liveSummaryCount = 0
            liveInsightCount = 0
            liveQuizCount = 0
            liveInputTokens = 0
            liveOutputTokens = 0
            summaryPhase = ""
            insightPhase = ""
            processingStartTime = nil
        }

        // Track all running insight tasks for true parallelism
        var runningInsightTasks: [Task<Void, Error>] = []
        var runningInsightCount = 0
        var lastInsightTitle: String?

        func updateInsightPhase() {
            guard runningInsightCount > 0 else {
                insightPhase = ""
                if summaryPhase.isEmpty {
                    appState.processingChapter = ""
                }
                return
            }

            let title = lastInsightTitle ?? "Insights"
            let suffix = runningInsightCount > 1 ? " (+\(runningInsightCount - 1) more)" : ""
            insightPhase = "\(title)\(suffix)"
            if summaryPhase.isEmpty {
                appState.processingChapter = "Insights: \(insightPhase)"
            }
        }

        func cancelAllInsightTasks() async {
            for task in runningInsightTasks {
                task.cancel()
            }
            for task in runningInsightTasks {
                _ = try? await task.value
            }
            runningInsightTasks.removeAll()
        }

        do {
            guard let bookId = book.id else { return }
            let allChapters = try appState.database.fetchChapters(for: book)
            
            // Filter by range if provided
            let effectiveRange = range ?? 0...(allChapters.count - 1)
            let chaptersInRange = allChapters.filter { effectiveRange.contains($0.index) }
            
            // Only count chapters that actually require processing for the total
            let chaptersToProcess = chaptersInRange.filter { !$0.shouldSkipAutoProcessing && !$0.processed }
            appState.processingTotalChapters = chaptersToProcess.count

            if chaptersToProcess.isEmpty {
                appState.processingProgress = 1.0
                summaryPhase = "Complete!"
                appState.processingChapter = "Complete!"
                return
            }

            let blockParser = ContentBlockParser()
            var rollingSummary: String?

            // Phase 1: Context building (if requested and starting mid-book)
            if includeContext && effectiveRange.lowerBound > 0 {
                appState.processingChapter = "Building context..."
                let contextChapters = allChapters.filter { $0.index < effectiveRange.lowerBound }
                
                for chapter in contextChapters {
                    if Task.isCancelled { return }
                    
                    if let existingSummary = chapter.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !existingSummary.isEmpty {
                        rollingSummary = appendRollingSummary(rollingSummary, summary: existingSummary)
                    } else if !chapter.shouldSkipAutoProcessing {
                        // Need to generate summary for context
                        summaryPhase = "Context: \(chapter.title)"
                        let (_, contentWithBlocks) = blockParser.parse(html: chapter.contentHTML)
                        let (generatedSummary, usage) = try await appState.llmService.generateSummary(
                            contentWithBlocks: contentWithBlocks,
                            rollingSummary: rollingSummary,
                            settings: appState.settings
                        )
                        if let usage {
                            liveInputTokens += usage.input
                            liveOutputTokens += usage.visibleOutput + (usage.reasoning ?? 0)
                        }
                        
                        // Save summary for future use
                        var updatedChapter = chapter
                        updatedChapter.summary = generatedSummary
                        updatedChapter.rollingSummary = rollingSummary
                        try appState.database.saveChapter(&updatedChapter)
                        
                        rollingSummary = appendRollingSummary(rollingSummary, summary: generatedSummary)
                    }
                }
            } else if effectiveRange.lowerBound > 0 {
                // Not building context, but we might still want to reuse existing summaries for rolling context if they exist
                let previousChapters = allChapters.filter { $0.index < effectiveRange.lowerBound }
                for chapter in previousChapters {
                    if let existingSummary = chapter.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !existingSummary.isEmpty {
                        rollingSummary = appendRollingSummary(rollingSummary, summary: existingSummary)
                    }
                }
            }

            // Phase 2: Processing range
            liveSummaryCount = 0
            appState.processingCompletedChapters = 0
            
            for chapter in chaptersInRange {
                if Task.isCancelled {
                    await cancelAllInsightTasks()
                    return
                }

                if chapter.shouldSkipAutoProcessing {
                    continue
                }

                if chapter.processed {
                    if let summary = chapter.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !summary.isEmpty {
                        rollingSummary = appendRollingSummary(rollingSummary, summary: summary)
                    }
                    continue
                }

                // Update summary phase UI
                summaryPhase = chapter.title
                appState.processingChapter = "Summarizing: \(chapter.title)"
                appState.processingProgress = Double(appState.processingCompletedChapters)
                    / Double(max(1, appState.processingTotalChapters))

                let (blocks, contentWithBlocks) = blockParser.parse(html: chapter.contentHTML)
                let chapterRollingSummary = rollingSummary

                let existingSummary = chapter.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
                let reuseSummary = (existingSummary?.isEmpty == false) && chapter.rollingSummary == chapterRollingSummary
                let summary: String
                if reuseSummary {
                    summary = existingSummary ?? ""
                } else if isSimulation {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // Simulate 1s latency
                    summary = "This is a simulated summary for chapter \(chapter.index + 1). Simulation mode is active."
                    liveInputTokens += 1000
                    liveOutputTokens += 500
                    appState.processingCostEstimate += 0.02
                } else {
                    let (generatedSummary, usage) = try await appState.llmService.generateSummary(
                        contentWithBlocks: contentWithBlocks,
                        rollingSummary: chapterRollingSummary,
                        settings: appState.settings
                    )
                    summary = generatedSummary
                    if let usage {
                        liveInputTokens += usage.input
                        liveOutputTokens += usage.visibleOutput + (usage.reasoning ?? 0)
                    }
                }

                var updatedChapter = chapter
                updatedChapter.summary = summary
                updatedChapter.rollingSummary = chapterRollingSummary
                updatedChapter.contentText = contentWithBlocks
                updatedChapter.blockCount = blocks.count
                if !isSimulation {
                    try appState.database.saveChapter(&updatedChapter)
                }

                liveSummaryCount += 1
                rollingSummary = appendRollingSummary(rollingSummary, summary: summary)

                if Task.isCancelled {
                    await cancelAllInsightTasks()
                    return
                }

                // Fire insight task in parallel - DO NOT AWAIT
                let workItem = InsightWorkItem(
                    chapter: updatedChapter,
                    blocks: blocks,
                    contentWithBlocks: contentWithBlocks,
                    rollingSummary: chapterRollingSummary
                )
                let chapterTitle = chapter.title
                lastInsightTitle = chapterTitle
                runningInsightCount += 1
                updateInsightPhase()

                let task = Task { @MainActor in
                    defer {
                        runningInsightCount -= 1
                        updateInsightPhase()
                    }
                    guard let chapterId = workItem.chapter.id else { return }
                    
                    let analysis = try await processInsights(
                        for: workItem,
                        bookId: bookId,
                        bookTitle: book.title,
                        author: book.author,
                        isSimulation: isSimulation
                    )

                    if !isSimulation, let analysis {
                        try appState.database.saveAnalysis(analysis, chapterId: chapterId, blockCount: workItem.blocks.count)
                        
                        await generateSuggestedImages(
                            analysis.imageSuggestions,
                            blockCount: workItem.blocks.count,
                            bookId: bookId,
                            chapterId: chapterId
                        )

                        var updatedChapter = workItem.chapter
                        updatedChapter.processed = true
                        if updatedChapter.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                            updatedChapter.summary = analysis.summary
                        }
                        updatedChapter.contentText = workItem.contentWithBlocks
                        updatedChapter.blockCount = workItem.blocks.count
                        try appState.database.saveChapter(&updatedChapter)
                    }
                    
                    appState.processingCompletedChapters += 1
                    appState.processingProgress = Double(appState.processingCompletedChapters)
                        / Double(max(1, appState.processingTotalChapters))
                }
                runningInsightTasks.append(task)

                // Continue to next summary immediately - don't await insights!
            }

            // All summaries done, now wait for remaining insight tasks
            summaryPhase = ""
            updateInsightPhase()
            if insightPhase.isEmpty {
                appState.processingChapter = "Finalizing..."
            }

            for task in runningInsightTasks {
                if Task.isCancelled {
                    await cancelAllInsightTasks()
                    return
                }
                do {
                    try await task.value
                } catch is CancellationError {
                    await cancelAllInsightTasks()
                    return
                } catch {
                    print("Insight task failed: \(error)")
                }
            }

            // Mark book as fully processed if all eligible chapters are done
            if !isSimulation {
                let freshChapters = (try? appState.database.fetchChapters(for: book)) ?? []
                let allEligibleDone = freshChapters.filter { !$0.shouldSkipAutoProcessing }.allSatisfy { $0.processed }
                
                if allEligibleDone {
                    if var updatedBook = try? appState.database.fetchAllBooks().first(where: { $0.id == book.id }) {
                        updatedBook.processedFully = true
                        try appState.database.saveBook(&updatedBook)
                    }
                }
            }

            appState.processingProgress = 1.0
            insightPhase = ""
            appState.processingChapter = "Complete!"

            await loadBooks()

        } catch {
            await cancelAllInsightTasks()
            if error is CancellationError {
                return
            }
            print("Failed to process book: \(error)")
        }
    }

    @MainActor
    private func processInsights(
        for workItem: InsightWorkItem,
        bookId: Int64,
        bookTitle: String?,
        author: String?,
        isSimulation: Bool
    ) async throws -> LLMService.ChapterAnalysis? {
        var analysis: LLMService.ChapterAnalysis?

        if isSimulation {
            // Simulate a stream of events
            for i in 1...5 {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 100_000_000...500_000_000))
                if Task.isCancelled { throw CancellationError() }
                
                if i % 2 == 0 {
                    liveInsightCount += 1
                } else if i == 5 {
                    liveQuizCount += 1
                }
                
                liveInputTokens += Int.random(in: 1000...3000)
                liveOutputTokens += Int.random(in: 500...1500)
                appState.processingCostEstimate += Double.random(in: 0.01...0.05)
            }
            
            analysis = LLMService.ChapterAnalysis(
                annotations: [
                    LLMService.AnnotationData(
                        type: "science",
                        title: "Simulated Science Insight",
                        content: "This is a simulated insight content for chapter \(workItem.chapter.index + 1).",
                        sourceBlockId: 1
                    )
                ],
                quizQuestions: [
                    LLMService.QuizData(
                        question: "Simulated question for chapter \(workItem.chapter.index + 1)?",
                        answer: "Simulated answer.",
                        sourceBlockId: 1
                    )
                ],
                imageSuggestions: [],
                summary: "Simulated summary for chapter \(workItem.chapter.index + 1)."
            )
        } else {
            // Use streaming API for live telemetry
            let stream = appState.llmService.analyzeChapterStreaming(
                contentWithBlocks: workItem.contentWithBlocks,
                rollingSummary: workItem.rollingSummary,
                bookTitle: bookTitle,
                author: author,
                settings: appState.settings
            )

            for try await event in stream {
                if Task.isCancelled { throw CancellationError() }

                switch event {
                case .thinking:
                    break  // Not displaying thinking in takeover view
                case .insightFound:
                    liveInsightCount += 1
                case .quizQuestionFound:
                    liveQuizCount += 1
                case .usage(let usage):
                    liveInputTokens += usage.input
                    liveOutputTokens += usage.visibleOutput + (usage.reasoning ?? 0)
                case .completed(let result):
                    analysis = result
                }
            }
        }

        if Task.isCancelled { throw CancellationError() }

        return analysis
    }

    private func generateSuggestedImages(
        _ suggestions: [LLMService.ImageSuggestion],
        blockCount: Int,
        bookId: Int64,
        chapterId: Int64
    ) async {
        guard appState.settings.imagesEnabled, !suggestions.isEmpty else { return }
        if Task.isCancelled { return }

        let trimmedKey = appState.settings.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            print("Skipping image generation: missing Google API key.")
            return
        }

        let inputs = imageInputs(
            from: suggestions,
            blockCount: blockCount,
            rewrite: appState.settings.rewriteImageExcerpts
        )
        let results = await appState.imageService.generateImages(
            from: inputs,
            model: appState.settings.imageModel,
            apiKey: trimmedKey,
            maxConcurrent: 5
        )
        if Task.isCancelled { return }

        await storeGeneratedImages(
            results,
            bookId: bookId,
            chapterId: chapterId
        )
    }

    private func imageInputs(
        from suggestions: [LLMService.ImageSuggestion],
        blockCount: Int,
        rewrite: Bool
    ) -> [ImageService.ImageSuggestionInput] {
        suggestions.map { suggestion in
            let validBlockId = suggestion.sourceBlockId > 0 && suggestion.sourceBlockId <= blockCount
                ? suggestion.sourceBlockId : 1
            let excerpt = suggestion.excerpt
            let prompt = appState.llmService.imagePromptFromExcerpt(excerpt, rewrite: rewrite)
            return ImageService.ImageSuggestionInput(
                excerpt: excerpt,
                prompt: prompt,
                sourceBlockId: validBlockId
            )
        }
    }

    private func storeGeneratedImages(
        _ results: [ImageService.GeneratedImageResult],
        bookId: Int64,
        chapterId: Int64
    ) async {
        for result in results {
            if Task.isCancelled { return }
            do {
                let imagePath = try appState.imageService.saveImage(
                    result.imageData,
                    for: bookId,
                    chapterId: chapterId
                )
                var image = GeneratedImage(
                    chapterId: chapterId,
                    prompt: result.excerpt,
                    imagePath: imagePath,
                    sourceBlockId: result.sourceBlockId
                )
                try appState.database.saveImage(&image)
                appState.readingStats.recordImage()
            } catch {
                print("Failed to save image: \(error)")
            }
        }
    }
}

// MARK: - EPUB UTType Extension

extension UTType {
    static var epub: UTType {
        UTType(filenameExtension: "epub") ?? .data
    }
}
