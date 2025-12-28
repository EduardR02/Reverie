import SwiftUI

struct StatsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var animateStats = false

    var body: some View {
        ZStack {
            // Background with subtle texture
            theme.base.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                statsHeader

                // Scrollable content
                ScrollView {
                    VStack(spacing: 32) {
                        // Hero stats row
                        heroStatsSection

                        // Reading activity graph (GitHub style)
                        activityGraphSection

                        // Two-column layout for secondary stats
                        HStack(alignment: .top, spacing: 24) {
                            // Left: Token usage
                            tokenUsageSection

                            // Right: Quiz performance
                            quizSection
                        }

                        // Reading milestones
                        milestonesSection
                    }
                    .padding(32)
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.1)) {
                animateStats = true
            }
        }
    }

    // MARK: - Header

    private var statsHeader: some View {
        HStack {
            Button {
                appState.goHome()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Library")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.subtle)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(theme.iris)

                Text("Reading Stats")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.text)
            }

            Spacer()

            // Placeholder for symmetry
            Color.clear.frame(width: 80)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(height: 52)
        .background(theme.surface)
    }

    // MARK: - Hero Stats Section

    private var heroStatsSection: some View {
        HStack(spacing: 20) {
            // Total reading time
            HeroStatCard(
                icon: "clock.fill",
                value: formatTime(appState.readingStats.totalMinutes),
                label: "Total Reading",
                color: theme.iris,
                delay: 0,
                animate: animateStats
            )

            // Words read
            HeroStatCard(
                icon: "text.word.spacing",
                value: formatNumber(appState.readingStats.totalWords),
                label: "Words Read",
                color: theme.foam,
                delay: 0.1,
                animate: animateStats
            )

            // Current streak
            HeroStatCard(
                icon: "flame.fill",
                value: "\(appState.readingStats.currentStreak)",
                label: "Day Streak",
                color: theme.love,
                delay: 0.2,
                animate: animateStats
            )

            // Books finished
            HeroStatCard(
                icon: "books.vertical.fill",
                value: "\(appState.readingStats.totalBooks)",
                label: "Books Finished",
                color: theme.gold,
                delay: 0.3,
                animate: animateStats
            )
        }
    }

    // MARK: - Activity Graph Section

    private var activityGraphSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.rose)

                Text("Reading Activity")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.text)

                Spacer()

                Text("Last 16 weeks")
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
            }

            // GitHub-style contribution graph
            ActivityGraph(
                stats: appState.readingStats,
                baseColor: theme.foam,
                emptyColor: theme.overlay
            )
        }
        .padding(20)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.overlay, lineWidth: 1)
        }
    }

    // MARK: - Token Usage Section

    private var tokenUsageSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.iris)

                Text("AI Usage")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.text)
            }

            let total = appState.readingStats.totalTokens
            let stats = appState.readingStats

            VStack(spacing: 12) {
                TokenBar(
                    label: "Input",
                    value: stats.tokensInput,
                    total: max(total, 1),
                    color: theme.foam,
                    animate: animateStats
                )

                TokenBar(
                    label: "Reasoning",
                    value: stats.tokensReasoning,
                    total: max(total, 1),
                    color: theme.iris,
                    animate: animateStats
                )

                TokenBar(
                    label: "Output",
                    value: stats.tokensOutput,
                    total: max(total, 1),
                    color: theme.rose,
                    animate: animateStats
                )
            }

            Divider()
                .background(theme.overlay)

            HStack {
                Text("Total Tokens")
                    .font(.system(size: 13))
                    .foregroundColor(theme.muted)

                Spacer()

                Text(formatNumber(total))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.text)
            }

            // Secondary stats
            HStack(spacing: 16) {
                MiniStatBadge(
                    icon: "lightbulb.fill",
                    value: "\(stats.insightsGenerated)",
                    label: "Insights",
                    color: theme.gold
                )

                MiniStatBadge(
                    icon: "bubble.left.fill",
                    value: "\(stats.followupsAsked)",
                    label: "Followups",
                    color: theme.foam
                )

                MiniStatBadge(
                    icon: "photo.fill",
                    value: "\(stats.imagesGenerated)",
                    label: "Images",
                    color: theme.rose
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.overlay, lineWidth: 1)
        }
    }

    // MARK: - Quiz Section

    private var quizSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.foam)

                Text("Quiz Performance")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.text)
            }

            let stats = appState.readingStats

            // Large accuracy ring
            HStack {
                Spacer()
                AccuracyRing(
                    accuracy: stats.quizAccuracy,
                    answered: stats.quizzesAnswered,
                    correct: stats.quizzesCorrect,
                    animate: animateStats
                )
                Spacer()
            }

            Divider()
                .background(theme.overlay)

            // Quiz breakdown
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stats.quizzesGenerated)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(theme.iris)
                    Text("Generated")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stats.quizzesAnswered)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(theme.text)
                    Text("Answered")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stats.quizzesCorrect)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(theme.foam)
                    Text("Correct")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stats.quizzesAnswered - stats.quizzesCorrect)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(theme.love)
                    Text("Missed")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.overlay, lineWidth: 1)
        }
    }

    // MARK: - Milestones Section

    private var milestonesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.gold)

                Text("Milestones")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.text)
            }

            let stats = appState.readingStats

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                MilestoneCard(
                    icon: "clock.fill",
                    title: "First Hour",
                    achieved: stats.totalMinutes >= 60,
                    color: theme.foam
                )

                MilestoneCard(
                    icon: "flame.fill",
                    title: "Week Streak",
                    achieved: stats.currentStreak >= 7,
                    color: theme.love
                )

                MilestoneCard(
                    icon: "book.closed.fill",
                    title: "First Book",
                    achieved: stats.totalBooks >= 1,
                    color: theme.gold
                )

                MilestoneCard(
                    icon: "lightbulb.fill",
                    title: "100 Insights",
                    achieved: stats.insightsGenerated >= 100,
                    color: theme.iris
                )

                MilestoneCard(
                    icon: "text.word.spacing",
                    title: "10K Words",
                    achieved: stats.totalWords >= 10000,
                    color: theme.rose
                )

                MilestoneCard(
                    icon: "checkmark.seal.fill",
                    title: "Quiz Master",
                    achieved: stats.quizzesCorrect >= 50,
                    color: theme.foam
                )

                MilestoneCard(
                    icon: "hourglass",
                    title: "10 Hours",
                    achieved: stats.totalMinutes >= 600,
                    color: theme.gold
                )

                MilestoneCard(
                    icon: "sparkles",
                    title: "AI Explorer",
                    achieved: stats.totalTokens >= 100000,
                    color: theme.iris
                )
            }
        }
        .padding(20)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.overlay, lineWidth: 1)
        }
    }

    // MARK: - Helpers

    private func formatTime(_ minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        } else if minutes < 1440 {
            let hours = minutes / 60
            let mins = minutes % 60
            return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        } else {
            let days = minutes / 1440
            let hours = (minutes % 1440) / 60
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
    }

    private func formatNumber(_ num: Int) -> String {
        if num < 1000 {
            return "\(num)"
        } else if num < 1_000_000 {
            let k = Double(num) / 1000.0
            return String(format: "%.1fK", k)
        } else {
            let m = Double(num) / 1_000_000.0
            return String(format: "%.1fM", m)
        }
    }
}

