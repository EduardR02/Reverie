import Foundation

/// Tracks reading speed and manages auto-scroll
@Observable
final class ReadingSpeedTracker {
    // MARK: - Reading Session Data

    struct ReadingSession: Codable {
        var startTime: Date
        var chapterId: Int64
        var wordsRead: Int
        var timeSpentSeconds: Double
        var pauses: [PauseEvent]
        var adjustments: [SpeedAdjustment]

        var wpm: Double {
            let effectiveTime = timeSpentSeconds - pauses.reduce(0) { $0 + $1.duration }
            guard effectiveTime > 0 else { return 0 }
            return Double(wordsRead) / (effectiveTime / 60.0)
        }
    }

    struct PauseEvent: Codable {
        var startTime: Date
        var duration: Double  // seconds
        var reason: PauseReason
    }

    enum PauseReason: String, Codable {
        case chatting
        case viewingInsights
        case viewingImage
        case manual
    }

    struct SpeedAdjustment: Codable {
        var type: AdjustmentType
        var factor: Double  // Multiplier to apply
    }

    enum AdjustmentType: String, Codable, CaseIterable {
        case readingSlowly = "I was reading a bit slow"
        case skippedInsights = "I skipped the insights"
        case readInsights = "I read all insights"
        case wasDistracted = "I was distracted"

        var factor: Double {
            switch self {
            case .readingSlowly: return 0.85      // Reduce expected speed by 15%
            case .skippedInsights: return 1.15   // Increase expected speed by 15%
            case .readInsights: return 0.9       // Account for extra reading time
            case .wasDistracted: return 0.7      // Significant reduction
            }
        }
    }

    // MARK: - State

    private(set) var currentSession: ReadingSession?
    private(set) var historicalWPM: [Double] = []
    private(set) var averageWPM: Double = 0
    private(set) var confidence: Double = 0  // 0-1, how confident we are in the reading speed
    private(set) var isAutoScrollEnabled: Bool = false
    private(set) var isPaused: Bool = false
    private(set) var isLocked: Bool = false  // User locked their reading speed

    private var pauseStartTime: Date?
    private var lastScrollTime: Date?

    // MARK: - Settings Keys

    private let wpmHistoryKey = "readingSpeedHistory"
    private let averageWPMKey = "averageReadingWPM"
    private let confidenceKey = "readingSpeedConfidence"
    private let isLockedKey = "readingSpeedLocked"

    // MARK: - Initialization

    init() {
        loadSavedData()
    }

    // MARK: - Session Management

    func startSession(chapterId: Int64, wordCount: Int) {
        currentSession = ReadingSession(
            startTime: Date(),
            chapterId: chapterId,
            wordsRead: wordCount,
            timeSpentSeconds: 0,
            pauses: [],
            adjustments: []
        )
        lastScrollTime = Date()
    }

    func updateSession(scrollPercent: Double) {
        guard var session = currentSession else { return }

        let now = Date()
        if let lastScroll = lastScrollTime {
            let delta = now.timeIntervalSince(lastScroll)
            // Only count time if under 2 minutes (user might have left)
            if delta < 120 {
                session.timeSpentSeconds += delta
            }
        }
        lastScrollTime = now
        currentSession = session
    }

    struct SessionResult {
        let wpm: Double
        let minutes: Int
        let seconds: Double
        let words: Int
    }

    func endSession() -> SessionResult? {
        guard var session = currentSession else { return nil }

        // Final time update
        if let lastScroll = lastScrollTime {
            let delta = Date().timeIntervalSince(lastScroll)
            if delta < 120 {
                session.timeSpentSeconds += delta
            }
        }

        let wpm = session.wpm
        let totalSeconds = session.timeSpentSeconds
        let minutes = Int(totalSeconds / 60.0)
        let words = session.wordsRead

        if wpm > 50 && wpm < 1000 {  // Sanity check
            historicalWPM.append(wpm)
            // Keep last 20 readings
            if historicalWPM.count > 20 {
                historicalWPM.removeFirst()
            }
            recalculateAverage()
            saveData()
        }

        currentSession = nil
        return SessionResult(wpm: wpm, minutes: max(0, minutes), seconds: max(0, totalSeconds), words: max(0, words))
    }

