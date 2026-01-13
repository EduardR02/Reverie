import Foundation

/// Tracks reading speed and manages auto-scroll
@Observable
final class ReadingSpeedTracker {
    // MARK: - Reading Session Data

    struct ReadingSession: Codable {
        var startTime: Date
        var chapterId: Int64
        var chapterWordCount: Int
        var startPercent: Double
        var maxPercent: Double
        var timeSpentSeconds: Double
        var pauses: [PauseEvent]
        var adjustments: [SpeedAdjustment]

        var wordsRead: Int {
            guard chapterWordCount > 0 else { return 0 }
            let clampedStart = min(max(startPercent, 0), 1)
            let clampedMax = min(max(maxPercent, clampedStart), 1)
            let delta = clampedMax - clampedStart
            return Int((Double(chapterWordCount) * delta).rounded())
        }

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
    private(set) var manualAutoScrollWPM: Double = 250
    private(set) var confidence: Double = 0  // 0-1, how confident we are in the reading speed
    private(set) var activePauseReasons: Set<PauseReason> = []
    var isPaused: Bool { !activePauseReasons.isEmpty }
    private(set) var isLocked: Bool = false  // User locked their reading speed

    static let idleThresholdSeconds: TimeInterval = 300

    private var pauseStartTime: Date?
    private var lastActivityTime: Date?
    private var lastTickTime: Date?

    // MARK: - Settings Keys

    private let wpmHistoryKey = "readingSpeedHistory"
    private let averageWPMKey = "averageReadingWPM"
    private let manualAutoScrollWPMKey = "manualAutoScrollWPM"
    private let confidenceKey = "readingSpeedConfidence"
    private let isLockedKey = "readingSpeedLocked"

    // MARK: - Initialization

    init() {
        loadSavedData()
    }

    // MARK: - Session Management

    func startSession(
        chapterId: Int64,
        wordCount: Int,
        startPercent: Double = 0,
        now: Date = Date()
    ) {
        let clampedStart = min(max(startPercent, 0), 1)
        currentSession = ReadingSession(
            startTime: now,
            chapterId: chapterId,
            chapterWordCount: max(0, wordCount),
            startPercent: clampedStart,
            maxPercent: clampedStart,
            timeSpentSeconds: 0,
            pauses: [],
            adjustments: []
        )
        lastActivityTime = now
        lastTickTime = now
    }

    func updateSession(scrollPercent: Double, now: Date = Date()) {
        guard var session = currentSession else { return }

        lastActivityTime = now
        let clamped = min(max(scrollPercent, 0), 1)
        session.maxPercent = max(session.maxPercent, clamped)
        currentSession = session
        _ = tick(now: now)
    }

    struct SessionResult {
        let wpm: Double
        let minutes: Int
        let seconds: Double
        let words: Int
    }

    func endSession(now: Date = Date()) -> SessionResult? {
        _ = tick(now: now)
        guard let session = currentSession else { return nil }

        let wpm = session.wpm
        let totalSeconds = session.timeSpentSeconds
        let minutes = Int(totalSeconds / 60.0)
        let words = session.wordsRead

        if !isLocked && wpm > 50 && wpm < 1500 {  // Sanity check
            historicalWPM.append(wpm)
            // Keep last 20 readings
            if historicalWPM.count > 20 {
                historicalWPM.removeFirst()
            }
            recalculateAverage()
            saveData()
        }

        currentSession = nil
        lastActivityTime = nil
        lastTickTime = nil
        return SessionResult(wpm: wpm, minutes: max(0, minutes), seconds: max(0, totalSeconds), words: max(0, words))
    }

    @discardableResult
    func tick(now: Date = Date()) -> Double {
        guard var session = currentSession else { return 0 }
        guard let lastTick = lastTickTime else {
            lastTickTime = now
            return 0
        }

        let delta = now.timeIntervalSince(lastTick)
        lastTickTime = now
        guard delta > 0 else { return 0 }
        guard let lastActivity = lastActivityTime,
              now.timeIntervalSince(lastActivity) <= Self.idleThresholdSeconds else {
            currentSession = session
            return 0
        }

        session.timeSpentSeconds += delta
        currentSession = session
        return delta
    }