// MARK: - Hero Stat Card

struct HeroStatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    let delay: Double
    let animate: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(color)
                .frame(width: 48, height: 48)
                .background(color.opacity(0.15))
                .clipShape(Circle())

            // Value
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(theme.text)
                .scaleEffect(animate ? 1 : 0.5)
                .opacity(animate ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(delay), value: animate)

            // Label
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.overlay, lineWidth: 1)
        }
    }
}

// MARK: - Activity Graph

struct ActivityGraph: View {
    let stats: ReadingStats
    let baseColor: Color
    let emptyColor: Color

    @Environment(\.theme) private var theme

    private let weeks = 16
    private let daysPerWeek = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Weekday labels
            HStack(spacing: 4) {
                VStack(alignment: .trailing, spacing: 2) {
                    let dayLabels = ["", "Mon", "", "Wed", "", "Fri", ""]
                    ForEach(Array(dayLabels.enumerated()), id: \.offset) { _, day in
                        Text(day)
                            .font(.system(size: 9))
                            .foregroundColor(theme.muted)
                            .frame(height: 12)
                    }
                }
                .frame(width: 28)

                // Grid of days
                HStack(spacing: 3) {
                    ForEach(0..<weeks, id: \.self) { week in
                        VStack(spacing: 3) {
                            ForEach(0..<daysPerWeek, id: \.self) { day in
                                let date = dateFor(week: week, day: day)
                                let minutes = stats.minutesFor(date: date)
                                let intensity = intensityLevel(minutes: minutes)

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(colorForIntensity(intensity))
                                    .frame(width: 12, height: 12)
                                    .help(tooltipFor(date: date, minutes: minutes))
                            }
                        }
                    }
                }
            }