    // MARK: - Pause Management

    func startPause(reason: PauseReason) {
        guard !isPaused else { return }
        isPaused = true
        pauseStartTime = Date()
    }

    func endPause() {
        guard isPaused, let startTime = pauseStartTime else { return }
        isPaused = false

        let duration = Date().timeIntervalSince(startTime)
        if var session = currentSession {
            session.pauses.append(PauseEvent(
                startTime: startTime,
                duration: duration,
                reason: .manual
            ))
            currentSession = session
        }
        pauseStartTime = nil
    }

    // MARK: - Adjustments

    func applyAdjustment(_ type: AdjustmentType) {
        guard var session = currentSession else { return }
        session.adjustments.append(SpeedAdjustment(type: type, factor: type.factor))
        currentSession = session

        // Apply adjustment to average
        averageWPM *= type.factor
        saveData()
    }

    // MARK: - Auto-Scroll

    func toggleAutoScroll() {
        isAutoScrollEnabled.toggle()
    }

    func toggleLock() {
        isLocked.toggle()
        UserDefaults.standard.set(isLocked, forKey: isLockedKey)
    }

    /// Returns the delay in seconds before next scroll
    func calculateScrollDelay(wordsInView: Int) -> Double {
        guard averageWPM > 0 else { return 30 }  // Default 30 seconds

        let minutesToRead = Double(wordsInView) / averageWPM
        let secondsToRead = minutesToRead * 60

        // Account for uncertainty - scroll slightly early
        let uncertaintyFactor = 1.0 - (confidence * 0.2)  // At 100% confidence, scroll at 80% of calculated time
        return secondsToRead * uncertaintyFactor
    }

    /// Returns estimated minutes until auto-scroll is enabled
    var minutesUntilAutoScroll: Int? {
        guard confidence < 0.8 else { return nil }  // Already confident enough

        let sessionsNeeded = max(1, Int((0.8 - confidence) * 10))
        let avgSessionMinutes = 5  // Rough estimate
        return sessionsNeeded * avgSessionMinutes
    }

    // MARK: - Stats

    var formattedAverageWPM: String {
        guard averageWPM > 0 else { return "—" }
        return "\(Int(averageWPM))"
    }

    var confidencePercentage: Int {
        Int(confidence * 100)
    }

    // MARK: - Private Helpers

    private func recalculateAverage() {
        guard !historicalWPM.isEmpty else {
            averageWPM = 0
            confidence = 0
            return
        }

        // Weighted average (recent readings count more)
        var weightedSum = 0.0
        var totalWeight = 0.0
        for (index, wpm) in historicalWPM.enumerated() {
            let weight = Double(index + 1)  // Later readings have higher weight
            weightedSum += wpm * weight
            totalWeight += weight
        }

        averageWPM = weightedSum / totalWeight

        // Confidence based on number of readings and consistency
        let count = Double(historicalWPM.count)
        let countConfidence = min(count / 10.0, 1.0)  // Max confidence at 10 readings

        // Calculate variance
        let variance = historicalWPM.reduce(0.0) { sum, wpm in
            sum + pow(wpm - averageWPM, 2)
        } / count

        let stdDev = sqrt(variance)
        let consistencyConfidence = max(0, 1.0 - (stdDev / averageWPM))  // Lower variance = higher confidence

        confidence = (countConfidence + consistencyConfidence) / 2.0
    }

    private func loadSavedData() {
        if let data = UserDefaults.standard.data(forKey: wpmHistoryKey),
           let history = try? JSONDecoder().decode([Double].self, from: data) {
            historicalWPM = history
        }
        averageWPM = UserDefaults.standard.double(forKey: averageWPMKey)
        confidence = UserDefaults.standard.double(forKey: confidenceKey)
        isLocked = UserDefaults.standard.bool(forKey: isLockedKey)
    }

    private func saveData() {
        if let data = try? JSONEncoder().encode(historicalWPM) {
            UserDefaults.standard.set(data, forKey: wpmHistoryKey)
        }
        UserDefaults.standard.set(averageWPM, forKey: averageWPMKey)
        UserDefaults.standard.set(confidence, forKey: confidenceKey)
    }
}
