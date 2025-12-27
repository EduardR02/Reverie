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
                onProcess: {
                    Task { await processFullBook(book) }
                },
                onCancel: {
                    bookToProcess = nil
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

            // Reading stats bar
            if appState.readingStats.totalMinutes > 0 || appState.readingStats.currentStreak > 0 {
                readingStatsBar
            }
        }
    }

    // MARK: - Reading Stats Bar

    private var readingStatsBar: some View {
        HStack(spacing: 24) {
            // Today's reading
            statItem(
                icon: "clock",
                value: formatMinutes(appState.readingStats.minutesToday),
                label: "Today"
            )

            // Streak
            statItem(
                icon: "flame",
                value: "\(appState.readingStats.currentStreak)",
                label: "Day Streak",
                accent: appState.readingStats.currentStreak >= 7
            )

            // Total time
            statItem(
                icon: "hourglass",
                value: formatMinutes(appState.readingStats.totalMinutes),
                label: "Total"
            )

            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 16)
    }

    private func statItem(icon: String, value: String, label: String, accent: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(accent ? theme.gold : theme.muted)

            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(accent ? theme.gold : theme.text)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(theme.muted)
            }
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        }
    }

    // MARK: - Book Grid

    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(books) { book in
                    BookCard(book: book) {
                        appState.openBook(book)
                    } onProcess: {
                        bookToProcess = book
                    } onDelete: {
                        deleteBook(book)
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

            let parser = EPUBParser()
            let parsed = try await parser.parse(epubURL: url)

            guard !parsed.chapters.isEmpty else {
                throw ImportError.noChaptersFound
            }

            // Copy EPUB to app storage
            let fileManager = FileManager.default
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let booksDir = appSupport
                .appendingPathComponent("Reader", isDirectory: true)
                .appendingPathComponent("books", isDirectory: true)

            try fileManager.createDirectory(at: booksDir, withIntermediateDirectories: true)

            let destURL = booksDir.appendingPathComponent("\(UUID().uuidString).epub")

            // Remove existing file if present
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }

            try fileManager.copyItem(at: url, to: destURL)

            // Save cover if exists
            var coverPath: String?
            if let coverData = parsed.coverData {
                let coverURL = booksDir.appendingPathComponent("\(UUID().uuidString).jpg")
                try coverData.write(to: coverURL)
                coverPath = coverURL.path
            }

            // Create book record
            var book = Book(
                title: parsed.title,
                author: parsed.author,
                coverPath: coverPath,
                epubPath: destURL.path,
                chapterCount: parsed.chapters.count
            )
            try appState.database.saveBook(&book)

            guard let bookId = book.id else {
                throw ImportError.bookSaveFailed
            }

            // Save chapters and footnotes
            for parsedChapter in parsed.chapters {
                var chapter = Chapter(
                    bookId: bookId,
                    index: parsedChapter.index,
                    title: parsedChapter.title,
                    contentHTML: parsedChapter.htmlContent,
                    wordCount: parsedChapter.htmlContent.split(separator: " ").count
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
                            sourceOffset: parsed.sourceOffset
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

    private func processFullBook(_ book: Book) async {
        isProcessingBook = true
        processingProgress = 0

        do {
            let chapters = try appState.database.fetchChapters(for: book)
            var rollingSummary: String? = nil

            for (index, chapter) in chapters.enumerated() {
                // Skip already processed chapters
                if chapter.processed { continue }

                processingChapter = chapter.title
                processingProgress = Double(index) / Double(chapters.count)

                // Process chapter
                let analysis = try await appState.llmService.analyzeChapter(
                    content: chapter.contentHTML,
                    rollingSummary: rollingSummary,
                    settings: appState.settings
                )

                // Save annotations
                for data in analysis.annotations {
                    let type = AnnotationType(rawValue: data.type) ?? .insight
                    var annotation = Annotation(
                        chapterId: chapter.id!,
                        type: type,
                        title: data.title,
                        content: data.content,
                        sourceQuote: data.sourceQuote,
                        sourceOffset: chapter.contentHTML.range(of: data.sourceQuote)
                            .map { chapter.contentHTML.distance(from: chapter.contentHTML.startIndex, to: $0.lowerBound) } ?? 0
                    )
                    try appState.database.saveAnnotation(&annotation)
                }

                // Save quizzes
                for data in analysis.quizQuestions {
                    var quiz = Quiz(
                        chapterId: chapter.id!,
                        question: data.question,
                        answer: data.answer,
                        sourceQuote: data.sourceQuote,
                        sourceOffset: chapter.contentHTML.range(of: data.sourceQuote)
                            .map { chapter.contentHTML.distance(from: chapter.contentHTML.startIndex, to: $0.lowerBound) } ?? 0
                    )
                    try appState.database.saveQuiz(&quiz)
                }

                // Update chapter
                var updatedChapter = chapter
                updatedChapter.processed = true
                updatedChapter.summary = analysis.summary
                updatedChapter.rollingSummary = rollingSummary
                try appState.database.saveChapter(&updatedChapter)

                // Build rolling summary for next chapter
                if let summary = rollingSummary {
                    rollingSummary = summary + "\n\n" + analysis.summary
                } else {
                    rollingSummary = analysis.summary
                }
            }

            // Mark book as fully processed
            var updatedBook = book
            updatedBook.processedFully = true
            try appState.database.saveBook(&updatedBook)

            processingProgress = 1.0
            processingChapter = "Complete!"

            // Wait a moment then close
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            bookToProcess = nil

            await loadBooks()

        } catch {
            print("Failed to process book: \(error)")
        }

        isProcessingBook = false
    }
}

// MARK: - Process Book Sheet

struct ProcessBookSheet: View {
    let book: Book
    @Binding var isProcessing: Bool
    @Binding var progress: Double
    @Binding var currentChapter: String
    let onProcess: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    @State private var totalWordCount: Int = 0

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(theme.rose)

                Text("Process Full Book")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.text)

                Text(book.title)
                    .font(.system(size: 14))
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
            }

            Divider()

            if isProcessing {
                // Progress view
                VStack(spacing: 12) {
                    ProgressView(value: progress)
                        .tint(theme.rose)

                    Text(currentChapter)
                        .font(.system(size: 13))
                        .foregroundColor(theme.subtle)

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.text)
                }
                .padding(.vertical, 20)
            } else {
                // Cost estimate
                VStack(alignment: .leading, spacing: 12) {
                    costRow("Chapters", "\(book.chapterCount)")
                    costRow("Words", formatWordCount(totalWordCount))
                    costRow("Est. tokens", estimatedTokens)
                    costRow("Est. cost", estimatedCost)

                    Text("This will generate insights, quiz questions, and summaries for all chapters.")
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)
                        .padding(.top, 8)
                }
                .padding(.vertical, 12)
            }

            // Actions
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isProcessing)

                Button(isProcessing ? "Processing..." : "Process") {
                    onProcess()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isProcessing || apiKeyMissing)
            }

            if apiKeyMissing {
                Text("Set up API keys in Settings first")
                    .font(.system(size: 12))
                    .foregroundColor(theme.love)
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(theme.surface)
        .onAppear {
            do {
                totalWordCount = try appState.database.fetchTotalWordCount(for: book)
            } catch {
                print("Failed to fetch word count: \(error)")
            }
        }
    }

    private func costRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(theme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
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

    private var estimatedTokens: String {
        // 1.3 tokens per word (average)
        let tokens = Double(totalWordCount) * 1.3
        if tokens > 1_000_000 {
            return String(format: "%.1fM", tokens / 1_000_000)
        } else if tokens > 1_000 {
            return String(format: "%.0fK", tokens / 1_000)
        } else {
            return "\(Int(tokens))"
        }
    }

    private var estimatedCost: String {
        // Based on Gemini Flash pricing ($0.075/1M input, $0.30/1M output)
        let inputTokens = Double(totalWordCount) * 1.3
        let outputTokens = Double(book.chapterCount) * 300  // ~300 tokens output per chapter
        let cost = (inputTokens * 0.000000075) + (outputTokens * 0.0000003)
        return String(format: "$%.2f", max(0.01, cost))
    }

    private var apiKeyMissing: Bool {
        switch appState.settings.llmProvider {
        case .google: return appState.settings.googleAPIKey.isEmpty
        case .openai: return appState.settings.openAIAPIKey.isEmpty
        case .anthropic: return appState.settings.anthropicAPIKey.isEmpty
        }
    }
}

// MARK: - EPUB UTType Extension

extension UTType {
    static var epub: UTType {
        UTType(filenameExtension: "epub") ?? .data
    }
}
