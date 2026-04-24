import SwiftUI
import Foundation

@Observable @MainActor
final class ChapterAnalyzer {
    // Observable state (View reads these directly)
    private(set) var processingStates: [Int64: ProcessingState] = [:]
    private(set) var isClassifying = false
    private(set) var classificationError: String?
    
    struct ProcessingState {
        var isProcessingInsights = false
        var isProcessingImages = false
        var liveInsightCount = 0
        var liveQuizCount = 0
        var liveThinking = ""
        var error: String?
    }
    
    // Dependencies
    private let llm: LLMService
    private let imageService: ImageService
    private let database: DatabaseService
    private let settings: UserSettings
    
    init(llm: LLMService, imageService: ImageService, database: DatabaseService, settings: UserSettings) {
        self.llm = llm
        self.imageService = imageService
        self.database = database
        self.settings = settings
    }
    
    enum AnalysisEvent {
        case thinking(String)
        case annotation(Annotation)  // Already saved to DB
        case quiz(Quiz)              // Already saved to DB
        case imageSuggestions([LLMService.ImageSuggestion])
        case complete(chapterSummary: String?)
    }
    
    // Streaming analysis - yields annotations as they're created
    func analyzeChapter(_ chapter: Chapter, book: Book) -> AsyncThrowingStream<AnalysisEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let chapterId = chapter.id else {
                    continuation.finish()
                    return
                }
                
                updateState(for: chapterId) { 
                    $0.isProcessingInsights = true
                    $0.error = nil
                    $0.liveInsightCount = 0
                    $0.liveQuizCount = 0
                }
                defer { updateState(for: chapterId) { $0.isProcessingInsights = false; $0.liveThinking = "" } }
                
