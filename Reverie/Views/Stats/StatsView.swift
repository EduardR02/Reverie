import SwiftUI

struct StatsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var animateStats = false
    @State private var dbStats: DatabaseService.DBStats?

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
                    }
                    .padding(32)
                }
            }
        }
        .onAppear {
            appState.refreshReadingStats()
            withAnimation(.easeOut(duration: 0.8).delay(0.1)) {
                animateStats = true
            }
        }
        .task {
            appState.refreshReadingStats()
            dbStats = try? appState.database.fetchStats()
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
            HeroStatCard(
                icon: "clock.fill",
                value: formatTime(appState.readingStats.minutesToday),
                label: "Today's Reading",
                color: theme.iris,
                delay: 0,
                animate: animateStats
            )

            HeroStatCard(
                icon: "text.word.spacing",
                value: formatNumber(appState.readingStats.totalWords),
                label: "Words Read",
                color: theme.foam,
                delay: 0.05,
                animate: animateStats
            )

            ReadingSpeedCard(
                value: appState.readingSpeedTracker.formattedAverageWPM,
                label: "Avg. Speed",
                color: theme.rose,
                delay: 0.1,
                animate: animateStats,
                onReset: {
                    appState.resetReadingSpeed()
                }
            )

            HeroStatCard(
                icon: "books.vertical.fill",
                value: "\(appState.readingStats.totalBooks)",
                label: "Books Finished",
                color: theme.gold,
                delay: 0.15,
                animate: animateStats
            )
        }
    }

    // MARK: - Activity Graph Section

    private var activityGraphSection: some View {
        VStack(alignment: .leading, spacing: 32) {
            // Header with Streaks integrated
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(theme.rose)

                        Text("READING ACTIVITY")
                            .font(.system(size: 11, weight: .bold))
                            .kerning(1.2)
                            .foregroundColor(theme.muted)
                    }

                    Text("Past 52 weeks")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.text.opacity(0.8))
                }

                Spacer()

                HStack(spacing: 48) {
                    integratedStreak(label: "CURRENT STREAK", value: appState.readingStats.currentStreak, color: theme.love)
                    integratedStreak(label: "BEST RECORD", value: appState.readingStats.maxStreak, color: theme.gold)
                }
            }

            // Expanded Activity Graph
            ActivityGraph(
                stats: appState.readingStats,
                baseColor: theme.foam,
                emptyColor: theme.overlay
            )
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(32)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(theme.overlay, lineWidth: 1)
        }
    }

    private func integratedStreak(label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .kerning(0.8)
                .foregroundColor(theme.muted)
            
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: color == theme.love ? "flame.fill" : "trophy.fill")
                    .font(.system(size: 14))
                    .foregroundColor(color)
                
                Text("\(value)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(theme.text)
                Text("DAYS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.muted)
            }
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

                if stats.tokensCached > 0 {
                    TokenBar(
                        label: "  └ Cached",
                        value: stats.tokensCached,
                        total: max(total, 1),
                        color: theme.gold,
                        animate: animateStats
                    )
                }

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
                    value: "\(appState.readingStats.insightsSeen)",
                    label: "Insights",
                    color: theme.gold
                )

                MiniStatBadge(
                    icon: "bubble.left.fill",
                    value: "\(appState.readingStats.followupsAsked)",
                    label: "Followups",
                    color: theme.foam
                )

                MiniStatBadge(
                    icon: "photo.fill",
                    value: "\(appState.readingStats.imagesGenerated)",
                    label: "Images",
                    color: theme.rose
                )
            }
        }
        .padding(24)
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

            let accuracy = Double(dbStats?.quizzesCorrect ?? 0) / Double(max(dbStats?.quizzesAnswered ?? 0, 1))

            Spacer(minLength: 0)
            HStack {
                Spacer()
                AccuracyRing(
                    accuracy: accuracy,
                    animate: animateStats
                )
                .scaleEffect(1.2)
                Spacer()
            }
            Spacer(minLength: 0)

            Divider()
                .background(theme.overlay)

            // Quiz breakdown
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(dbStats?.quizzesGenerated ?? 0)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(theme.iris)
                    Text("Generated")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(dbStats?.quizzesAnswered ?? 0)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(theme.text)
                    Text("Answered")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(dbStats?.quizzesCorrect ?? 0)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(theme.foam)
                    Text("Correct")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    let missed = (dbStats?.quizzesAnswered ?? 0) - (dbStats?.quizzesCorrect ?? 0)
                    Text("\(max(0, missed))")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(theme.love)
                    Text("Missed")
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Reading Speed Card

struct ReadingSpeedCard: View {
    let value: String
    let label: String
    let color: Color
    let delay: Double
    let animate: Bool
    let onReset: () -> Void

    @Environment(\.theme) private var theme
    @State private var showConfirm = false
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 12) {
                // Icon (Identical to HeroStatCard)
                Image(systemName: "speedometer")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(color)
                    .frame(width: 48, height: 48)
                    .background(color.opacity(0.15))
                    .clipShape(Circle())

                // Value
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(theme.text)
                    
                    if value != "—" {
                        Text("WPM")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.muted)
                    }
                }
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

            // Minimalist Zero-Shift Reset
            if isHovered {
                Button {
                    if showConfirm {
                        onReset()
                        withAnimation { showConfirm = false }
                    } else {
                        withAnimation(.spring(response: 0.2)) {
                            showConfirm = true
                        }
                    }
                } label: {
                    ZStack {
                        if showConfirm {
                            Text("SURE?")
                                .font(.system(size: 8, weight: .black))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(theme.love)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(theme.muted)
                                .frame(width: 36, height: 36)
                                .background(theme.overlay)
                                .clipShape(Circle())
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(8)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.overlay, lineWidth: 1)
        }
        .onHover { h in
            withAnimation(.spring(response: 0.3)) {
                isHovered = h
                if !h { showConfirm = false }
            }
        }
    }
}

// MARK: - Activity Graph

struct ActivityGraph: View {
    let stats: ReadingStats
    let baseColor: Color
    let emptyColor: Color

    @Environment(\.theme) private var theme

    private let weeks = 52
    private let daysPerWeek = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Weekday labels
            HStack(spacing: 4) {
                VStack(alignment: .trailing, spacing: 2) {
                    let dayLabels = ["", "Mon", "", "Wed", "", "Fri", ""]
                    ForEach(Array(dayLabels.enumerated()), id: \.offset) { _, day in
                        Text(day)
                            .font(.system(size: 8))
                            .foregroundColor(theme.muted)
                            .frame(height: 14)
                    }
                }
                .frame(width: 24)

                // Grid of days
                HStack(spacing: 4) {
                    ForEach(0..<weeks, id: \.self) { week in
                        VStack(spacing: 4) {
                            ForEach(0..<daysPerWeek, id: \.self) { day in
                                let date = dateFor(week: week, day: day)
                                let minutes = stats.minutesFor(date: date)
                                let intensity = intensityLevel(minutes: minutes)

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(colorForIntensity(intensity))
                                    .frame(width: 14, height: 14)
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
                        .frame(width: 14, height: 14)
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
