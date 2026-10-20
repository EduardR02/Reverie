import SwiftUI
import Foundation

/// Orchestrates the full book processing including summary and insight generation.
@MainActor
final class BookProcessor {
    private let appState: AppState
    private let book: Book
    private let range: ClosedRange<Int>?
    private let includeContext: Bool
    private let isSimulation: Bool
    
    // Callbacks for live telemetry
    var onSummaryCountUpdate: ((Int) -> Void)?
    var onInsightCountUpdate: ((Int) -> Void)?
    var onQuizCountUpdate: ((Int) -> Void)?
    var onImageCountUpdate: ((Int) -> Void)?
    var onWordsPerInsightUpdate: ((Int) -> Void)?
    var onUsageUpdate: ((Int, Int) -> Void)? // input, output
    var onPhaseUpdate: ((String, String) -> Void)? // summaryPhase, insightPhase
    
    private var liveSummaryCount = 0
    private var liveInsightCount = 0
    private var liveQuizCount = 0
    private var liveImageCount = 0
    private var liveInputTokens = 0
    private var liveOutputTokens = 0
    private var liveTotalWords = 0
    private var summaryPhase = ""
    private var insightPhase = ""
    
    
    init(appState: AppState, book: Book, range: ClosedRange<Int>? = nil, includeContext: Bool = false, isSimulation: Bool = false) {
        self.appState = appState
        self.book = book
        self.range = range
        self.includeContext = includeContext
        self.isSimulation = isSimulation
    }
    
    func process() async {
        appState.isProcessingBook = true
        appState.processingBookId = book.id
        appState.processingProgress = 0
        appState.processingCompletedChapters = 0
        appState.processingTotalChapters = 0
        appState.processingChapter = "Preparing..."
        appState.processingCostEstimate = 0
        appState.processingInFlightSummaries = 0
        appState.processingInFlightInsights = 0
        appState.processingInFlightImages = 0

        defer {
            appState.isProcessingBook = false
            appState.processingBookId = nil
            appState.processingChapter = ""
            appState.processingInFlightSummaries = 0
            appState.processingInFlightInsights = 0
            appState.processingInFlightImages = 0
            onPhaseUpdate?("", "")
        }

        do {
            guard let bookId = book.id else { return }
            let allChapters = try appState.database.fetchChapters(for: book)
            let rangeStart = range?.lowerBound ?? 0
            let chaptersInRange = allChapters.filter { range?.contains($0.index) ?? true }
            appState.processingTotalChapters = chaptersInRange.filter { !$0.shouldSkipAutoProcessing && !$0.processed }.count
            guard appState.processingTotalChapters > 0 else {
                appState.processingProgress = 1
                return
            }

            let blockParser = ContentBlockParser()
            var rollingSummary: String?
            var coveredIdeas: [String] = []
            for chapter in allChapters where chapter.index < rangeStart {
                try Task.checkCancellation()
                if let summary = chapter.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    rollingSummary = appendRollingSummary(rollingSummary, summary: summary, chapter: chapter)
                } else if includeContext && !chapter.shouldSkipAutoProcessing {
                    summaryPhase = "Context: \(chapter.title)"
                    onPhaseUpdate?(summaryPhase, "")
                    appState.processingChapter = summaryPhase
                    let (_, text) = blockParser.parse(html: chapter.contentHTML)
                    let summary: String
                    if isSimulation {
                        summary = "Simulated context summary."
                    } else {
                        let result = try await appState.llmService.generateSummary(
                            contentWithBlocks: text, rollingSummary: rollingSummary, settings: appState.settings
                        )
                        summary = result.summary
                        if let usage = result.usage {
                            updateUsage(input: usage.input, output: usage.visibleOutput + (usage.reasoning ?? 0))
                        }
                        try Task.checkCancellation()
                        try appState.database.updateChapterSummary(
                            id: chapter.id!, summary: summary, rollingSummary: rollingSummary
                        )
                    }
                    rollingSummary = appendRollingSummary(rollingSummary, summary: summary, chapter: chapter)
                }
                coveredIdeas.append(contentsOf: try appState.database.fetchAnnotations(for: chapter).map(PromptLibrary.coverageHint))
            }

            summaryPhase = ""
            for chapter in chaptersInRange {
                try Task.checkCancellation()
                if chapter.shouldSkipAutoProcessing { continue }
                if chapter.processed {
                    if let summary = chapter.summary {
                        rollingSummary = appendRollingSummary(rollingSummary, summary: summary, chapter: chapter)
                    }
                    coveredIdeas.append(contentsOf: try appState.database.fetchAnnotations(for: chapter).map(PromptLibrary.coverageHint))
                    continue
                }

                insightPhase = chapter.title
                onPhaseUpdate?("", insightPhase)
                appState.processingChapter = "Analyzing: \(chapter.title)"
                let (blocks, text) = blockParser.parse(html: chapter.contentHTML)
                liveTotalWords += chapter.wordCount
                updateWordsPerInsight()
                let workItem = InsightWorkItem(
                    chapter: chapter, blocks: blocks, contentWithBlocks: text,
                    rollingSummary: rollingSummary, coveredIdeas: coveredIdeas
                )
                let generated = try await processInsights(for: workItem)
                try Task.checkCancellation()
                let analysis = try generated.validated(blocks: blocks)
                guard !analysis.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ChapterAnalysisValidationError.emptyField("chapter summary")
                }
                if !isSimulation {
                    var updatedChapter = chapter
                    updatedChapter.processed = true
                    updatedChapter.summary = analysis.summary
                    updatedChapter.rollingSummary = rollingSummary
                    updatedChapter.contentText = text
                    updatedChapter.blockCount = blocks.count
                    let saved = try appState.database.saveChapterAnalysis(
                        analysis, chapter: &updatedChapter, blockCount: blocks.count
                    )
                    coveredIdeas.append(contentsOf: saved.annotations.map(PromptLibrary.coverageHint))
                    await generateSuggestedImages(analysis.imageSuggestions, bookId: bookId, chapterId: chapter.id!)
                    try Task.checkCancellation()
                }

                // Only an accepted analysis becomes context for the following chapter.
                rollingSummary = appendRollingSummary(rollingSummary, summary: analysis.summary, chapter: chapter)
                liveSummaryCount += 1
                onSummaryCountUpdate?(liveSummaryCount)
                appState.processingCompletedChapters += 1
                updateProgress()
            }

