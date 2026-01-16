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
    var onCostUpdate: ((Double) -> Void)?
    
    private var liveSummaryCount = 0
    private var liveInsightCount = 0
    private var liveQuizCount = 0
    private var liveImageCount = 0
    private var liveInputTokens = 0
    private var liveOutputTokens = 0
    private var liveTotalWords = 0
    private var summaryPhase = ""
    private var insightPhase = ""
    private var costEstimate: Double = 0
    
    private var runningInsightCount = 0
    private var lastInsightTitle: String?
    private var runningInsightTasks: [Task<Void, Never>] = []
    
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
            
            // Filter by range if provided
            let effectiveRange = range ?? 0...(allChapters.count - 1)
            let chaptersInRange = allChapters.filter { effectiveRange.contains($0.index) }
            
            // Only count chapters that actually require processing for the total
            let chaptersToProcess = chaptersInRange.filter { !$0.shouldSkipAutoProcessing && !$0.processed }
            appState.processingTotalChapters = chaptersToProcess.count
            
            if chaptersToProcess.isEmpty {
                appState.processingProgress = 1.0
                onPhaseUpdate?("Complete!", "")
                appState.processingChapter = "Complete!"
                return
            }
            
            let blockParser = ContentBlockParser()
            var rollingSummary: String?
            
            // Phase 1: Context building
            if includeContext && effectiveRange.lowerBound > 0 {
                appState.processingChapter = "Building context..."
                let contextChapters = allChapters.filter { $0.index < effectiveRange.lowerBound }
                
                for chapter in contextChapters {
                    if Task.isCancelled { return }
                    
                    if let existingSummary = chapter.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !existingSummary.isEmpty {
                        rollingSummary = appendRollingSummary(rollingSummary, summary: existingSummary)
                    } else if !chapter.shouldSkipAutoProcessing {
                        onPhaseUpdate?("Context: \(chapter.title)", "")
                        let (_, contentWithBlocks) = blockParser.parse(html: chapter.contentHTML)
                        
                        let summary: String
                        if isSimulation {
                            appState.processingInFlightSummaries += 1
                            defer { appState.processingInFlightSummaries = max(0, appState.processingInFlightSummaries - 1) }
                            summary = "Simulated context summary."
                        } else {
                            let (generatedSummary, usage) = try await appState.llmService.generateSummary(
                                contentWithBlocks: contentWithBlocks,
                                rollingSummary: rollingSummary,
                                settings: appState.settings
                            )
                            summary = generatedSummary
                            if let usage {
                                updateUsage(input: usage.input, output: usage.visibleOutput + (usage.reasoning ?? 0))
                            }
                        }
                        
                        var updatedChapter = chapter
                        updatedChapter.summary = summary
                        updatedChapter.rollingSummary = rollingSummary
                        try appState.database.saveChapter(&updatedChapter)
                        
                        rollingSummary = appendRollingSummary(rollingSummary, summary: summary)
                    }
                }
            } else if effectiveRange.lowerBound > 0 {
                let previousChapters = allChapters.filter { $0.index < effectiveRange.lowerBound }
                for chapter in previousChapters {
                    if let existingSummary = chapter.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !existingSummary.isEmpty {
                        rollingSummary = appendRollingSummary(rollingSummary, summary: existingSummary)
                    }
                }
            }
            
            // Phase 2: Processing range
            for chapter in chaptersInRange {
                if Task.isCancelled {
                    await cancelAllInsightTasks()
                    return
                }
                
                if chapter.shouldSkipAutoProcessing { continue }
                if chapter.processed {
                    if let summary = chapter.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                        rollingSummary = appendRollingSummary(rollingSummary, summary: summary)
                    }
                    continue
                }
                
                // Update UI
                summaryPhase = chapter.title
                onPhaseUpdate?(summaryPhase, insightPhase)
                appState.processingChapter = "Summarizing: \(chapter.title)"
                updateProgress()
                
                let (blocks, contentWithBlocks) = blockParser.parse(html: chapter.contentHTML)
                let chapterRollingSummary = rollingSummary
                
                // Track words for words-per-insight metric
                liveTotalWords += chapter.wordCount
                updateWordsPerInsight()
                
                let existingSummary = chapter.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
                let reuseSummary = (existingSummary?.isEmpty == false) && chapter.rollingSummary == chapterRollingSummary
                let summary: String
                
                if reuseSummary {
                    summary = existingSummary ?? ""
                } else if isSimulation {
                    appState.processingInFlightSummaries += 1
                    defer { appState.processingInFlightSummaries = max(0, appState.processingInFlightSummaries - 1) }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    summary = "Simulated summary for chapter \(chapter.index + 1)."
                    updateUsage(input: 1000, output: 500)
                    updateCost(0.02)
                } else {
                    let (generatedSummary, usage) = try await appState.llmService.generateSummary(
                        contentWithBlocks: contentWithBlocks,
                        rollingSummary: chapterRollingSummary,
                        settings: appState.settings
                    )
                    summary = generatedSummary
                    if let usage {
                        updateUsage(input: usage.input, output: usage.visibleOutput + (usage.reasoning ?? 0))
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
                onSummaryCountUpdate?(liveSummaryCount)
                rollingSummary = appendRollingSummary(rollingSummary, summary: summary)
                
                if Task.isCancelled {
                    await cancelAllInsightTasks()
                    return
                }
                
                // Fire insight task
                let workItem = InsightWorkItem(
                    chapter: updatedChapter,
                    blocks: blocks,
                    contentWithBlocks: contentWithBlocks,
                    rollingSummary: chapterRollingSummary
                )
                startInsightTask(workItem: workItem, bookId: bookId)
            }
            
            // Wait for insights
            summaryPhase = ""
            onPhaseUpdate?(summaryPhase, insightPhase)
            if insightPhase.isEmpty {
                appState.processingChapter = "Finalizing..."
            }
            
            for task in runningInsightTasks {
                await task.value
            }
            
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
            onPhaseUpdate?("", "")
            appState.processingChapter = "Complete!"
            appState.triggerLibraryRefresh()
            
        } catch {
            await cancelAllInsightTasks()
            if !(error is CancellationError) {
                print("Failed to process book: \(error)")
            }
        }
    }
    
    private func startInsightTask(workItem: InsightWorkItem, bookId: Int64) {
        lastInsightTitle = workItem.chapter.title
        runningInsightCount += 1
        updateInsightPhaseUI()
        
        let task = Task {
            defer {
                runningInsightCount -= 1
                updateInsightPhaseUI()
            }
            
            do {
                let analysis = try await processInsights(for: workItem, bookId: bookId)
                
                if !isSimulation, let analysis, let chapterId = workItem.chapter.id {
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
                updateProgress()
            } catch {
                print("Insight task failed: \(error)")
            }
        }
        runningInsightTasks.append(task)
    }
    
    private func processInsights(for workItem: InsightWorkItem, bookId: Int64) async throws -> LLMService.ChapterAnalysis? {
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
                annotations: [
                    LLMService.AnnotationData(type: "science", title: "Simulated Insight", content: "Simulated content", sourceBlockId: 1)
                ],
                quizQuestions: [
                    LLMService.QuizData(question: "Simulated question?", answer: "Simulated answer", sourceBlockId: 1)
                ],
                imageSuggestions: [
                    LLMService.ImageSuggestion(excerpt: "Simulated image excerpt", sourceBlockId: 1)
                ],
                summary: "Simulated summary"
            )
        } else {
            let stream = appState.llmService.analyzeChapterStreaming(
                contentWithBlocks: workItem.contentWithBlocks,
                rollingSummary: workItem.rollingSummary,
                bookTitle: book.title,
                author: book.author,
                settings: appState.settings
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
            return finalAnalysis
        }
    }
    
    private func generateSuggestedImages(_ suggestions: [LLMService.ImageSuggestion], blockCount: Int, bookId: Int64, chapterId: Int64) async {
        guard appState.settings.imagesEnabled, !suggestions.isEmpty else { return }
        let trimmedKey = appState.settings.googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        
        let inputs = suggestions.map { suggestion -> ImageService.ImageSuggestionInput in
            let validBlockId = suggestion.sourceBlockId > 0 && suggestion.sourceBlockId <= blockCount ? suggestion.sourceBlockId : 1
            let prompt = appState.llmService.imagePromptFromExcerpt(suggestion.excerpt, rewrite: appState.settings.rewriteImageExcerpts)
            return ImageService.ImageSuggestionInput(excerpt: suggestion.excerpt, prompt: prompt, sourceBlockId: validBlockId)
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
            
            // Track total image count
            liveImageCount += 1
            onImageCountUpdate?(liveImageCount)
            
            // Fix Real Mode Image Cost Tracking
            let pricing = PricingCatalog.imagePricing(for: appState.settings.imageModel)
            if let perImage = pricing.outputPerImage {
                updateCost(perImage)
            } else if let outputPerM = pricing.outputPerMToken {
                // Approximate image cost if based on tokens
                let tokens = CostEstimates.imageOutputTokensPerImage
                updateCost((Double(tokens) / 1_000_000) * outputPerM)
            }
            
            do {
                let imagePath = try appState.imageService.saveImage(result.imageData, for: bookId, chapterId: chapterId)
                var image = GeneratedImage(chapterId: chapterId, prompt: result.excerpt, imagePath: imagePath, sourceBlockId: result.sourceBlockId)
                try appState.database.saveImage(&image)
                appState.readingStats.recordImage()
            } catch {
                print("Failed to save image: \(error)")
            }
        }
    }
    
    private func updateInsightPhaseUI() {
        guard runningInsightCount > 0 else {
            insightPhase = ""
            if summaryPhase.isEmpty { appState.processingChapter = "" }
            onPhaseUpdate?(summaryPhase, insightPhase)
            return
        }
        
        let title = lastInsightTitle ?? "Insights"
        let suffix = runningInsightCount > 1 ? " (+\(runningInsightCount - 1) more)" : ""
        insightPhase = "\(title)\(suffix)"
        if summaryPhase.isEmpty {
            appState.processingChapter = "Insights: \(insightPhase)"
        }
        onPhaseUpdate?(summaryPhase, insightPhase)
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
        costEstimate += delta
        appState.processingCostEstimate = costEstimate
        onCostUpdate?(costEstimate)
    }
    
    private func updateWordsPerInsight() {
        let ratio = liveInsightCount > 0 ? liveTotalWords / liveInsightCount : 0
        onWordsPerInsightUpdate?(ratio)
    }
    
    private func cancelAllInsightTasks() async {
        for task in runningInsightTasks { task.cancel() }
        runningInsightTasks.removeAll()
    }
    
    private func appendRollingSummary(_ existing: String?, summary: String) -> String? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        if let existing, !existing.isEmpty { return existing + "\n\n" + trimmed }
        return trimmed
    }
    
    private struct InsightWorkItem {
        let chapter: Chapter
        let blocks: [ContentBlock]
        let contentWithBlocks: String
        let rollingSummary: String?
    }
}
