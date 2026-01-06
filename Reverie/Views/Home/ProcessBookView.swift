import SwiftUI

struct ProcessBookView: View {
    let book: Book
    let isProcessing: Bool
    let progress: Double
    let currentChapter: String
    let onStart: () -> Void
    let onClose: () -> Void
    let onStop: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    @State private var chapterStats = ChapterEstimateStats()
    @State private var classificationStatus: ClassificationStatus = .pending
    @State private var classificationError: String?
    @State private var isClassifying = false
    @State private var showBreakdown = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 24)

            if isProcessing {
                processingView
            } else {
                VStack(spacing: 20) {
                    metricsGrid
                    
                    costOverview
                    
                    if appState.settings.imagesEnabled {
                        imageInclusionCard
                    }
                    
                    garbageFilterSection
                }
            }

            Spacer(minLength: 24)

            actionRow
        }
        .padding(32)
        .frame(width: 440)
        .background(theme.base)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color.black.opacity(0.15), radius: 30, x: 0, y: 20)
        .onAppear {
            classificationStatus = book.classificationStatus
            classificationError = book.classificationError
            refreshEstimateStats()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(theme.rose.opacity(0.15))
                    .frame(width: 52, height: 52)
                
                Image(systemName: isProcessing ? "bolt.fill" : "sparkles")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(theme.rose)
                    .symbolEffect(.pulse, isActive: isProcessing)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(isProcessing ? "Enhancing your library" : "Process Book")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.text)

                Text(book.title)
                    .font(.system(size: 14))
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    // MARK: - Metrics

    private var metricsGrid: some View {
        HStack(spacing: 16) {
            MetricCard(
                title: "Chapters",
                value: chapterCountLabel,
                icon: "list.bullet.indent",
                theme: theme
            )
            MetricCard(
                title: "Word Count",
                value: formatWordCount(estimatedWordCount),
                icon: "text.alignleft",
                theme: theme
            )
        }
    }

    // MARK: - Cost Overview

    private var costOverview: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ESTIMATED TOTAL")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(theme.subtle)
                    
                    Text(formatCostRange(totalCostRangeWithImages))
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.text)
                }
                
                Spacer() 
                
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        showBreakdown.toggle()
                    }
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 20))
                        .foregroundColor(showBreakdown ? theme.rose : theme.subtle)
                }
                .buttonStyle(.plain)
            }
            
            if showBreakdown {
                VStack(spacing: 8) {
                    costDetailRow("Analysis Model", appState.settings.llmProvider.modelName(for: appState.settings.llmModel))
                    if appState.settings.imagesEnabled {
                        costDetailRow("Image Model", appState.settings.imageModel.rawValue)
                    }
                    Divider()
                        .padding(.vertical, 4)
                        .opacity(0.3)
                    costDetailRow("Tokens (In)", formatTokenCount(estimatedInputTokens))
                    costDetailRow("Tokens (Out)", formatTokenRange(estimatedOutputTokensRange))
                    costDetailRow("Text Analysis", formatCostRange(textCostRange))
                    if appState.settings.imagesEnabled {
                        costDetailRow("Visual Generation", formatCost(estimatedImageCost))
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(24)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.black.opacity(0.03), radius: 10, x: 0, y: 5)
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(theme.rose.opacity(0.1), lineWidth: 1)
        }
    }

    private func costDetailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(theme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.text)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Image Inclusion

    private var imageInclusionCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 20))
                .foregroundColor(theme.foam)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Visual Supplement")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.text)
                
                Text("~\(formatDecimal(estimatedImageCount)) images at \(appState.settings.imageDensity.rawValue.lowercased()) density")
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
            }
            
            Spacer()
            
            Text(formatCost(estimatedImageCost))
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(theme.foam)
        }
        .padding(16)
        .background(theme.foam.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Garbage Filter

    private var garbageFilterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Intelligent Filtering")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.text)
                    
                    Text("Skip copyright, TOC, and meta pages")
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)
                }
                
                Spacer()
                
                if classificationStatus == .completed {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(theme.foam)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(theme.foam.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            
            if classificationStatus != .completed || isClassifying {
                Button {
                    Task { await classifyBookForEstimate() }
                } label: {
                    HStack {
                        if isClassifying {
                            ProgressView()
                                .controlSize(.small)
                                .tint(theme.iris)
                                .padding(.trailing, 4)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        
                        Text(isClassifying ? "Scanning..." : "Run Quick Scan (\(formatCost(classificationCostEstimate)))")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.iris)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(theme.iris.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(isClassifying || classificationKeyMissing)
            }
        }
        .padding(16)
        .background(theme.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Processing View

    private var processingView: some View {
        VStack(spacing: 32) {
            ZStack {
                // Outer glow circle
                Circle()
                    .stroke(theme.rose.opacity(0.1), lineWidth: 8)
                    .frame(width: 180, height: 180)
                
                // Progress circle
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        LinearGradient(
                            colors: [theme.rose, theme.iris],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 180, height: 180)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring, value: progress)
                
                VStack(spacing: 4) {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundColor(theme.text)
                    
                    Text("COMPLETED")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(theme.subtle)
                }
            }
            .padding(.top, 20)
            
            VStack(spacing: 8) {
                Text(currentChapter.isEmpty ? "Preparing..." : currentChapter)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                
                Text("Estimated time remaining: \(formatRemainingTime())")
                    .font(.system(size: 13))
                    .foregroundColor(theme.muted)
            }
        }
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 16) {
            if isProcessing {
                Button("Background") {
                    onClose()
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(maxWidth: .infinity)

                Button {
                    onStop()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(CancelButtonStyle())
                .frame(maxWidth: .infinity)
            } else {
                Button("Cancel") {
                    onClose()
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(maxWidth: .infinity)

                Button("Start Processing") {
                    onStart()
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(apiKeyMissing)
            }
        }
    }

    // MARK: - Helpers (Copied/Adapted from ProcessBookSheet)

    private func formatRemainingTime() -> String {
        guard progress > 0 else { return "Calculating..." }
        let remaining = 1.0 - progress
        let chaptersRemaining = Double(chapterStats.includedChapters) * remaining
        // Arbitrary estimate: 60 seconds per chapter (text + several images)
        let seconds = Int(chaptersRemaining * 60)
        
        if seconds < 60 {
            return "Less than a minute"
        } else {
            return "\(seconds / 60)m \(seconds % 60)s"
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
        // Show remaining chapters to process
        let remaining = chapterStats.includedChapters
        let total = chapterStats.totalChapters
        let processed = chapterStats.alreadyProcessedChapters

        if remaining == 0 && processed > 0 {
            return "All done"
        } else if processed > 0 || chapterStats.excludedChapters > 0 {
            return "\(remaining)/\(total)"
        }
        return "\(remaining)"
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

            // Exclude garbage chapters AND already processed chapters
            let excluded = chapters.filter { $0.shouldSkipAutoProcessing || $0.processed }
            let included = chapters.filter { !$0.shouldSkipAutoProcessing && !$0.processed }
            let includedWords = included.reduce(0) { $0 + $1.wordCount }
            let previewWords = chapters.reduce(0) { total, chapter in
                total + min(chapter.wordCount, CostEstimates.classificationPreviewWordLimit)
            }

            // Count already processed separately for display
            let alreadyProcessed = chapters.filter { $0.processed }.count

            chapterStats = ChapterEstimateStats(
                totalWords: totalWords,
                totalChapters: chapters.count,
                excludedChapters: excluded.count,
                includedWords: includedWords,
                includedChapters: included.count,
                classificationPreviewWords: previewWords,
                alreadyProcessedChapters: alreadyProcessed
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

        // Fetch fresh copy to avoid overwriting newer data
        var updatedBook = (try? appState.database.fetchAllBooks().first(where: { $0.id == book.id })) ?? book
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

            if var finalBook = try? appState.database.fetchAllBooks().first(where: { $0.id == book.id }) {
                finalBook.classificationStatus = .completed
                finalBook.classificationError = nil
                try appState.database.saveBook(&finalBook)
            }
        } catch {
            classificationStatus = .failed
            classificationError = error.localizedDescription

            if var errorBook = try? appState.database.fetchAllBooks().first(where: { $0.id == book.id }) {
                errorBook.classificationStatus = .failed
                errorBook.classificationError = error.localizedDescription
                try? appState.database.saveBook(&errorBook)
            }
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

// MARK: - Subcomponents

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let theme: Theme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(theme.rose)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(theme.text)
                
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.03), radius: 8, x: 0, y: 4)
    }
}

private struct CancelButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(theme.love)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(theme.love.opacity(0.12))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(theme.love.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: theme.love.opacity(0.15), radius: 6, y: 2)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

private struct ChapterEstimateStats {
    var totalWords: Int = 0
    var totalChapters: Int = 0
    var excludedChapters: Int = 0
    var includedWords: Int = 0
    var includedChapters: Int = 0
    var classificationPreviewWords: Int = 0
    var alreadyProcessedChapters: Int = 0
}