                do {
                    let (contentWithBlocks, blockCount) = chapter.getContentText()
                    let rollingSummary = rollingSummaryForAnalysis(chapter)
                    let stream = llm.analyzeChapterStreaming(
                        contentWithBlocks: contentWithBlocks,
                        rollingSummary: rollingSummary,
                        bookTitle: book.title,
                        author: book.author,
                        settings: settings
                    )
                    
                    var lastThinkingUpdate = Date.distantPast
                    var finalAnalysis: LLMService.ChapterAnalysis?
                    
                    for try await event in stream {
                        switch event {
                        case .thinking(let text):
                            if Date().timeIntervalSince(lastThinkingUpdate) > 0.1 {
                                updateState(for: chapterId) { $0.liveThinking = text }
                                lastThinkingUpdate = Date()
                                continuation.yield(.thinking(text))
                            }
                        case .insightFound:
                            updateState(for: chapterId) { $0.liveInsightCount += 1 }
                        case .quizQuestionFound:
                            updateState(for: chapterId) { $0.liveQuizCount += 1 }
                        case .usage: 
                            break
                        case .completed(let analysis):
                            finalAnalysis = analysis
                        }
                    }
                    
                    guard let analysis = finalAnalysis else {
                        continuation.finish()
                        return
                    }
                    
                    for data in analysis.annotations {
                        let type = AnnotationType(rawValue: data.type) ?? .science
                        let blockId = (data.sourceBlockId > 0 && data.sourceBlockId <= blockCount) ? data.sourceBlockId : 1
                        var annotation = Annotation(chapterId: chapterId, type: type, title: data.title, content: data.content, sourceBlockId: blockId)
                        try database.saveAnnotation(&annotation)
                        continuation.yield(.annotation(annotation))
                    }
                    
                    for data in analysis.quizQuestions {
                        let blockId = (data.sourceBlockId > 0 && data.sourceBlockId <= blockCount) ? data.sourceBlockId : 1
                        var quiz = Quiz(chapterId: chapterId, question: data.question, answer: data.answer, sourceBlockId: blockId)
                        try database.saveQuiz(&quiz)
                        continuation.yield(.quiz(quiz))
                    }
                    
                    if !analysis.imageSuggestions.isEmpty {
                        continuation.yield(.imageSuggestions(analysis.imageSuggestions))
                    }
                    
                    var updatedChapter = chapter
                    updatedChapter.processed = true
                    updatedChapter.summary = analysis.summary
                    updatedChapter.rollingSummary = rollingSummary
                    updatedChapter.contentText = contentWithBlocks
                    updatedChapter.blockCount = blockCount
                    do {
                        try database.saveChapter(&updatedChapter)
                    } catch {
                        print("ChapterAnalyzer: Failed to save chapter after analysis: \(error)")
                    }
                    
                    continuation.yield(.complete(chapterSummary: analysis.summary))
                    continuation.finish()
                } catch {
                    updateState(for: chapterId) { $0.error = error.localizedDescription }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    // Generate more (returns arrays, not streams - simpler for "more" operations)
    func generateMoreInsights(for chapter: Chapter) async throws -> [Annotation] {
        guard let chapterId = chapter.id else { return [] }
        updateState(for: chapterId) { $0.isProcessingInsights = true; $0.error = nil }
        defer { updateState(for: chapterId) { $0.isProcessingInsights = false; $0.liveThinking = "" } }
        
        let (contentWithBlocks, blockCount) = chapter.getContentText()
        let existingTitles = (try? database.fetchAnnotations(for: chapter))?.map { $0.title } ?? []
        let stream = llm.generateMoreInsightsStreaming(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: chapter.rollingSummary,
            existingTitles: existingTitles,
            settings: settings
        )
        
        var finalAnalysis: LLMService.ChapterAnalysis?
        for try await event in stream {
            if case .completed(let analysis) = event { finalAnalysis = analysis }
            if case .thinking(let text) = event { updateState(for: chapterId) { $0.liveThinking = text } }
        }
        
        guard let analysis = finalAnalysis else { return [] }
        var saved: [Annotation] = []
        for data in analysis.annotations {
            let type = AnnotationType(rawValue: data.type) ?? .science
            let blockId = (data.sourceBlockId > 0 && data.sourceBlockId <= blockCount) ? data.sourceBlockId : 1
            var annotation = Annotation(chapterId: chapterId, type: type, title: data.title, content: data.content, sourceBlockId: blockId)
            try database.saveAnnotation(&annotation)
            saved.append(annotation)
        }
        return saved
    }
    
    func generateMoreQuestions(for chapter: Chapter) async throws -> [Quiz] {
        guard let chapterId = chapter.id else { return [] }
        updateState(for: chapterId) { $0.isProcessingInsights = true; $0.error = nil }
        defer { updateState(for: chapterId) { $0.isProcessingInsights = false; $0.liveThinking = "" } }
        
        let (contentWithBlocks, blockCount) = chapter.getContentText()
        let existingQuestions = (try? database.fetchQuizzes(for: chapter))?.map { $0.question } ?? []
        let stream = llm.generateMoreQuestionsStreaming(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: chapter.rollingSummary,
            existingQuestions: existingQuestions,
            settings: settings
        )
        
        var finalAnalysis: LLMService.ChapterAnalysis?
        for try await event in stream {
            if case .completed(let analysis) = event { finalAnalysis = analysis }
            if case .thinking(let text) = event { updateState(for: chapterId) { $0.liveThinking = text } }
        }
        
        guard let analysis = finalAnalysis else { return [] }
        var saved: [Quiz] = []
        for data in analysis.quizQuestions {
            let blockId = (data.sourceBlockId > 0 && data.sourceBlockId <= blockCount) ? data.sourceBlockId : 1
            var quiz = Quiz(chapterId: chapterId, question: data.question, answer: data.answer, sourceBlockId: blockId)
            try database.saveQuiz(&quiz)
            saved.append(quiz)
        }
        return saved
    }
    
    // Image generation
    func generateImages(suggestions: [LLMService.ImageSuggestion], book: Book, chapter: Chapter) -> AsyncThrowingStream<GeneratedImage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let chapterId = chapter.id, let bookId = book.id else {
                    continuation.finish()
                    return
                }
                
                updateState(for: chapterId) { $0.isProcessingImages = true }
                defer { updateState(for: chapterId) { $0.isProcessingImages = false } }
                
                let (_, blockCount) = chapter.getContentText()
                let apiKey = settings.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                
                let inputs = suggestions.map {
                    let blockId = ($0.sourceBlockId > 0 && $0.sourceBlockId <= blockCount) ? $0.sourceBlockId : 1
                    let prompt = llm.imagePromptFromExcerpt($0.excerpt, rewrite: settings.rewriteImageExcerpts)
                    return ImageService.ImageSuggestionInput(
                        excerpt: $0.excerpt,
                        prompt: prompt,
                        sourceBlockId: blockId,
                        aspectRatio: $0.aspectRatio
                    )
                }
                
                let results = await imageService.generateImages(
                    from: inputs,
                    model: settings.imageModel,
                    apiKey: apiKey,
                    maxConcurrent: settings.maxConcurrentRequests
                )

                for result in results {
                    if Task.isCancelled { break }
                    do {
                        let image = try persistGeneratedImage(result, bookId: bookId, chapterId: chapterId)
                        continuation.yield(image)
                    } catch {
                        continue
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func retryImage(_ image: GeneratedImage, book: Book, chapter: Chapter) async throws -> GeneratedImage {
        try await regenerateImage(image, book: book, chapter: chapter, rewritePrompt: false)
    }

    func rewriteAndRetryImage(_ image: GeneratedImage, book: Book, chapter: Chapter) async throws -> GeneratedImage {
        try await regenerateImage(image, book: book, chapter: chapter, rewritePrompt: true)
    }

    private func regenerateImage(
        _ image: GeneratedImage,
        book: Book,
        chapter: Chapter,
        rewritePrompt: Bool
    ) async throws -> GeneratedImage {
        guard let chapterId = chapter.id, let bookId = book.id else {
            throw ImageService.ImageError.invalidResponse
        }

        let apiKey = settings.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ImageService.ImageError.missingAPIKey
        }

        updateState(for: chapterId) { $0.isProcessingImages = true }
        defer { updateState(for: chapterId) { $0.isProcessingImages = false } }

        let promptToUse: String
        if rewritePrompt {
            let reason = image.failureReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackReason = (reason?.isEmpty == false ? reason : nil) ?? "The image model rejected the prompt."
            promptToUse = try await llm.rewriteImagePrompt(originalPrompt: image.prompt, refusalReason: fallbackReason, settings: settings)
        } else {
            promptToUse = image.prompt
        }

        let input = ImageService.ImageSuggestionInput(
            excerpt: image.excerpt,
            prompt: promptToUse,
            sourceBlockId: image.sourceBlockId,
            aspectRatio: image.aspectRatio
        )
        guard let result = await imageService.generateImages(
            from: [input],
            model: settings.imageModel,
            apiKey: apiKey,
            maxConcurrent: 1
        ).first else {
            throw ImageService.ImageError.invalidResponse
        }

        var updatedImage = image
        updatedImage.prompt = promptToUse
        return try persistGeneratedImage(result, bookId: bookId, chapterId: chapterId, existingImage: updatedImage)
    }

    private func persistGeneratedImage(
        _ result: ImageService.GeneratedImageResult,
        bookId: Int64,
        chapterId: Int64,
        existingImage: GeneratedImage? = nil
    ) throws -> GeneratedImage {
        var status = result.status
        var failureReason = result.failureReason
        var imagePath = ""

        if status == .success {
            if let data = result.imageData {
                imagePath = try imageService.saveImage(data, for: bookId, chapterId: chapterId)
                do {
                    try database.saveImageGenerationUsage(model: settings.imageModel)
                } catch {
                    print("ChapterAnalyzer: Failed to save image usage: \(error)")
                }
            } else {
                status = .failed
                failureReason = "Image generation returned no image data."
            }
        }

        var image = existingImage ?? GeneratedImage(
            chapterId: chapterId,
            excerpt: result.excerpt,
            prompt: result.prompt,
            imagePath: imagePath,
            sourceBlockId: result.sourceBlockId,
            aspectRatio: result.aspectRatio
        )
        image.chapterId = chapterId
        image.excerpt = result.excerpt
        image.prompt = result.prompt
        image.imagePath = imagePath
        image.sourceBlockId = result.sourceBlockId
        image.aspectRatio = result.aspectRatio
        image.status = status
        image.failureReason = failureReason

        try database.saveImage(&image)
        return image
    }
    
    // Classification
    func classifyChapters(_ chapters: [Chapter], for book: Book) async throws -> [Int64: ChapterType] {
        isClassifying = true
        classificationError = nil
        defer { isClassifying = false }
        
        let chapterData = chapters.map { (index: $0.index, title: $0.title, preview: $0.contentHTML.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)) }
        
        do {
            let classifications = try await llm.classifyChapters(chapters: chapterData, settings: settings)
            var results: [Int64: ChapterType] = [:]
            
            for var chapter in chapters {
                guard let id = chapter.id else { continue }
                let isGarbage = classifications[chapter.index] ?? false
                chapter.isGarbage = isGarbage
                do {
                    try database.saveChapter(&chapter)
                } catch {
                    print("ChapterAnalyzer: Failed to save chapter during classification: \(error)")
                }
                results[id] = isGarbage ? .garbage : .content
            }
            return results
        } catch {
            classificationError = error.localizedDescription
            throw error
        }
    }
    
    enum ChapterType {
        case content
        case garbage
    }
    
    // Cancellation
    func cancel(for chapterId: Int64) {
        updateState(for: chapterId) { 
            $0.isProcessingInsights = false
            $0.isProcessingImages = false
        }
    }
    
    func cancelAll() {
        for id in processingStates.keys {
            cancel(for: id)
        }
    }
    
    func cancel() {
        cancelAll()
    }
    
    // Helpers
    func shouldAutoProcess(_ chapter: Chapter, in chapters: [Chapter], book: Book? = nil) -> Bool {
        if chapter.userOverride { return true }
        let hasLLMKey = !settings.googleAPIKey.isEmpty || !settings.openAIAPIKey.isEmpty || !settings.anthropicAPIKey.isEmpty
        let isClassified = book == nil || book?.classificationStatus == .completed
        return settings.autoAIProcessingEnabled && hasLLMKey && !chapter.processed && !chapter.shouldSkipAutoProcessing && isClassified
    }
    
    private func updateState(for chapterId: Int64, transform: (inout ProcessingState) -> Void) {
        var state = processingStates[chapterId] ?? ProcessingState()
        transform(&state)
        processingStates[chapterId] = state
    }

    func rollingSummaryForAnalysis(_ chapter: Chapter) -> String? {
        let summaries = (try? database.fetchSummariesBeforeChapter(bookId: chapter.bookId, chapterIndex: chapter.index)) ?? []
        let combined = summaries.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !combined.isEmpty { return combined }

        if let rollingSummary = chapter.rollingSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rollingSummary.isEmpty {
            return rollingSummary
        }
        return nil
    }
}
