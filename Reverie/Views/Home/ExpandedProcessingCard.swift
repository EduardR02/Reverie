import SwiftUI

struct ExpandedProcessingCard: View {
    let book: Book
    let status: BookProcessingStatus
    let summariesCompleted: Int
    let totalChapters: Int
    let liveInsightCount: Int
    let liveQuizCount: Int
    let summaryPhase: String
    let insightPhase: String
    let liveInputTokens: Int
    let liveOutputTokens: Int
    let startTime: Date?
    let onCancel: () -> Void
    let processingCost: Double

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 24) {
            // Large cover on the left
            coverView
                .frame(width: 140, height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

            // Content on the right
            VStack(alignment: .leading, spacing: 16) {
                // Title and author
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(theme.text)
                        .lineLimit(2)

                    Text(book.author)
                        .font(.system(size: 13))
                        .foregroundColor(theme.muted)
                }

                // Progress bar
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.overlay)
                                .frame(height: 8)

                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    LinearGradient(
                                        colors: [theme.rose, theme.iris],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geometry.size.width * status.progress, height: 8)
                                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: status.progress)
                        }
                    }
                    .frame(height: 8)

                    // Separate phase lines
                    phaseDisplay
                }

                // Telemetry grid
                HStack(spacing: 0) {
                    telemetryItem(
                        icon: "doc.text.fill",
                        value: "\(summariesCompleted)/\(totalChapters)",
                        label: "Summaries",
                        color: theme.gold
                    )

                    telemetryItem(
                        icon: "lightbulb.fill",
                        value: "\(liveInsightCount)",
                        label: "Insights",
                        color: theme.rose
                    )

                    telemetryItem(
                        icon: "checkmark.circle.fill",
                        value: "\(liveQuizCount)",
                        label: "Questions",
                        color: theme.foam
                    )

                    costTelemetryItem

                    tokenTelemetryItem

                    telemetryItem(
                        icon: "clock.fill",
                        value: estimatedTimeRemaining,
                        label: "ETA",
                        color: theme.iris
                    )
                }

                // Cancel button
                Button {
                    onCancel()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Cancel")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(theme.love)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.love.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: 600)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.rose.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: theme.rose.opacity(0.1), radius: 20, y: 8)
    }

    // MARK: - Phase Display

    @ViewBuilder
    private var phaseDisplay: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !summaryPhase.isEmpty {
                HStack(spacing: 4) {
                    Text("Summary:")
                        .foregroundColor(theme.gold)
                    Text(summaryPhase)
                        .foregroundColor(theme.subtle)
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }

            if !insightPhase.isEmpty {
                HStack(spacing: 4) {
                    Text("Insights:")
                        .foregroundColor(theme.rose)
                    Text(insightPhase)
                        .foregroundColor(theme.subtle)
                }
                .font(.system(size: 11))
                .lineLimit(1)
            }

            // Fallback if both are empty
            if summaryPhase.isEmpty && insightPhase.isEmpty {
                Text("Preparing...")
                    .font(.system(size: 11))
                    .foregroundColor(theme.subtle)
            }
        }
    }

    // MARK: - Cost Telemetry

    private var costTelemetryItem: some View {
        VStack(spacing: 4) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.rose)

            Text(String(format: "$%.2f", processingCost))
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(theme.text)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3), value: processingCost)

            Text("Spent")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Token Telemetry

    private var tokenTelemetryItem: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12))
                .foregroundColor(theme.pine)

            HStack(spacing: 2) {
                Text(formatTokens(liveInputTokens))
                Text("/")
                    .foregroundColor(theme.muted)
                Text(formatTokens(liveOutputTokens))
            }
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundColor(theme.text)
            .contentTransition(.numericText())
            .animation(.spring(response: 0.3), value: liveInputTokens)
            .animation(.spring(response: 0.3), value: liveOutputTokens)

            Text("In / Out")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Telemetry Item

    private func telemetryItem(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)

            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(theme.text)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3), value: value)

            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Cover View

    @ViewBuilder
    private var coverView: some View {
        if let coverURL = book.coverURL,
           let image = NSImage(contentsOf: coverURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            theme.overlay
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 32, weight: .light))
                            .foregroundColor(theme.muted)

                        Text(book.title)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.subtle)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 12)
                    }
                }
        }
    }

    // MARK: - Helpers

    private var estimatedTimeRemaining: String {
        guard let startTime = startTime,
              status.completedChapters > 0 else {
            return "--:--"
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let avgPerChapter = elapsed / Double(status.completedChapters)
        let remaining = Double(totalChapters - status.completedChapters) * avgPerChapter

        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else if seconds > 0 {
            return "\(seconds)s"
        } else {
            return "< 1s"
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
