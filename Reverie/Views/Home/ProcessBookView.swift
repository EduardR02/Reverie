import SwiftUI

struct ProcessBookView: View {
    let book: Book
    let isProcessing: Bool
    let progress: Double
    let currentChapter: String
    let onStart: (ClosedRange<Int>, Bool) -> Void
    let onClose: () -> Void
    let onStop: () -> Void

    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState

    @State private var metadata: [ChapterMetadata] = []
    @State private var startChapterIndex: Int = 0
    @State private var endChapterIndex: Int = 0
    @State private var includeContextSummary: Bool = true

    @State private var chapterStats = ChapterEstimateStats()
    @State private var classificationStatus: ClassificationStatus = .pending
    @State private var classificationError: String?
    @State private var isClassifying = false
    @State private var showBreakdown = false

    @State private var showRangeSettings = false
    @State private var showAIOptions = false
    @State private var showingStartPicker = false
    @State private var showingEndPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 20)

            if isProcessing {
                processingView
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        metricsGrid
                        
                        costOverview
                        
                        rangeSection
                        
                        aiOptionsSection
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer(minLength: 20)

            actionRow
        }
        .padding(28)
        .frame(width: 440)
        .frame(maxHeight: 720)
        .background(theme.base)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color.black.opacity(0.15), radius: 30, x: 0, y: 20)
        .onAppear {
            classificationStatus = book.classificationStatus
            classificationError = book.classificationError
            refreshEstimateStats()
        }
    }

    // MARK: - Sections

    private var rangeSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    showRangeSettings.toggle()
                }
            } label: {
                HStack {
                    Label("Chapter Range", systemImage: "list.number")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.text)
                    
                    Spacer()
                    
                    Text(rangeLabel)
                        .font(.system(size: 12))
                        .foregroundColor(theme.muted)
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.subtle)
                        .rotationEffect(.degrees(showRangeSettings ? 90 : 0))
                }
                .padding(16)
                .background(theme.surface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showRangeSettings {
                VStack(spacing: 12) {
                    HStack(spacing: 0) {
                        chapterRangeCard(
                            label: "START",
                            index: startChapterIndex,
                            color: theme.rose,
                            isShowingPicker: $showingStartPicker
                        ) { newIndex in
                            startChapterIndex = newIndex
                            if startChapterIndex > endChapterIndex {
                                endChapterIndex = startChapterIndex
                            }
                            refreshEstimateStats(updateIndices: false)
                        }

                        rangeConnector

                        chapterRangeCard(
                            label: "END",
                            index: endChapterIndex,
                            color: theme.iris,
                            isShowingPicker: $showingEndPicker
                        ) { newIndex in
                            endChapterIndex = newIndex
                            if endChapterIndex < startChapterIndex {
                                startChapterIndex = endChapterIndex
                            }
                            refreshEstimateStats(updateIndices: false)
                        }
                    }
                    
                    if startChapterIndex > 0 {
                        let contextRange = startChapterIndex == 1 ? "Ch. 1" : "Ch. 1–\(startChapterIndex)"
                        Text("Include context summaries: \(contextRange)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(includeContextSummary ? theme.rose : theme.muted)
                            .opacity(includeContextSummary ? 1.0 : 0.6)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .background(theme.surface)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.overlay, lineWidth: 1)
        }
    }

    private var aiOptionsSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    showAIOptions.toggle()
                }
            } label: {
                HStack {
                    Label("AI & Filtering", systemImage: "wand.and.stars")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.text)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.subtle)
                        .rotationEffect(.degrees(showAIOptions ? 90 : 0))
                }
                .padding(16)
                .background(theme.surface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAIOptions {
                VStack(spacing: 16) {
                    if appState.settings.imagesEnabled {
                        imageInclusionCard
                    }
                    
                    garbageFilterSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .background(theme.surface)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.overlay, lineWidth: 1)
        }
    }

    private var rangeLabel: String {
        if metadata.isEmpty { return "" }
        if startChapterIndex == 0 && endChapterIndex == metadata.count - 1 {
            return "Full Book"
        }
        return "Ch. \(startChapterIndex + 1) – \(endChapterIndex + 1)"
    }

    private func chapterRangeCard(
        label: String,
        index: Int,
        color: Color,
        isShowingPicker: Binding<Bool>,
        onSelect: @escaping (Int) -> Void
    ) -> some View {
        Button {
            isShowingPicker.wrappedValue = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 9, weight: .black))
                    .foregroundColor(theme.muted)
                    .opacity(0.8)
                
                if metadata.indices.contains(index) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(color)
                        
                        Text(metadata[index].title)
                            .font(.system(size: 12))
                            .foregroundColor(theme.muted)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.overlay.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.highlightHigh.opacity(0.3), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: isShowingPicker, arrowEdge: .bottom) {
            ChapterPicker(
                chapters: metadata,
                selection: index,
                theme: theme,
                onSelect: onSelect
            )
        }
    }

    private var rangeConnector: some View {
        ZStack {
            Rectangle()
                .fill(theme.overlay)
                .frame(width: 32, height: 1)
            
            if startChapterIndex > 0 {
                Button {
                    withAnimation(.spring(duration: 0.2)) {
                        includeContextSummary.toggle()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(theme.surface)
                            .frame(width: 24, height: 24)
                        
                        Image(systemName: includeContextSummary ? "brain.head.profile.fill" : "brain.head.profile")
                            .font(.system(size: 12))
                            .foregroundColor(includeContextSummary ? theme.rose : theme.muted)
                    }
                    .overlay {
                        Circle()
                            .stroke(includeContextSummary ? theme.rose.opacity(0.5) : theme.overlay, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .help("Build Context Summary: Include previous chapters in AI memory")
            }
        }
        .frame(width: 44)
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
                    costDetailRow("Tokens (In)", Formatters.formatTokenCount(Int(estimatedInputTokens)))
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
                Circle()
                    .stroke(theme.rose.opacity(0.1), lineWidth: 8)
                    .frame(width: 180, height: 180)
                
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
            
            VStack(spacing: 12) {
                VStack(spacing: 8) {
                    Text(currentChapter.isEmpty ? "Preparing..." : currentChapter)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                    
                    Text("Estimated time remaining: \(formatRemainingTime())")
                        .font(.system(size: 13))
                        .foregroundColor(theme.muted)
                    
                    if appState.processingCostEstimate > 0 {
                        Text(String(format: "$%.2f spent", appState.processingCostEstimate))
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.foam)
                            .padding(.top, 4)
                    }
                }
                
                inFlightRow
            }
        }
    }

    private var inFlightRow: some View {
        HStack(spacing: 16) {
            inFlightItem(icon: "doc.text", count: appState.processingInFlightSummaries, color: theme.gold)
            inFlightItem(icon: "lightbulb", count: appState.processingInFlightInsights, color: theme.rose)
            inFlightItem(icon: "photo", count: appState.processingInFlightImages, color: theme.foam)
        }
    }

    private func inFlightItem(icon: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .foregroundColor(count > 0 ? color : theme.subtle)
        .opacity(count > 0 ? 1.0 : 0.4)
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
                    onStart(startChapterIndex...endChapterIndex, includeContextSummary)
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
        let perChapter = CostEstimates.analysisOutputTokensPerChapterRange(for: appState.settings.llmModel)
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

    private func formatTokenRange(_ range: ClosedRange<Double>) -> String {
        let minText = Formatters.formatTokenCount(Int(range.lowerBound))
        let maxText = Formatters.formatTokenCount(Int(range.upperBound))
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

    private func refreshEstimateStats(updateIndices: Bool = true) {
        let currentMetadata = metadata
        let bookToFetch = book
        let database = appState.database
        let currentStartIndex = startChapterIndex
        let currentEndIndex = endChapterIndex

        Task {
            do {
                let fetchedMetadata: [ChapterMetadata]
                if currentMetadata.isEmpty {
                    fetchedMetadata = try await Task.detached(priority: .userInitiated) {
                        try database.fetchChapterMetadata(for: bookToFetch)
                    }.value
                } else {
                    fetchedMetadata = currentMetadata
                }

                let finalStartIndex = updateIndices ? 0 : currentStartIndex
                let finalEndIndex = updateIndices ? max(0, fetchedMetadata.count - 1) : currentEndIndex
                
                let range = finalStartIndex...finalEndIndex
                let rangeMetadata = fetchedMetadata.filter { range.contains($0.index) }
                
                var totalWords = 0
                var excludedChapters = 0
                var includedWords = 0
                var includedChapters = 0
                var alreadyProcessedChapters = 0
                
                for chapter in rangeMetadata {
                    totalWords += chapter.wordCount
                    if chapter.shouldSkipAutoProcessing || chapter.processed {
                        excludedChapters += 1
                    }
                    if !chapter.shouldSkipAutoProcessing && !chapter.processed {
                        includedWords += chapter.wordCount
                        includedChapters += 1
                    }
                    if chapter.processed {
                        alreadyProcessedChapters += 1
                    }
                }
                
                let previewWords = fetchedMetadata.reduce(0) { total, chapter in
                    total + min(chapter.wordCount, CostEstimates.classificationPreviewWordLimit)
                }

                let stats = ChapterEstimateStats(
                    totalWords: totalWords,
                    totalChapters: rangeMetadata.count,
                    excludedChapters: excludedChapters,
                    includedWords: includedWords,
                    includedChapters: includedChapters,
                    classificationPreviewWords: previewWords,
                    alreadyProcessedChapters: alreadyProcessedChapters
                )

                await MainActor.run {
                    self.metadata = fetchedMetadata
                    if updateIndices {
                        self.startChapterIndex = finalStartIndex
                        self.endChapterIndex = finalEndIndex
                    }
                    self.chapterStats = stats
                }
            } catch {
                print("Failed to fetch chapters for estimate: \(error)")
            }
        }
    }

    private func classifyBookForEstimate() async {
        guard !isClassifying else { return }

        isClassifying = true
        classificationError = nil
        classificationStatus = .inProgress

        let bookId = book.id
        let settings = appState.settings
        let database = appState.database
        let llmService = appState.llmService
        let bookToClassify = self.book

        do {
            // 1. Prepare data in background
            let chapterData = try await Task.detached(priority: .userInitiated) {
                if let bId = bookId {
                    try database.updateBookClassificationStatus(id: bId, status: .inProgress)
                }

                let chapters = try database.fetchChapters(for: bookToClassify)
                return chapters.map { chapter in
                    let plainText = chapter.contentHTML
                        .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return (index: chapter.index, title: chapter.title, preview: plainText)
                }
            }.value

            // 2. Classify (MainActor async call, doesn't block)
            let classifications = try await llmService.classifyChapters(
                chapters: chapterData,
                settings: settings
            )

            // 3. Save results in background
            try await Task.detached(priority: .userInitiated) {
                if let bId = bookId {
                    try database.updateChapterGarbageStatus(bookId: bId, classifications: classifications)
                    try database.updateBookClassificationStatus(id: bId, status: .completed)
                }
            }.value

            // 4. Update UI
            await MainActor.run {
                classificationStatus = .completed
                classificationError = nil
                metadata = []
                refreshEstimateStats(updateIndices: false)
                isClassifying = false
            }
        } catch {
            let errorMessage = error.localizedDescription
            
            // Update book error status in background
            if let bId = bookId {
                _ = try? await Task.detached(priority: .userInitiated) {
                    try database.updateBookClassificationStatus(id: bId, status: .failed, error: errorMessage)
                }.value
            }

            await MainActor.run {
                classificationStatus = .failed
                classificationError = errorMessage
                isClassifying = false
            }
        }
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

private struct ChapterPicker: View {
    let chapters: [ChapterMetadata]
    let selection: Int
    let theme: Theme
    let onSelect: (Int) -> Void
    
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss
    
    private var filteredChapters: [(Int, ChapterMetadata)] {
        let all = Array(chapters.enumerated())
        if searchText.isEmpty {
            return all.map { ($0.offset, $0.element) }
        }
        return all.filter { index, chapter in
            String(index + 1).hasPrefix(searchText) ||
            chapter.title.localizedCaseInsensitiveContains(searchText)
        }.map { ($0.offset, $0.element) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.subtle)
                
                TextField("Search chapters...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.text)
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(theme.subtle)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.overlay.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(12)
            
            Divider()
                .background(theme.overlay)
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredChapters, id: \.0) { index, chapter in
                            Button {
                                onSelect(index)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundColor(index == selection ? theme.rose : theme.muted)
                                        .frame(width: 28, alignment: .trailing)
                                    
                                    Text(chapter.title)
                                        .font(.system(size: 13))
                                        .foregroundColor(index == selection ? theme.text : theme.muted)
                                        .lineLimit(1)
                                    
                                    Spacer()
                                    
                                    if index == selection {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(theme.rose)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(index == selection ? theme.rose.opacity(0.1) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 300)
                .onAppear {
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
        .frame(width: 280)
        .background(theme.surface)
    }
}
