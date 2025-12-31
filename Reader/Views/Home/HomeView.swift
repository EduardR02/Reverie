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
            ProcessBookView(
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
                // Fetch fresh copy to avoid overwriting background classification status
                if var updatedBook = try? appState.database.fetchAllBooks().first(where: { $0.id == book.id }) {
                    updatedBook.processedFully = true
                    try appState.database.saveBook(&updatedBook)
                } else {
                    var updatedBook = book
                    updatedBook.processedFully = true
                    try appState.database.saveBook(&updatedBook)
                }
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

// MARK: - EPUB UTType Extension

extension UTType {
    static var epub: UTType {
        UTType(filenameExtension: "epub") ?? .data
    }
}
