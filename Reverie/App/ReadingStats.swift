import Foundation

struct ReadingStats: Codable {
    var secondsToday: Double = 0
    var currentStreak: Int = 0
    var maxStreak: Int = 0
    var totalSeconds: Double = 0
    var totalBooks: Int = 0
    var lastReadDate: Date?

    var minutesToday: Int { Int(secondsToday / 60.0) }
    var totalMinutes: Int { Int(totalSeconds / 60.0) }

    // Lifetime Journey Stats (Permanent)
    var totalWords: Int = 0
    var insightsSeen: Int = 0
    var followupsAsked: Int = 0
    var imagesGenerated: Int = 0

    // Token usage breakdown
    var tokensInput: Int = 0
    var tokensReasoning: Int = 0
    var tokensOutput: Int = 0

    var totalTokens: Int {
        tokensInput + tokensReasoning + tokensOutput
    }

    // Daily reading log (for GitHub-style graph) - stores date string -> total seconds
    var dailyLog: [String: Double] = [:]

    mutating func resetCheck() {
        let calendar = Calendar.current
        if let lastDate = lastReadDate, !calendar.isDate(lastDate, inSameDayAs: Date()) {
            secondsToday = 0
            
            // Streak check (if yesterday was missed, streak reset)
            let today = calendar.startOfDay(for: Date())
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            if !calendar.isDate(lastDate, inSameDayAs: yesterday) {
                currentStreak = 0
            }
        }
    }

    mutating func addReadingTime(_ seconds: Double) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Reset today's seconds if it's a new day
        if let lastDate = lastReadDate, !calendar.isDate(lastDate, inSameDayAs: Date()) {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            if calendar.isDate(lastDate, inSameDayAs: yesterday) {
                currentStreak += 1
            } else {
                currentStreak = 1
            }
            secondsToday = 0
        } else if lastReadDate == nil {
            currentStreak = 1
        }
        
        maxStreak = max(maxStreak, currentStreak)

        secondsToday += seconds
        totalSeconds += seconds
        lastReadDate = Date()

        let dateKey = Self.dateKey(for: Date())
        dailyLog[dateKey, default: 0] += seconds
    }

    mutating func addTokens(input: Int, reasoning: Int, output: Int) {
        tokensInput += input
        tokensReasoning += reasoning
        tokensOutput += output
    }

    mutating func recordInsightSeen() {
        insightsSeen += 1
    }

    mutating func recordFollowup() {
        followupsAsked += 1
    }

    mutating func recordImage() {
        imagesGenerated += 1
    }

    mutating func addWords(_ count: Int) {
        totalWords += count
    }

    mutating func recordBookFinished(finished: Bool) {
        if finished {
            totalBooks += 1
        } else {
            totalBooks = max(0, totalBooks - 1)
        }
    }

    static func dateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func minutesFor(date: Date) -> Int {
        let key = Self.dateKey(for: date)
        return Int((dailyLog[key] ?? 0) / 60.0)
    }
}