            if !isSimulation {
                let freshChapters = try appState.database.fetchChapters(for: book)
                if freshChapters.filter({ !$0.shouldSkipAutoProcessing }).allSatisfy(\.processed),
                   var updatedBook = try appState.database.fetchBook(id: bookId) {
                    updatedBook.processedFully = true
                    try appState.database.saveBook(&updatedBook)
                }
            }
            appState.processingProgress = 1
            appState.triggerLibraryRefresh()
        } catch {
            if !(error is CancellationError) {
                print("Failed to process book: \(error)")
            }
            appState.triggerLibraryRefresh()
        }
    }
    
    
    private func processInsights(for workItem: InsightWorkItem) async throws -> LLMService.ChapterAnalysis {
        if isSimulation {
            appState.processingInFlightInsights += 1
            defer { appState.processingInFlightInsights = max(0, appState.processingInFlightInsights - 1) }
            
            for i in 1...5 {
                try await Task.sleep(nanoseconds: UInt64.random(in: 100_000_000...500_000_000))
                if Task.isCancelled { throw CancellationError() }
                
                if i % 2 == 0 {
                    liveInsightCount += 1
                    onInsightCountUpdate?(liveInsightCount)
                    updateWordsPerInsight()
                } else if i == 5 {
                    liveQuizCount += 1
                    onQuizCountUpdate?(liveQuizCount)
                }
                
                updateUsage(input: Int.random(in: 1000...3000), output: Int.random(in: 500...1500))
                updateCost(Double.random(in: 0.01...0.05))
            }
            
            // Simulation: Image generation
            let imageCount = Int.random(in: 1...2)
            for _ in 0..<imageCount {
                appState.processingInFlightImages += 1
                try await Task.sleep(nanoseconds: UInt64.random(in: 200_000_000...400_000_000))
                appState.processingInFlightImages = max(0, appState.processingInFlightImages - 1)
                
                liveImageCount += 1
                onImageCountUpdate?(liveImageCount)
                updateCost(0.05) // Mock image cost
            }
            
            return LLMService.ChapterAnalysis(
                annotations: [],
                quizQuestions: [],
                imageSuggestions: [],
                summary: "Simulated summary"
            )
        } else {
            let stream = appState.llmService.analyzeChapterStreaming(
                contentWithBlocks: workItem.contentWithBlocks,
                rollingSummary: workItem.rollingSummary,
                bookTitle: book.title,
                author: book.author,
                settings: appState.settings,
                coveredIdeas: workItem.coveredIdeas
            )
            
            var finalAnalysis: LLMService.ChapterAnalysis?
            for try await event in stream {
                if Task.isCancelled { throw CancellationError() }
                switch event {
                case .insightFound:
                    liveInsightCount += 1
                    onInsightCountUpdate?(liveInsightCount)
                    updateWordsPerInsight()
                case .quizQuestionFound:
                    liveQuizCount += 1
                    onQuizCountUpdate?(liveQuizCount)
                case .usage(let usage):
                    updateUsage(input: usage.input, output: usage.visibleOutput + (usage.reasoning ?? 0))
                case .completed(let result):
                    finalAnalysis = result
                case .thinking: break
                }
            }
            guard let finalAnalysis else {
                throw ChapterAnalysisValidationError.missingCompletion
            }
            return finalAnalysis
        }
    }
    
    private func generateSuggestedImages(_ suggestions: [LLMService.ImageSuggestion], bookId: Int64, chapterId: Int64) async {
        guard !Task.isCancelled, appState.settings.imagesEnabled, !suggestions.isEmpty else { return }
        let trimmedKey = appState.settings.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        
        let inputs = suggestions.map { suggestion -> ImageService.ImageSuggestionInput in
            let prompt = appState.llmService.imagePromptFromExcerpt(suggestion.excerpt, rewrite: appState.settings.rewriteImageExcerpts)
            return ImageService.ImageSuggestionInput(
                excerpt: suggestion.excerpt,
                prompt: prompt,
                sourceBlockId: suggestion.sourceBlockId,
                aspectRatio: suggestion.aspectRatio
            )
        }
        
        let results = await appState.imageService.generateImages(
            from: inputs,
            model: appState.settings.imageModel,
            apiKey: trimmedKey,
            maxConcurrent: appState.settings.maxConcurrentRequests,
            onRequestStart: { [weak appState] in
                Task { @MainActor in appState?.processingInFlightImages += 1 }
            },
            onRequestFinish: { [weak appState] in
                Task { @MainActor in appState?.processingInFlightImages = max(0, (appState?.processingInFlightImages ?? 0) - 1) }
            }
        )
        
        for result in results {
            if Task.isCancelled { return }

            do {
                var status = result.status
                var failureReason = result.failureReason
                var imagePath = ""

                if result.status == .success {
                    guard let data = result.imageData else {
                        status = .failed
                        failureReason = "Image generation returned no image data."
                        var image = GeneratedImage(
                            chapterId: chapterId,
                            excerpt: result.excerpt,
                            prompt: result.prompt,
                            imagePath: imagePath,
                            sourceBlockId: result.sourceBlockId,
                            aspectRatio: result.aspectRatio,
                            status: status,
                            failureReason: failureReason
                        )
                        try appState.database.saveImage(&image)
                        continue
                    }

                    imagePath = try appState.imageService.saveImage(data, for: bookId, chapterId: chapterId)

                    // Track total image count and cost for successful generations only
                    liveImageCount += 1
                    onImageCountUpdate?(liveImageCount)

                    if let imageCost = LLMCallUsage.calculatedImageCost(for: appState.settings.imageModel) {
                        updateCost(imageCost)
                    }
                    do {
                        try appState.database.saveImageGenerationUsage(model: appState.settings.imageModel)
                    } catch {
                        print("Failed to save image usage: \(error)")
                    }
                }

                var image = GeneratedImage(
                    chapterId: chapterId,
                    excerpt: result.excerpt,
                    prompt: result.prompt,
                    imagePath: imagePath,
                    sourceBlockId: result.sourceBlockId,
                    aspectRatio: result.aspectRatio,
                    status: status,
                    failureReason: failureReason
                )
                try appState.database.saveImage(&image)
                if status == .success {
                    appState.readingStats.recordImage()
                }
            } catch {
                print("Failed to save image: \(error)")
            }
        }
    }
    
    
    private func updateProgress() {
        appState.processingProgress = Double(appState.processingCompletedChapters) / Double(max(1, appState.processingTotalChapters))
    }
    
    private func updateUsage(input: Int, output: Int) {
        liveInputTokens += input
        liveOutputTokens += output
        onUsageUpdate?(liveInputTokens, liveOutputTokens)
    }
    
    private func updateCost(_ delta: Double) {
        appState.processingCostEstimate += delta
    }
    
    private func updateWordsPerInsight() {
        let ratio = liveInsightCount > 0 ? liveTotalWords / liveInsightCount : 0
        onWordsPerInsightUpdate?(ratio)
    }
    
    
    private func appendRollingSummary(_ existing: String?, summary: String, chapter: Chapter) -> String? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        let entry = "Chapter \(chapter.index + 1): \(chapter.title)\n\(trimmed)"
        if let existing, !existing.isEmpty { return existing + "\n\n" + entry }
        return entry
    }

    private struct InsightWorkItem {
        let chapter: Chapter
        let blocks: [ContentBlock]
        let contentWithBlocks: String
        let rollingSummary: String?
        let coveredIdeas: [String]
    }
}
