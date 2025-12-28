import Foundation

struct LLMStreamChunk {
    let text: String
    let isThinking: Bool

    static func content(_ text: String) -> LLMStreamChunk {
        LLMStreamChunk(text: text, isThinking: false)
    }

    static func thinking(_ text: String) -> LLMStreamChunk {
        LLMStreamChunk(text: text, isThinking: true)
    }
}

struct SSELineParser {
    var buffer = Data()

    mutating func append(byte: UInt8, onLine: (String) throws -> Void) throws {
        buffer.append(byte)
        try drain(onLine: onLine)
    }

    mutating func finalize(onLine: (String) throws -> Void) throws {
        guard !buffer.isEmpty else { return }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        try onLine(line)
    }

    private mutating func drain(onLine: (String) throws -> Void) throws {
        while let lineEnd = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[..<lineEnd]
            var removeEnd = buffer.index(after: lineEnd)
            if buffer[lineEnd] == 0x0D, removeEnd < buffer.endIndex, buffer[removeEnd] == 0x0A {
                removeEnd = buffer.index(after: removeEnd)
            }
            buffer.removeSubrange(..<removeEnd)
            let line = String(decoding: lineData, as: UTF8.self)
            try onLine(line)
        }
    }
}

func ssePayload(from line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("data:") else { return nil }

    var payload = trimmed.dropFirst(5)
    if payload.first == " " {
        payload = payload.dropFirst()
    }
    return String(payload)
}
