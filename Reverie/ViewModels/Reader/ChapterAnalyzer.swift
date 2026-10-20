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
    private var cancellationGenerationByChapter: [Int64: Int] = [:]
    private var imageCancellationGenerationByChapter: [Int64: Int] = [:]
    private var producerTasks: [UUID: (chapterId: Int64, isImage: Bool, task: Task<Void, Never>)] = [:]
    private var classificationGeneration = UUID()
    
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
        let generation = chapter.id.map { cancellationGenerationByChapter[$0, default: 0] }
        let taskID = UUID()
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { producerTasks.removeValue(forKey: taskID) }
                guard let chapterId = chapter.id, let generation else {
                    continuation.finish()
                    return
                }
                guard !Task.isCancelled,
                      cancellationGenerationByChapter[chapterId, default: 0] == generation else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                
                updateState(for: chapterId) { 
                    $0.isProcessingInsights = true
                    $0.error = nil
                    $0.liveInsightCount = 0
                    $0.liveThinking = ""
                    $0.liveQuizCount = 0
                }
                defer {
                    if cancellationGenerationByChapter[chapterId, default: 0] == generation {
                        updateState(for: chapterId) { $0.isProcessingInsights = false; $0.liveThinking = "" }
                    }
                }
                
                do {
                    let (blocks, contentWithBlocks) = ContentBlockParser().parse(html: chapter.contentHTML)
                    let blockCount = blocks.count
                    let rollingSummary = rollingSummaryForAnalysis(chapter)
                    let coveredIdeas = try database.fetchAnnotationsBeforeChapter(
                        bookId: chapter.bookId, chapterIndex: chapter.index
                    ).map(PromptLibrary.coverageHint)
                    let stream = llm.analyzeChapterStreaming(
                        contentWithBlocks: contentWithBlocks,
                        rollingSummary: rollingSummary,
                        bookTitle: book.title,
                        author: book.author,
                        settings: settings,
                        coveredIdeas: coveredIdeas
                    )
                    
                    var finalAnalysis: LLMService.ChapterAnalysis?
                    
                    for try await event in stream {
                        try checkCancellation(for: chapterId, generation: generation)
                        switch event {
                        case .thinking(let text):
                            updateState(for: chapterId) { $0.liveThinking += text }
                            continuation.yield(.thinking(processingStates[chapterId]!.liveThinking))
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
                    
                    guard let finalAnalysis else {
                        throw ChapterAnalysisValidationError.missingCompletion
                    }
                    try checkCancellation(for: chapterId, generation: generation)
                    let analysis = try finalAnalysis.validated(blocks: blocks)

                    var updatedChapter = chapter
                    updatedChapter.processed = true
                    updatedChapter.summary = analysis.summary
                    updatedChapter.rollingSummary = rollingSummary
                    updatedChapter.contentText = contentWithBlocks
                    updatedChapter.blockCount = blockCount
                    let saved = try database.saveChapterAnalysis(
                        analysis,
                        chapter: &updatedChapter,
                        blockCount: blockCount
                    )
                    for annotation in saved.annotations {
                        continuation.yield(.annotation(annotation))
                    }
                    for quiz in saved.quizzes {
                        continuation.yield(.quiz(quiz))
                    }
                    
                    if !analysis.imageSuggestions.isEmpty {
                        continuation.yield(.imageSuggestions(analysis.imageSuggestions))
                    }
                    
                    
                    continuation.yield(.complete(chapterSummary: analysis.summary))
                    continuation.finish()
                } catch {
                    if !Task.isCancelled && cancellationGenerationByChapter[chapterId, default: 0] == generation {
                        updateState(for: chapterId) { $0.error = error.localizedDescription }
                    }
                    continuation.finish(throwing: error)
                }
            }
            if let chapterId = chapter.id { producerTasks[taskID] = (chapterId, false, task) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    // Generate more (returns arrays, not streams - simpler for "more" operations)
    func generateMoreInsights(for chapter: Chapter) async throws -> [Annotation] {
        guard let chapterId = chapter.id else { return [] }
        try Task.checkCancellation()
        let generation = cancellationGenerationByChapter[chapterId, default: 0]
        updateState(for: chapterId) { $0.isProcessingInsights = true; $0.error = nil }
        defer {
            if cancellationGenerationByChapter[chapterId, default: 0] == generation {
                updateState(for: chapterId) { $0.isProcessingInsights = false; $0.liveThinking = "" }
            }
        }
        
        let (blocks, contentWithBlocks) = ContentBlockParser().parse(html: chapter.contentHTML)
        let existing = try database.fetchAnnotations(for: chapter)
        let prior = try database.fetchAnnotationsBeforeChapter(bookId: chapter.bookId, chapterIndex: chapter.index)
        let stream = llm.generateMoreInsightsStreaming(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: rollingSummaryForAnalysis(chapter),
            existingTitles: existing.map(\.title),
            settings: settings,
            coveredIdeas: (prior + existing).map(PromptLibrary.coverageHint)
        )
        
        var finalAnalysis: LLMService.ChapterAnalysis?
        for try await event in stream {
            try checkCancellation(for: chapterId, generation: generation)
            if case .completed(let analysis) = event { finalAnalysis = analysis }
            if case .thinking(let text) = event { updateState(for: chapterId) { $0.liveThinking += text } }
        }
        
        guard let finalAnalysis else {
            throw ChapterAnalysisValidationError.missingCompletion
        }
        try checkCancellation(for: chapterId, generation: generation)
        let analysis = try finalAnalysis.validated(blocks: blocks)
        var saved = analysis.annotations.map { data in
            Annotation(
                chapterId: chapterId,
                type: AnnotationType(rawValue: data.type)!,
                title: data.title,
                content: data.content,
                sourceBlockId: data.sourceBlockId
            )
        }
        try database.saveAnnotations(&saved)
        return saved
    }
    
    func generateMoreQuestions(for chapter: Chapter) async throws -> [Quiz] {
        guard let chapterId = chapter.id else { return [] }
        try Task.checkCancellation()
        let generation = cancellationGenerationByChapter[chapterId, default: 0]
        updateState(for: chapterId) { $0.isProcessingInsights = true; $0.error = nil }
        defer {
            if cancellationGenerationByChapter[chapterId, default: 0] == generation {
                updateState(for: chapterId) { $0.isProcessingInsights = false; $0.liveThinking = "" }
            }
        }
        
        let (blocks, contentWithBlocks) = ContentBlockParser().parse(html: chapter.contentHTML)
        let existingQuestions = try database.fetchQuizzes(for: chapter).map { $0.question }
        let stream = llm.generateMoreQuestionsStreaming(
            contentWithBlocks: contentWithBlocks,
            rollingSummary: chapter.rollingSummary,
            existingQuestions: existingQuestions,
            settings: settings
        )
        
        var finalAnalysis: LLMService.ChapterAnalysis?
        for try await event in stream {
            try checkCancellation(for: chapterId, generation: generation)
            if case .completed(let analysis) = event { finalAnalysis = analysis }
            if case .thinking(let text) = event { updateState(for: chapterId) { $0.liveThinking += text } }
        }
        
        guard let finalAnalysis else {
            throw ChapterAnalysisValidationError.missingCompletion
        }
        try checkCancellation(for: chapterId, generation: generation)
        let analysis = try finalAnalysis.validated(blocks: blocks)
        var saved = analysis.quizQuestions.map { data in
            Quiz(chapterId: chapterId, question: data.question, answer: data.answer, sourceBlockId: data.sourceBlockId)
        }
        try database.saveQuizzes(&saved)
        return saved
    }
    
    // Image generation
    func generateImages(suggestions: [LLMService.ImageSuggestion], book: Book, chapter: Chapter) -> AsyncThrowingStream<GeneratedImage, Error> {
        let generation = chapter.id.map { imageCancellationGenerationByChapter[$0, default: 0] }
        let taskID = UUID()
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { producerTasks.removeValue(forKey: taskID) }
                guard let chapterId = chapter.id, let bookId = book.id, let generation else {
                    continuation.finish()
                    return
                }
                guard !Task.isCancelled,
                      imageCancellationGenerationByChapter[chapterId, default: 0] == generation else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                
                updateState(for: chapterId) { $0.isProcessingImages = true }
                defer {
                    if imageCancellationGenerationByChapter[chapterId, default: 0] == generation {
                        updateState(for: chapterId) { $0.isProcessingImages = false }
                    }
                }
                
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
                    guard !Task.isCancelled,
                          imageCancellationGenerationByChapter[chapterId, default: 0] == generation else { break }
                    do {
                        let image = try persistGeneratedImage(result, bookId: bookId, chapterId: chapterId)
                        continuation.yield(image)
                    } catch {
                        continue
                    }
                }
                continuation.finish()
            }
            if let chapterId = chapter.id { producerTasks[taskID] = (chapterId, true, task) }
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
        try Task.checkCancellation()
        let generation = imageCancellationGenerationByChapter[chapterId, default: 0]

        let apiKey = settings.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ImageService.ImageError.missingAPIKey
        }

        updateState(for: chapterId) { $0.isProcessingImages = true }
        defer {
            if imageCancellationGenerationByChapter[chapterId, default: 0] == generation {
                updateState(for: chapterId) { $0.isProcessingImages = false }
            }
        }

        let promptToUse: String
        if rewritePrompt {
            let reason = image.failureReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackReason = (reason?.isEmpty == false ? reason : nil) ?? "The image model rejected the prompt."
            promptToUse = try await llm.rewriteImagePrompt(originalPrompt: image.prompt, refusalReason: fallbackReason, settings: settings)
        } else {
            promptToUse = image.prompt
        }

        try checkImageCancellation(for: chapterId, generation: generation)
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
        try checkImageCancellation(for: chapterId, generation: generation)

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
        try Task.checkCancellation()
        let generation = UUID()
        classificationGeneration = generation
        isClassifying = true
        classificationError = nil
        defer {
            if classificationGeneration == generation { isClassifying = false }
        }
        
        let chapterData = chapters.map { (index: $0.index, title: $0.title, preview: $0.contentHTML.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)) }
        
        do {
            let classifications = try await llm.classifyChapters(chapters: chapterData, settings: settings)
            try Task.checkCancellation()
            guard classificationGeneration == generation else { throw CancellationError() }
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
            if !Task.isCancelled && classificationGeneration == generation {
                classificationError = error.localizedDescription
            }
            throw error
        }
    }
    
    enum ChapterType {
        case content
        case garbage
    }
    
    // Cancellation
    func cancel(for chapterId: Int64) {
        cancelInsights(for: chapterId)
        imageCancellationGenerationByChapter[chapterId, default: 0] += 1
        for (id, producer) in producerTasks where producer.chapterId == chapterId && producer.isImage {
            producer.task.cancel()
            producerTasks.removeValue(forKey: id)
        }
        updateState(for: chapterId) { $0.isProcessingImages = false }
    }

    func cancelInsights(for chapterId: Int64) {
        cancellationGenerationByChapter[chapterId, default: 0] += 1
        for (id, producer) in producerTasks where producer.chapterId == chapterId && !producer.isImage {
            producer.task.cancel()
            producerTasks.removeValue(forKey: id)
        }
        updateState(for: chapterId) {
            $0.isProcessingInsights = false
            $0.liveThinking = ""
        }
    }
    
    func cancelAll() {
        classificationGeneration = UUID()
        isClassifying = false
        for producer in producerTasks.values { producer.task.cancel() }
        producerTasks.removeAll()
        for id in processingStates.keys {
            cancel(for: id)
        }
    }
    
    func cancel() {
        cancelAll()
    }
    
    // Helpers
    func shouldAutoProcess(_ chapter: Chapter, in chapters: [Chapter], book: Book? = nil) -> Bool {
        let hasLLMKey = settings.hasAuthentication(for: settings.llmProvider)
        guard hasLLMKey, !chapter.processed else { return false }
        if chapter.userOverride { return true }
        let isClassified = book == nil || book?.classificationStatus == .completed
        return settings.autoAIProcessingEnabled && !chapter.shouldSkipAutoProcessing && isClassified
    }
    
    private func updateState(for chapterId: Int64, transform: (inout ProcessingState) -> Void) {
        var state = processingStates[chapterId] ?? ProcessingState()
        transform(&state)
        processingStates[chapterId] = state
    }

    private func checkCancellation(for chapterId: Int64, generation: Int) throws {
        try Task.checkCancellation()
        guard cancellationGenerationByChapter[chapterId, default: 0] == generation else {
            throw CancellationError()
        }
    }

    private func checkImageCancellation(for chapterId: Int64, generation: Int) throws {
        try Task.checkCancellation()
        guard imageCancellationGenerationByChapter[chapterId, default: 0] == generation else {
            throw CancellationError()
        }
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