            // Legend
            HStack(spacing: 4) {
                Spacer()
                Text("Less")
                    .font(.system(size: 10))
                    .foregroundColor(theme.muted)

                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorForIntensity(level))
                        .frame(width: 12, height: 12)
                }

                Text("More")
                    .font(.system(size: 10))
                    .foregroundColor(theme.muted)
            }
        }
    }

    private func dateFor(week: Int, day: Int) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayWeekday = calendar.component(.weekday, from: today)

        // Start from Sunday of current week
        let startOfWeek = calendar.date(byAdding: .day, value: -(todayWeekday - 1), to: today)!
        let weeksBack = weeks - 1 - week
        let targetWeekStart = calendar.date(byAdding: .weekOfYear, value: -weeksBack, to: startOfWeek)!

        return calendar.date(byAdding: .day, value: day, to: targetWeekStart)!
    }

    private func intensityLevel(minutes: Int) -> Int {
        if minutes == 0 { return 0 }
        if minutes < 15 { return 1 }
        if minutes < 30 { return 2 }
        if minutes < 60 { return 3 }
        return 4
    }

    private func colorForIntensity(_ level: Int) -> Color {
        switch level {
        case 0: return emptyColor
        case 1: return baseColor.opacity(0.3)
        case 2: return baseColor.opacity(0.5)
        case 3: return baseColor.opacity(0.75)
        default: return baseColor
        }
    }

    private func tooltipFor(date: Date, minutes: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dateStr = formatter.string(from: date)

        if minutes == 0 {
            return "No reading on \(dateStr)"
        } else {
            return "\(minutes) minutes on \(dateStr)"
        }
    }
}

// MARK: - Token Bar

struct TokenBar: View {
    let label: String
    let value: Int
    let total: Int
    let color: Color
    let animate: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.text)

                Spacer()

                Text(formatTokens(value))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.muted)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(theme.overlay)

                    // Progress
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: animate ? geo.size.width * CGFloat(value) / CGFloat(total) : 0)
                        .animation(.easeOut(duration: 0.8).delay(0.2), value: animate)
                }
            }
            .frame(height: 8)
        }
    }

    private func formatTokens(_ num: Int) -> String {
        if num < 1000 {
            return "\(num)"
        } else {
            return String(format: "%.1fK", Double(num) / 1000.0)
        }
    }
}

// MARK: - Mini Stat Badge

struct MiniStatBadge: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(color)

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(theme.text)

            Text(label)
                .font(.system(size: 10))
                .foregroundColor(theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(theme.overlay.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Accuracy Ring

struct AccuracyRing: View {
    let accuracy: Double
    let answered: Int
    let correct: Int
    let animate: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(theme.overlay, lineWidth: 12)
                .frame(width: 120, height: 120)

            // Progress ring
            Circle()
                .trim(from: 0, to: animate ? accuracy : 0)
                .stroke(
                    accuracy >= 0.8 ? theme.foam :
                    accuracy >= 0.5 ? theme.gold : theme.love,
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .frame(width: 120, height: 120)
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 1).delay(0.3), value: animate)

            // Center text
            VStack(spacing: 2) {
                Text("\(Int(accuracy * 100))%")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(theme.text)

                Text("accuracy")
                    .font(.system(size: 11))
                    .foregroundColor(theme.muted)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Milestone Card

struct MilestoneCard: View {
    let icon: String
    let title: String
    let achieved: Bool
    let color: Color

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(achieved ? color.opacity(0.2) : theme.overlay)
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(achieved ? color : theme.muted)
            }

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(achieved ? theme.text : theme.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(achieved ? color.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(achieved ? color.opacity(0.3) : theme.overlay, lineWidth: 1)
        }
        .opacity(achieved ? 1 : 0.5)
    }
}
