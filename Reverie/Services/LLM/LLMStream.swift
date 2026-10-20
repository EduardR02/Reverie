import Foundation

enum LLMStreamChunk {
    case content(String)
    case thinking(String)
    case usage(LLMService.TokenUsage)

    var text: String {
        switch self {
        case .content(let text), .thinking(let text): return text
        case .usage: return ""
        }
    }

    var isThinking: Bool {
        if case .thinking = self { return true }
        return false
    }
}

struct SSELineParser {
    var buffer = Data()
    private var previousWasCR = false

    mutating func append(byte: UInt8, onLine: (String) throws -> Void) throws {
        if byte == 0x0A && previousWasCR {
            previousWasCR = false
            return
        }
        previousWasCR = byte == 0x0D
        if byte == 0x0A || byte == 0x0D {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            try onLine(line)
        } else {
            buffer.append(byte)
        }
    }

    mutating func finalize(onLine: (String) throws -> Void) throws {
        guard !buffer.isEmpty else { return }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        try onLine(line)
    }
}

func ssePayload(from line: String) -> String? {
    guard line.hasPrefix("data:") else { return nil }
    var payload = line.dropFirst(5)
    if payload.first == " " { payload = payload.dropFirst() }
    return String(payload)
}

/// SSE dispatches an event at a blank line, joining data fields with newlines.
struct SSEEventParser {
    private var dataLines: [String] = []

    mutating func append(line: String, onEvent: (String) throws -> Void) throws {
        if line.isEmpty {
            try finalize(onEvent: onEvent)
        } else if let payload = ssePayload(from: line) {
            dataLines.append(payload)
        }
    }

    mutating func finalize(onEvent: (String) throws -> Void) throws {
        guard !dataLines.isEmpty else { return }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        try onEvent(payload)
    }
}

/// Accumulates native blocks independently from the human-readable delta stream.
/// EOF is never a successful completion signal.
struct LLMStreamAccumulator {
    let provider: LLMProvider
    let structuredOutputTool: Bool
    private(set) var response: [String: Any] = [:]
    private(set) var isComplete = false
    private var blocks: [Int: [String: Any]] = [:]
    private var partialToolJSON: [Int: String] = [:]
    private var geminiParts: [[String: Any]] = []
    private var openBlocks: Set<Int> = []
    private var openAIItemIndices: [String: Int] = [:]
    private var reasoningSummaries: [String: String] = [:]
    private var hasReasoningSummary = false

    init(provider: LLMProvider, structuredOutputTool: Bool = false) {
        self.provider = provider
        self.structuredOutputTool = structuredOutputTool
    }

    var needsContinuation: Bool {
        provider == .anthropic && response["stop_reason"] as? String == "pause_turn"
    }

