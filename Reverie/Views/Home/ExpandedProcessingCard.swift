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
        HStack(spacing: 20) {
            // Large cover on the left
            coverView
                .frame(width: 160, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

            // Content on the right
            VStack(alignment: .leading, spacing: 12) {
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
                VStack(spacing: 16) {
                    HStack(spacing: 0) {
                        telemetryItem(
                            icon: "doc.text.fill",
                            value: "\(summariesCompleted)/\(totalChapters)",
                            label: "Chapters",
                            color: theme.gold
                        )

                        telemetryItem(
                            icon: "lightbulb.fill",
                            value: "\(liveInsightCount)",
                            label: "Insights",
                            color: theme.rose
                        )

                        telemetryItem(
                            icon: "questionmark.circle.fill",
                            value: "\(liveQuizCount)",
                            label: "Questions",
                            color: theme.foam
                        )
                    }

                    HStack(spacing: 0) {
                        telemetryItem(
                            icon: "dollarsign.circle.fill",
                            value: String(format: "$%.2f", processingCost),
                            label: "Cost",
                            color: theme.rose
                        )

                        tokenTelemetryItem()

                        telemetryItem(
                            icon: "clock.fill",
                            value: estimatedTimeRemaining,
                            label: "Remaining",
                            color: theme.iris
                        )
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 700)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            Button {
                onCancel()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                    Text("Cancel")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.subtle)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.overlay.opacity(0.3))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(12)
        }
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
            // Summary Slot
            HStack(spacing: 4) {
                Text("Summary:")
                    .foregroundColor(theme.gold)
                    .fontWeight(.semibold)
                Text(summaryPhase.isEmpty ? "Pending..." : summaryPhase)
                    .foregroundColor(theme.subtle)
                    .opacity(summaryPhase.isEmpty ? 0.4 : 1.0)
            }
            .font(.system(size: 11))
            .lineLimit(1)

            // Insight Slot
            HStack(spacing: 4) {
                Text("Insights:")
                    .foregroundColor(theme.rose)
                    .fontWeight(.semibold)
                Text(insightPhase.isEmpty ? "Pending..." : insightPhase)
                    .foregroundColor(theme.subtle)
                    .opacity(insightPhase.isEmpty ? 0.4 : 1.0)
            }
            .font(.system(size: 11))
            .lineLimit(1)
        }
        .frame(height: 32, alignment: .leading)
    }

    // MARK: - Telemetry Item

    private func telemetryItem(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
                .frame(height: 12, alignment: .center)

            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 28, alignment: .center) // Fixed height for 2 lines equivalent
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3), value: value)

            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(theme.muted)
                .tracking(0.5)
                .frame(height: 10, alignment: .center)
        }
        .frame(maxWidth: .infinity)
    }

    private func tokenTelemetryItem() -> some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.pine)
                .frame(height: 12, alignment: .center)

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("IN")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.muted)
                        .frame(width: 28, alignment: .trailing)
                    Text(formatTokens(liveInputTokens))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text("OUT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.muted)
                        .frame(width: 28, alignment: .trailing)
                    Text(formatTokens(liveOutputTokens))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.text)
                        .lineLimit(1)
                }
            }
            .frame(height: 28, alignment: .center)

            Text("TOKENS")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(theme.muted)
                .tracking(0.5)
                .frame(height: 10, alignment: .center)
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