    // MARK: - Pause Management

    func startPause(reason: PauseReason) {
        let wasEmpty = activePauseReasons.isEmpty
        activePauseReasons.insert(reason)
        if wasEmpty {
            pauseStartTime = Date()
        }
    }

    func endPause(reason: PauseReason) {
        activePauseReasons.remove(reason)
        
        // Only record pause duration when ALL reasons cleared
        guard activePauseReasons.isEmpty, let startTime = pauseStartTime else { return }
        
        let duration = Date().timeIntervalSince(startTime)
        if var session = currentSession {
            session.pauses.append(PauseEvent(
                startTime: startTime,
                duration: duration,
                reason: reason  // Use the final reason that ended the pause
            ))
            currentSession = session
        }
        pauseStartTime = nil
    }

    func endAllPauses() {
        guard !activePauseReasons.isEmpty, let startTime = pauseStartTime else { return }
        
        let duration = Date().timeIntervalSince(startTime)
        if var session = currentSession {
            session.pauses.append(PauseEvent(
                startTime: startTime,
                duration: duration,
                reason: .manual
            ))
            currentSession = session
        }
        activePauseReasons.removeAll()
        pauseStartTime = nil
    }

    // MARK: - Adjustments

    func applyAdjustment(_ type: AdjustmentType) {
        guard var session = currentSession else { return }
        session.adjustments.append(SpeedAdjustment(type: type, factor: type.factor))
        currentSession = session

        // Apply adjustment to average
        if !isLocked {
            averageWPM *= type.factor
            saveData()
        }
    }

    func updateSessionWordCount(_ wordCount: Int) {
        guard var session = currentSession else { return }
        session.chapterWordCount = max(0, wordCount)
        currentSession = session
    }

    @discardableResult
    func discardSession() -> SessionResult? {
        guard let session = currentSession else { return nil }
        let result = SessionResult(
            wpm: session.wpm,
            minutes: Int(session.timeSpentSeconds / 60.0),
            seconds: session.timeSpentSeconds,
            words: session.wordsRead
        )
        currentSession = nil
        lastActivityTime = nil
        lastTickTime = nil
        return result
    }

    // MARK: - Auto-Scroll

    var effectiveAutoScrollWPM: Double {
        manualAutoScrollWPM
    }

    func incrementManualSpeed() {
        manualAutoScrollWPM += 10
        saveData()
    }

    func decrementManualSpeed() {
        manualAutoScrollWPM = max(50, manualAutoScrollWPM - 10)
        saveData()
    }

    func toggleLock() {
        isLocked.toggle()
        UserDefaults.standard.set(isLocked, forKey: isLockedKey)
    }

    /// Returns the delay in seconds before next scroll
    func calculateScrollDelay(wordsInView: Int) -> Double {
        let wpm = effectiveAutoScrollWPM
        guard wpm > 0 else { return 30 }  // Default 30 seconds

        let minutesToRead = Double(wordsInView) / wpm
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

    func reset() {
        historicalWPM.removeAll()
        averageWPM = 0
        confidence = 0
        saveData()
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
        
        manualAutoScrollWPM = UserDefaults.standard.double(forKey: manualAutoScrollWPMKey)
        if manualAutoScrollWPM == 0 {
            manualAutoScrollWPM = averageWPM > 0 ? averageWPM : 250
        }
    }

    private func saveData() {
        if let data = try? JSONEncoder().encode(historicalWPM) {
            UserDefaults.standard.set(data, forKey: wpmHistoryKey)
        }
        UserDefaults.standard.set(averageWPM, forKey: averageWPMKey)
        UserDefaults.standard.set(manualAutoScrollWPM, forKey: manualAutoScrollWPMKey)
        UserDefaults.standard.set(confidence, forKey: confidenceKey)
    }
}
