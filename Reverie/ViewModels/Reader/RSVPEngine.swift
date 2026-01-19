import Foundation
import Observation
import Combine

/// Core engine for RSVP (Rapid Serial Visual Presentation) reading mode.
/// Displays one word at a time with precise timing and ORP alignment.
@Observable @MainActor
final class RSVPEngine {
    
    // MARK: - State
    
    var isPlaying: Bool = false
    var currentWordIndex: Int = 0
    var words: [RSVPWord] = []
    var pendingPauseContent: PauseContent? = nil
    var wpm: Double = 300.0
    
    private var timer: Task<Void, Never>?
    private var pausePoints: [Int: PauseContent] = [:]
    
    // MARK: - Computed Properties
    
    var progress: Double {
        guard !words.isEmpty else { return 0.0 }
        return Double(currentWordIndex) / Double(words.count - 1)
    }
    
    var currentWord: RSVPWord? {
        guard words.indices.contains(currentWordIndex) else { return nil }
        return words[currentWordIndex]
    }
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Public Methods
    
    /// Loads a chapter's content and prepares it for RSVP display.
    /// - Parameters:
    ///   - blocks: The content blocks of the chapter.
    ///   - annotations: Insights associated with the chapter.
    ///   - images: Generated images associated with the chapter.
    ///   - footnotes: Footnotes associated with the chapter.
    func loadChapter(
        blocks: [ContentBlock],
        annotations: [Annotation],
        images: [GeneratedImage],
        footnotes: [Footnote]
    ) {
        pause()
        
        var allWords: [RSVPWord] = []
        var points: [Int: PauseContent] = [:]
        
        for block in blocks {
            let blockWords = block.text.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            
            // Map the first word of each block to its pause points if any
            let startWordIndex = allWords.count
            
            // For RSVP, we pause at the START of a block that has an insight/image/footnote
            // This ensures the reader sees the content related to the text they are about to read.
            // Alternatively, we could pause at the END of the block.
            // Given the requirements, we'll map sourceBlockId to the first word of that block.
            
            if let annotation = annotations.first(where: { $0.sourceBlockId == block.id }) {
                points[startWordIndex] = .insight(annotation)
            } else if let image = images.first(where: { $0.sourceBlockId == block.id }) {
                points[startWordIndex] = .image(image)
            } else if let footnote = footnotes.first(where: { $0.sourceBlockId == block.id }) {
                points[startWordIndex] = .footnote(footnote)
            }
            
            for wordText in blockWords {
                let rsvpWord = RSVPWord(
                    id: allWords.count,
                    text: wordText,
                    orpIndex: calculateORP(for: wordText),
                    sourceBlockId: block.id
                )
                allWords.append(rsvpWord)
            }
        }
        
        self.words = allWords
        self.pausePoints = points
        self.currentWordIndex = 0
        self.pendingPauseContent = nil
    }
    
    func play() {
        guard !isPlaying, !words.isEmpty else { return }
        
        // If we are at a pause point and just showing the content, 
        // clear it when resuming
        if pendingPauseContent != nil {
            pendingPauseContent = nil
        }
        
        isPlaying = true
        scheduleNextWord()
    }
    
    func pause() {
        isPlaying = false
        timer?.cancel()
        timer = nil
    }
    
    func toggle() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func skip(words count: Int) {
        let newIndex = currentWordIndex + count
        currentWordIndex = max(0, min(words.count - 1, newIndex))
        
        // When skipping, if we hit a pause point exactly, we might want to show it,
        // but usually manual skip should just move the cursor.
        // For now, we clear any pending content.
        pendingPauseContent = nil
    }
    
    func reset() {
        pause()
        currentWordIndex = 0
        pendingPauseContent = nil
    }
    
    func setWPM(_ wpm: Double) {
        self.wpm = max(50.0, wpm)
        if isPlaying {
            // Restart timer with new speed
            pause()
            play()
        }
    }
    
    // MARK: - Private Methods
    
    private func scheduleNextWord() {
        guard isPlaying, currentWord != nil else { return }
        
        // Constant timing per word: interval = 60.0 / wpm
        let interval = 60.0 / wpm
        
        timer?.cancel()
        timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if !Task.isCancelled {
                advance()
            }
        }
    }
    
    private func advance() {
        let nextIndex = currentWordIndex + 1
        
        guard nextIndex < words.count else {
            pause()
            return
        }
        
        // Check for pause points at the upcoming index
        if let content = pausePoints[nextIndex] {
            pause()
            currentWordIndex = nextIndex
            pendingPauseContent = content
            return
        }
        
        currentWordIndex = nextIndex
        scheduleNextWord()
    }
    
    /// Spritz ORP Algorithm:
    /// 0-1 chars: 0
    /// 2-5 chars: 1
    /// 6-9 chars: 2
    /// 10-13 chars: 3
    /// 14+ chars: 4
    private func calculateORP(for word: String) -> Int {
        let length = word.count
        switch length {
        case 0...1: return 0
        case 2...5: return 1
        case 6...9: return 2
        case 10...13: return 3
        default: return 4
        }
    }
}

// MARK: - Supporting Types

struct RSVPWord: Identifiable, Equatable {
    let id: Int
    let text: String
    let orpIndex: Int
    let sourceBlockId: Int
    
    var beforeORP: String {
        let start = text.startIndex
        let end = text.index(start, offsetBy: min(orpIndex, text.count), limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }
    
    var orpChar: Character {
        let index = text.index(text.startIndex, offsetBy: min(orpIndex, text.count), limitedBy: text.endIndex) ?? text.endIndex
        if index < text.endIndex {
            return text[index]
        }
        return " "
    }
    
    var afterORP: String {
        let index = text.index(text.startIndex, offsetBy: min(orpIndex + 1, text.count), limitedBy: text.endIndex) ?? text.endIndex
        return String(text[index...])
    }
}

enum PauseContent: Equatable {
    case insight(Annotation)
    case image(GeneratedImage)
    case footnote(Footnote)

    static func == (lhs: PauseContent, rhs: PauseContent) -> Bool {
        switch (lhs, rhs) {
        case (.insight(let a), .insight(let b)): return a.id == b.id
        case (.image(let a), .image(let b)): return a.id == b.id
        case (.footnote(let a), .footnote(let b)): return a.id == b.id
        default: return false
        }
    }
}
