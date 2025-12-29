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
    @State private var isProcessingBook = false
    @State private var processingProgress: Double = 0
    @State private var processingChapter: String = ""
    @State private var processingBookId: Int64?
    @State private var processingTotalChapters: Int = 0
    @State private var processingCompletedChapters: Int = 0
    @State private var processingTask: Task<Void, Never>?

    // Import error handling
    @State private var importError: String?
    @State private var showImportError = false

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 24)
    ]

    var body: some View {
        ZStack {
            // Background
            theme.base.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                header
                    .zIndex(10)  // Keep header above cards

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
            ProcessBookSheet(
                book: book,
                isProcessing: $isProcessingBook,
                progress: $processingProgress,
                currentChapter: $processingChapter,
                onStart: {
                    startProcessing(book)
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
        .alert("Import Error", isPresented: $showImportError) {
            Button("OK") { }
        } message: {
            Text(importError ?? "Unknown error")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.text)

                    Text("\(books.count) books")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.muted)
                }

                Spacer()

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
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(books) { book in
                    BookCard(
                        book: book,
                        processingStatus: processingStatus(for: book)
                    ) {
                        appState.openBook(book)
                    } onProcess: {
                        handleProcessRequest(book)
                    } onDelete: {
                        deleteBook(book)
                    } onToggleFinished: {
                        appState.toggleBookFinished(book)
                        Task { await loadBooks() }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)  // Breathing room below header
            .padding(.bottom, 32)
        }
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
        guard isProcessingBook,
              let bookId = book.id,
              bookId == processingBookId else {
            return nil
        }

        return BookProcessingStatus(
            progress: processingProgress,
            completedChapters: processingCompletedChapters,
            totalChapters: processingTotalChapters
        )
    }

    private func handleProcessRequest(_ book: Book) {
        if isProcessingBook {
            if let activeId = processingBookId,
               let activeBook = books.first(where: { $0.id == activeId }) {
                bookToProcess = activeBook
            } else {
                bookToProcess = book
            }
            return
        }

        bookToProcess = book
    }

    private func startProcessing(_ book: Book) {
        guard !isProcessingBook else { return }
        processingTask?.cancel()
        processingTask = Task { await processFullBook(book) }
    }

    private func cancelProcessing() {
        processingChapter = "Stopping..."
        processingTask?.cancel()
    }

    private func deleteBook(_ book: Book) {
        do {
            // Delete from database (cascade deletes chapters, annotations, etc.)
            try appState.database.deleteBook(book)

            // Delete cover image if exists
            if let coverPath = book.coverPath {
                try? FileManager.default.removeItem(atPath: coverPath)
            }

            // Delete EPUB file
            try? FileManager.default.removeItem(atPath: book.epubPath)

            // Delete extracted publication and images
            if let bookId = book.id {
                let publicationDir = LibraryPaths.publicationDirectory(for: bookId)
                try? FileManager.default.removeItem(at: publicationDir)

                let imagesDir = LibraryPaths.imagesDirectory
                    .appendingPathComponent("\(bookId)", isDirectory: true)
                try? FileManager.default.removeItem(at: imagesDir)
            }

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
            let parsed = try await parser.parse(epubURL: url, destinationURL: tempExtractDir)

            guard !parsed.chapters.isEmpty else {
                throw ImportError.noChaptersFound
            }

            // Copy EPUB to app storage
            let fileManager = FileManager.default
            let destURL = LibraryPaths.booksDirectory
                .appendingPathComponent("\(UUID().uuidString).epub")

            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: url, to: destURL)

            // Create book record
            var book = Book(
                title: parsed.title,
                author: parsed.author,
                coverPath: nil,
                epubPath: destURL.path,
                chapterCount: parsed.chapters.count
            )
            try appState.database.saveBook(&book)

            guard let bookId = book.id else {
                throw ImportError.bookSaveFailed
            }

            let finalExtractDir = LibraryPaths.publicationDirectory(for: bookId)
            if fileManager.fileExists(atPath: finalExtractDir.path) {
                try fileManager.removeItem(at: finalExtractDir)
            }
            try fileManager.moveItem(at: tempExtractDir, to: finalExtractDir)
            didMoveExtract = true

            if let cover = parsed.cover {
                let fileExtension = coverFileExtension(for: cover)
                let coverURL = LibraryPaths.coverURL(for: bookId, fileExtension: fileExtension)
                try cover.data.write(to: coverURL)
                book.coverPath = coverURL.path
                try appState.database.saveBook(&book)
            }

            // Save chapters and footnotes
            for parsedChapter in parsed.chapters {
                var chapter = Chapter(
                    bookId: bookId,
                    index: parsedChapter.index,
                    title: parsedChapter.title,
                    contentHTML: parsedChapter.htmlContent,
                    resourcePath: parsedChapter.resourcePath,
                    wordCount: parsedChapter.wordCount
                )
                try appState.database.saveChapter(&chapter)

                // Save footnotes for this chapter
                if let chapterId = chapter.id {
                    let footnotes = parsedChapter.footnotes.map { parsed in
                        Footnote(
                            chapterId: chapterId,
                            marker: parsed.marker,
                            content: parsed.content,
                            refId: parsed.refId,
                            sourceBlockId: parsed.sourceBlockId
                        )
                    }
                    if !footnotes.isEmpty {
                        try appState.database.saveFootnotes(footnotes)
                    }
                }
            }

            // Reload
            await loadBooks()

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

    private func processFullBook(_ book: Book) async {
        isProcessingBook = true
        processingBookId = book.id
        processingProgress = 0
        processingChapter = "Preparing..."
        processingCompletedChapters = 0
        processingTotalChapters = 0
        defer {
            isProcessingBook = false
            processingTask = nil
            processingBookId = nil
        }
        var didCancel = false

        do {
            let chapters = try appState.database.fetchChapters(for: book)
            var rollingSummary: String? = nil
            let chaptersToProcess = chapters.filter { !$0.processed && !$0.shouldSkipAutoProcessing }
            processingTotalChapters = chaptersToProcess.count

            if chaptersToProcess.isEmpty {
                processingProgress = 1.0
                processingChapter = "Complete!"
            }

            for (index, chapter) in chaptersToProcess.enumerated() {
                if Task.isCancelled {
                    didCancel = true
                    break
                }

                processingChapter = chapter.title
                processingProgress = Double(index) / Double(max(1, chaptersToProcess.count))

                // Parse chapter into blocks
                let blockParser = ContentBlockParser()
                let (blocks, contentWithBlocks) = blockParser.parse(html: chapter.contentHTML)

                // Process chapter
                let analysis = try await appState.llmService.analyzeChapter(
                    contentWithBlocks: contentWithBlocks,
                    rollingSummary: rollingSummary,
                    settings: appState.settings
                )

                if Task.isCancelled {
                    didCancel = true
                    break
                }

                // Save annotations
                for data in analysis.annotations {
                    let type = AnnotationType(rawValue: data.type) ?? .science
                    let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blocks.count
                        ? data.sourceBlockId : 1
                    var annotation = Annotation(
                        chapterId: chapter.id!,
                        type: type,
                        title: data.title,
                        content: data.content,
                        sourceBlockId: validBlockId
                    )
                    try appState.database.saveAnnotation(&annotation)
                }

                // Save quizzes
                for data in analysis.quizQuestions {
                    let validBlockId = data.sourceBlockId > 0 && data.sourceBlockId <= blocks.count
                        ? data.sourceBlockId : 1
                    var quiz = Quiz(
                        chapterId: chapter.id!,
                        question: data.question,
                        answer: data.answer,
                        sourceBlockId: validBlockId
                    )
                    try appState.database.saveQuiz(&quiz)
                }

                if Task.isCancelled {
                    didCancel = true
                    break
                }

                await generateSuggestedImages(
                    analysis.imageSuggestions,
                    blockCount: blocks.count,
                    bookId: book.id!,
                    chapterId: chapter.id!
                )

                if Task.isCancelled {
                    didCancel = true
                    break
                }

                // Update chapter with block info
                var updatedChapter = chapter
                updatedChapter.processed = true
                updatedChapter.summary = analysis.summary
                updatedChapter.rollingSummary = rollingSummary
                updatedChapter.contentText = contentWithBlocks
                updatedChapter.blockCount = blocks.count
                try appState.database.saveChapter(&updatedChapter)

                processingCompletedChapters += 1
                processingProgress = Double(processingCompletedChapters) / Double(max(1, chaptersToProcess.count))

                // Build rolling summary for next chapter
                if let summary = rollingSummary {
                    rollingSummary = summary + "\n\n" + analysis.summary
                } else {
                    rollingSummary = analysis.summary
                }
            }

            if didCancel {
                processingChapter = "Cancelled"
                return
            }

            // Mark book as fully processed if all eligible chapters were done
            if processingCompletedChapters == chaptersToProcess.count {
                var updatedBook = book
                updatedBook.processedFully = true
                try appState.database.saveBook(&updatedBook)
            }

            processingProgress = 1.0
            processingChapter = "Complete!"

            await loadBooks()

        } catch {
            if error is CancellationError {
                processingChapter = "Cancelled"
                return
            }
            print("Failed to process book: \(error)")
        }
    }

    private func generateSuggestedImages(
        _ suggestions: [LLMService.ImageSuggestion],
        blockCount: Int,
        bookId: Int64,
        chapterId: Int64
    ) async {
        guard appState.settings.imagesEnabled, !suggestions.isEmpty else { return }

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

// MARK: - Process Book Sheet

struct ProcessBookSheet: View {
    let book: Book
    @Binding var isProcessing: Bool
    @Binding var progress: Double
    @Binding var currentChapter: String
    let onStart: () -> Void
    let onClose: () -> Void
    let onStop: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    @State private var chapterStats = ChapterEstimateStats()
    @State private var classificationStatus: ClassificationStatus = .pending
    @State private var classificationError: String?
    @State private var isClassifying = false

    var body: some View {
        VStack(spacing: 16) {
            header

            if isProcessing {
                progressSection
            } else {
                estimateSection
            }

            actionRow

            if apiKeyMissing && !isProcessing {
                Text("Set up API keys in Settings first")
                    .font(.system(size: 11))
                    .foregroundColor(theme.love)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(theme.surface)
        .onAppear {
            classificationStatus = book.classificationStatus
            classificationError = book.classificationError
            refreshEstimateStats()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(theme.rose)

            VStack(alignment: .leading, spacing: 2) {
                Text("Process Book")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.text)

                Text(book.title)
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: progress)
                .tint(theme.rose)

            HStack {
                Text(currentChapter.isEmpty ? "Working..." : currentChapter)
                    .font(.system(size: 12))
                    .foregroundColor(theme.subtle)
                    .lineLimit(1)

                Spacer()

                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.text)
            }
        }
        .padding(12)
        .background(theme.base)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var estimateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            estimateCard
            classificationCard
        }
    }

    private var estimateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Estimate")

            VStack(spacing: 6) {
                costRow("Chapters", chapterCountLabel)
                costRow("Words", formatWordCount(estimatedWordCount))
                costRow("Tokens in", formatTokenCount(estimatedInputTokens))
                costRow("Tokens out", formatTokenRange(estimatedOutputTokensRange))
                costRow(appState.settings.imagesEnabled ? "Text total" : "Total", formatCostRange(textCostRange))
            }

            if appState.settings.imagesEnabled {
                Divider()
                    .padding(.vertical, 4)

                sectionLabel("Images")

                VStack(spacing: 6) {
                    costRow("Images", "\(formatDecimal(estimatedImageCount)) @ \(formatDecimal(imagesPerChapter))/chap")
                    costRow("Image total", formatCost(estimatedImageCost))
                    costRow("Total", formatCostRange(totalCostRangeWithImages))
                }
            }

            Text("Assumes 2-4k output tokens per chapter.")
                .font(.system(size: 10))
                .foregroundColor(theme.subtle)
        }
        .padding(12)
        .background(theme.base)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var classificationCard: some View {
        let selection = appState.llmService.classificationModelSelection(settings: appState.settings)
        let provider = selection.0
        let model = selection.1
        let modelLabel = "\(provider.displayName) \(provider.modelName(for: model))"
        let estimateLabel = formatCost(classificationCostEstimate)
        let actionTitle = classificationStatus == .completed ? "Re-run" : "Classify"
        let actionLabel = "\(actionTitle) (\(estimateLabel))"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionLabel("Garbage filter")
                Spacer()
                Button(actionLabel) {
                    Task { await classifyBookForEstimate() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isClassifying || classificationKeyMissing)
            }

            Text("Model: \(modelLabel)")
                .font(.system(size: 10))
                .foregroundColor(theme.subtle)

            if isClassifying {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(theme.rose)
            }

            if classificationKeyMissing {
                Text("Add an API key to run classification.")
                    .font(.system(size: 10))
                    .foregroundColor(theme.love)
            } else if let classificationError {
                Text(classificationError)
                    .font(.system(size: 10))
                    .foregroundColor(theme.love)
            }
        }
        .padding(12)
        .background(theme.base)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            if isProcessing {
                Button("Close") {
                    onClose()
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("Stop") {
                    onStop()
                }
                .buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Cancel") {
                    onClose()
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("Process") {
                    onStart()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(apiKeyMissing)
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(theme.subtle)
    }

    private func costRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(theme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.text)
        }
    }

    private func formatWordCount(_ count: Int) -> String {
        if count > 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count > 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }

    private var usesGarbageFilter: Bool {
        classificationStatus == .completed
    }

    private var estimatedChapterCount: Int {
        usesGarbageFilter ? chapterStats.includedChapters : chapterStats.totalChapters
    }

    private var estimatedWordCount: Int {
        usesGarbageFilter ? chapterStats.includedWords : chapterStats.totalWords
    }

    private var estimatedInputTokens: Double {
        Double(estimatedWordCount) * CostEstimates.tokensPerWord
    }

    private var estimatedOutputTokensRange: ClosedRange<Double> {
        let perChapter = CostEstimates.analysisOutputTokensPerChapterRange
        let minTokens = Double(estimatedChapterCount * perChapter.lowerBound)
        let maxTokens = Double(estimatedChapterCount * perChapter.upperBound)
        return minTokens...maxTokens
    }

    private var textCostRange: ClosedRange<Double>? {
        guard let pricing = PricingCatalog.textPricing(for: appState.settings.llmModel) else { return nil }
        let inputCost = (estimatedInputTokens / 1_000_000) * pricing.inputPerMToken
        let minOutputCost = (estimatedOutputTokensRange.lowerBound / 1_000_000) * pricing.outputPerMToken
        let maxOutputCost = (estimatedOutputTokensRange.upperBound / 1_000_000) * pricing.outputPerMToken
        return (inputCost + minOutputCost)...(inputCost + maxOutputCost)
    }

    private var imagesPerChapter: Double {
        CostEstimates.imagesPerChapter(for: appState.settings.imageDensity)
    }

    private var estimatedImageCount: Double {
        Double(estimatedChapterCount) * imagesPerChapter
    }

    private var estimatedImageCost: Double? {
        guard appState.settings.imagesEnabled else { return nil }
        let pricing = PricingCatalog.imagePricing(for: appState.settings.imageModel)
        let promptTokens = Double(CostEstimates.imagePromptTokensPerImage) * estimatedImageCount
        let inputCost = (promptTokens / 1_000_000) * pricing.inputPerMToken

        if let perImage = pricing.outputPerImage {
            return inputCost + (perImage * estimatedImageCount)
        }
        if let outputPerMToken = pricing.outputPerMToken {
            let outputTokens = Double(CostEstimates.imageOutputTokensPerImage) * estimatedImageCount
            return inputCost + (outputTokens / 1_000_000) * outputPerMToken
        }

        return inputCost
    }

    private var totalCostRangeWithImages: ClosedRange<Double>? {
        guard appState.settings.imagesEnabled else { return textCostRange }
        guard let textCostRange, let imageCost = estimatedImageCost else { return nil }
        return (textCostRange.lowerBound + imageCost)...(textCostRange.upperBound + imageCost)
    }

    private var chapterCountLabel: String {
        guard usesGarbageFilter, chapterStats.excludedChapters > 0 else {
            return "\(estimatedChapterCount)"
        }
        return "\(estimatedChapterCount)/\(chapterStats.totalChapters)"
    }

    private var classificationKeyMissing: Bool {
        let selection = appState.llmService.classificationModelSelection(settings: appState.settings)
        return selection.2.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
    }

    private var classificationCostEstimate: Double? {
        let selection = appState.llmService.classificationModelSelection(settings: appState.settings)
        guard let pricing = PricingCatalog.textPricing(for: selection.1) else { return nil }
        let inputTokens = Double(chapterStats.classificationPreviewWords) * CostEstimates.tokensPerWord
        let outputTokens = Double(chapterStats.totalChapters * CostEstimates.classificationOutputTokensPerChapter)
        let inputCost: Double = (inputTokens / 1_000_000) * pricing.inputPerMToken
        let outputCost: Double = (outputTokens / 1_000_000) * pricing.outputPerMToken
        return inputCost + outputCost
    }

    private func formatTokenCount(_ tokens: Double) -> String {
        if tokens > 1_000_000 {
            return String(format: "%.1fM", tokens / 1_000_000)
        } else if tokens > 1_000 {
            return String(format: "%.0fK", tokens / 1_000)
        } else {
            return "\(Int(tokens))"
        }
    }

    private func formatTokenRange(_ range: ClosedRange<Double>) -> String {
        let minText = formatTokenCount(range.lowerBound)
        let maxText = formatTokenCount(range.upperBound)
        if minText == maxText {
            return minText
        }
        return "\(minText)-\(maxText)"
    }

    private func formatCost(_ value: Double?) -> String {
        guard let value else { return "N/A" }
        return String(format: "$%.2f", max(0.01, value))
    }

    private func formatCostRange(_ range: ClosedRange<Double>?) -> String {
        guard let range else { return "N/A" }
        let minValue = max(0.01, range.lowerBound)
        let maxValue = max(0.01, range.upperBound)
        if abs(minValue - maxValue) < 0.005 {
            return String(format: "$%.2f", minValue)
        }
        return String(format: "$%.2f-$%.2f", minValue, maxValue)
    }

    private func formatDecimal(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func refreshEstimateStats() {
        do {
            let chapters = try appState.database.fetchChapters(for: book)
            let totalWords = chapters.reduce(0) { $0 + $1.wordCount }
            let excluded = chapters.filter { $0.shouldSkipAutoProcessing }
            let included = chapters.filter { !$0.shouldSkipAutoProcessing }
            let includedWords = included.reduce(0) { $0 + $1.wordCount }
            let previewWords = chapters.reduce(0) { total, chapter in
                total + min(chapter.wordCount, CostEstimates.classificationPreviewWordLimit)
            }

            chapterStats = ChapterEstimateStats(
                totalWords: totalWords,
                totalChapters: chapters.count,
                excludedChapters: excluded.count,
                includedWords: includedWords,
                includedChapters: included.count,
                classificationPreviewWords: previewWords
            )
        } catch {
            print("Failed to fetch chapters for estimate: \(error)")
        }
    }

    private func classifyBookForEstimate() async {
        guard !isClassifying else { return }

        isClassifying = true
        classificationError = nil
        classificationStatus = .inProgress

        var updatedBook = book
        updatedBook.classificationStatus = .inProgress
        updatedBook.classificationError = nil
        try? appState.database.saveBook(&updatedBook)

        do {
            let chapters = try appState.database.fetchChapters(for: book)
            let chapterData: [(index: Int, title: String, preview: String)] = chapters.map { chapter in
                let plainText = chapter.contentHTML
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (index: chapter.index, title: chapter.title, preview: plainText)
            }

            let classifications = try await appState.llmService.classifyChapters(
                chapters: chapterData,
                settings: appState.settings
            )

            for chapter in chapters {
                var updatedChapter = chapter
                updatedChapter.isGarbage = classifications[chapter.index] ?? false
                try appState.database.saveChapter(&updatedChapter)
            }

            classificationStatus = .completed
            classificationError = nil

            updatedBook.classificationStatus = .completed
            updatedBook.classificationError = nil
            try appState.database.saveBook(&updatedBook)
        } catch {
            classificationStatus = .failed
            classificationError = error.localizedDescription

            updatedBook.classificationStatus = .failed
            updatedBook.classificationError = error.localizedDescription
            try? appState.database.saveBook(&updatedBook)
        }

        isClassifying = false
        refreshEstimateStats()
    }

    private var apiKeyMissing: Bool {
        switch appState.settings.llmProvider {
        case .google: return appState.settings.googleAPIKey.isEmpty
        case .openai: return appState.settings.openAIAPIKey.isEmpty
        case .anthropic: return appState.settings.anthropicAPIKey.isEmpty
        }
    }
}

private struct ChapterEstimateStats {
    var totalWords: Int = 0
    var totalChapters: Int = 0
    var excludedChapters: Int = 0
    var includedWords: Int = 0
    var includedChapters: Int = 0
    var classificationPreviewWords: Int = 0
}

// MARK: - EPUB UTType Extension

extension UTType {
    static var epub: UTType {
        UTType(filenameExtension: "epub") ?? .data
    }
}