    var visibleText: String {
        switch provider {
        case .openai:
            return OpenAIProvider.responseText(response)
        case .anthropic:
            if structuredOutputTool {
                guard let input = try? AnthropicProvider.submissionInput(in: response),
                      let data = try? JSONSerialization.data(withJSONObject: input) else { return "" }
                return String(decoding: data, as: UTF8.self)
            }
            return (response["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        case .google:
            return geminiParts.compactMap { $0["thought"] as? Bool == true ? nil : $0["text"] as? String }.joined()
        }
    }

    private mutating func openAIIndex(for json: [String: Any], item: [String: Any]) -> Int {
        let id = item["id"] as? String ?? json["item_id"] as? String
        let index = json["output_index"] as? Int
            ?? id.flatMap { openAIItemIndices[$0] }
            ?? ((blocks.keys.max() ?? -1) + 1)
        if let id { openAIItemIndices[id] = index }
        return index
    }

    func includesOpenAITextDelta(_ json: [String: Any]) -> Bool {
        let index = json["output_index"] as? Int
            ?? (json["item_id"] as? String).flatMap { openAIItemIndices[$0] }
        guard let index, let item = blocks[index] else { return true }
        return OpenAIProvider.isFinalMessage(item)
    }

    /// Summary snapshots supplement missing deltas; they never expose native encrypted reasoning.
    mutating func openAIReasoningUpdates(_ json: [String: Any]) -> [String] {
        var updates: [String] = []
        func append(_ text: String, itemID: String, index: Int, delta: Bool) {
            guard !text.isEmpty else { return }
            let key = "\(itemID):\(index)"
            let previous = reasoningSummaries[key] ?? ""
            let next = delta ? previous + text : text
            guard next.utf8.starts(with: previous.utf8) else { return }
            let suffix = String(decoding: next.utf8.dropFirst(previous.utf8.count), as: UTF8.self)
            guard !suffix.isEmpty else { return }
            if previous.isEmpty && hasReasoningSummary { updates.append("\n\n") }
            reasoningSummaries[key] = next
            hasReasoningSummary = true
            updates.append(suffix)
        }
        func appendItem(_ item: [String: Any], fallback: String) {
            guard item["type"] as? String == "reasoning" else { return }
            for (index, part) in (item["summary"] as? [[String: Any]] ?? []).enumerated() {
                if let text = part["text"] as? String {
                    append(text, itemID: item["id"] as? String ?? fallback, index: index, delta: false)
                }
            }
        }
        let itemID = json["item_id"] as? String
            ?? (json["output_index"] as? Int).flatMap { blocks[$0]?["id"] as? String }
            ?? "reasoning"
        switch json["type"] as? String {
        case "response.reasoning_summary_text.delta":
            if let text = json["delta"] as? String {
                append(text, itemID: itemID, index: json["summary_index"] as? Int ?? 0, delta: true)
            }
        case "response.reasoning_summary_text.done":
            if let text = json["text"] as? String {
                append(text, itemID: itemID, index: json["summary_index"] as? Int ?? 0, delta: false)
            }
        case "response.reasoning_summary_part.done":
            if let part = json["part"] as? [String: Any], let text = part["text"] as? String {
                append(text, itemID: itemID, index: json["summary_index"] as? Int ?? 0, delta: false)
            }
        case "response.output_item.done":
            if let item = json["item"] as? [String: Any] { appendItem(item, fallback: itemID) }
        case "response.completed", "response.done":
            for (index, item) in (response["output"] as? [[String: Any]] ?? []).enumerated() {
                appendItem(item, fallback: "reasoning-\(index)")
            }
        default: break
        }
        return updates
    }

    /// A non-SSE response has the same lifecycle and native history as a streamed one.
    mutating func consumeResponse(_ json: [String: Any]) throws {
        response = json
        switch provider {
        case .openai:
            try OpenAIProvider.validateResponse(json)
        case .anthropic:
            try AnthropicProvider.validateResponse(json, allowPause: true, structuredOutputTool: structuredOutputTool)
            guard let reason = json["stop_reason"] as? String,
                  ["end_turn", "stop_sequence", "pause_turn"].contains(reason) || (structuredOutputTool && reason == "tool_use") else { throw LLMService.LLMError.invalidResponse }
        case .google:
            try GeminiProvider.validateResponse(json)
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first,
                  candidate["finishReason"] as? String == "STOP" else { throw LLMService.LLMError.invalidResponse }
            geminiParts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        }
        isComplete = true
    }

    mutating func consume(_ json: [String: Any]) throws {
        switch provider {
        case .openai:
            let type = json["type"] as? String ?? ""
            switch type {
            case "response.output_item.added", "response.output_item.done":
                guard let item = json["item"] as? [String: Any] else { throw LLMService.LLMError.invalidResponse }
                let index = openAIIndex(for: json, item: item)
                blocks[index] = item
                if type == "response.output_item.added" { openBlocks.insert(index) }
                else { openBlocks.remove(index) }
            case "response.completed", "response.done", "response.failed", "response.incomplete":
                guard var value = json["response"] as? [String: Any] else { throw LLMService.LLMError.invalidResponse }
                // Codex sends output_item.done snapshots followed by completion metadata,
                // not necessarily a full Responses object. Only completed implies success.
                if type == "response.completed", value["status"] == nil { value["status"] = "completed" }
                let output = value["output"] as? [[String: Any]]
                if output == nil || output?.isEmpty == true {
                    guard openBlocks.isEmpty else { throw LLMService.LLMError.invalidResponse }
                    value["output"] = blocks.keys.sorted().compactMap { blocks[$0] }
                }
                // Store failed snapshots before validation so billed usage is not lost.
                response = value
                guard type == "response.completed" || type == "response.done" else {
                    throw LLMService.LLMError.apiError("OpenAI generation did not complete.")
                }
                try consumeResponse(value)
            default: break
            }
        case .anthropic:
            let index = json["index"] as? Int ?? 0
            switch json["type"] as? String {
            case "message_start":
                guard let message = json["message"] as? [String: Any] else { throw LLMService.LLMError.invalidResponse }
                response = message
            case "content_block_start":
                guard let block = json["content_block"] as? [String: Any] else { throw LLMService.LLMError.invalidResponse }
                blocks[index] = block
                openBlocks.insert(index)
            case "content_block_delta":
                guard var block = blocks[index], let delta = json["delta"] as? [String: Any] else { throw LLMService.LLMError.invalidResponse }
                switch delta["type"] as? String {
                case "text_delta": block["text"] = (block["text"] as? String ?? "") + (delta["text"] as? String ?? "")
                case "thinking_delta": block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta": block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
                case "input_json_delta": partialToolJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                case "citations_delta":
                    if let citation = delta["citation"] as? [String: Any] {
                        var citations = block["citations"] as? [[String: Any]] ?? []
                        citations.append(citation)
                        block["citations"] = citations
                    }
                default: break
                }
                blocks[index] = block
            case "content_block_stop":
                if let input = partialToolJSON.removeValue(forKey: index) {
                    guard let data = input.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMService.LLMError.invalidResponse }
                    blocks[index]?["input"] = object
                }
                openBlocks.remove(index)
            case "message_delta":
                for (key, value) in json["delta"] as? [String: Any] ?? [:] { response[key] = value }
                var usage = response["usage"] as? [String: Any] ?? [:]
                for (key, value) in json["usage"] as? [String: Any] ?? [:] { usage[key] = value }
                response["usage"] = usage
            case "message_stop":
                guard openBlocks.isEmpty, response["stop_reason"] as? String != nil else { throw LLMService.LLMError.invalidResponse }
                response["content"] = blocks.keys.sorted().compactMap { blocks[$0] }
                try AnthropicProvider.validateResponse(response, allowPause: true, structuredOutputTool: structuredOutputTool)
                isComplete = true
            default: break
            }
        case .google:
            try GeminiProvider.validateResponse(json)
            if let usage = json["usageMetadata"] { response["usageMetadata"] = usage }
            guard let candidate = (json["candidates"] as? [[String: Any]])?.first else { return }
            let content = candidate["content"] as? [String: Any]
            // Keep signature-bearing parts intact, including signature-only final chunks.
            geminiParts.append(contentsOf: content?["parts"] as? [[String: Any]] ?? [])
            var accumulated = candidate
            accumulated["content"] = ["role": "model", "parts": geminiParts]
            response["candidates"] = [accumulated]
            if candidate["finishReason"] as? String == "STOP" { isComplete = true }
        }
    }

    func finish() throws {
        guard isComplete else {
            throw LLMService.LLMError.apiError("The provider stream ended before generation completed. Please try again.")
        }
    }

    func conversationState(model: String, scope: String? = nil) throws -> LLMConversationState {
        try finish()
        let items: [[String: Any]]
        switch provider {
        case .openai: items = response["output"] as? [[String: Any]] ?? []
        case .anthropic: items = [["role": "assistant", "content": response["content"] as? [[String: Any]] ?? []]]
        case .google: items = geminiParts
        }
        return LLMConversationState(provider: provider, model: model, payload: try JSONSerialization.data(withJSONObject: items), scope: scope)
    }
}
