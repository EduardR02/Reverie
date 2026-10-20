import Foundation
import CryptoKit

protocol LLMProviderClient: Sendable {
    var conversationScope: String? { get }
    var structuredOutputTool: Bool { get }
    func makeRequest(prompt: LLMRequestPrompt, model: String, apiKey: String, temperature: Double, reasoning: ReasoningLevel, schema: LLMStructuredSchema?, stream: Bool, webSearch: Bool) throws -> URLRequest
    func parseResponseText(from data: Data) throws -> (String, LLMService.TokenUsage?)
    func usage(fromResponse json: [String: Any]) -> LLMService.TokenUsage?
    func handleStreamEvent(_ json: [String: Any], emit: (LLMStreamChunk) -> Void) throws
    func usage(fromStreamEvent json: [String: Any]) -> LLMService.TokenUsage?
    func observedUsage(fromStreamEvent json: [String: Any]) -> LLMService.TokenUsage?
}

extension LLMProviderClient {
    var conversationScope: String? { nil }
    var structuredOutputTool: Bool { false }

    func observedUsage(fromStreamEvent json: [String: Any]) -> LLMService.TokenUsage? {
        usage(fromStreamEvent: json)
    }
}

/// Provider-native output is opaque conversation state, never a displayed reasoning summary.
struct LLMConversationState: Codable, Equatable, Sendable {
    let provider: LLMProvider
    let model: String
    let payload: Data
    let scope: String?

    init(provider: LLMProvider, model: String, payload: Data, scope: String? = nil) {
        self.provider = provider
        self.model = model
        self.payload = payload
        self.scope = scope
    }

    func items(for provider: LLMProvider, model: String) throws -> [[String: Any]]? {
        guard self.provider == provider,
              SupportedModels.canonicalLLMModelID(self.model) == SupportedModels.canonicalLLMModelID(model) else { return nil }
        guard let items = try JSONSerialization.jsonObject(with: payload) as? [[String: Any]] else {
            throw LLMService.LLMError.invalidResponse
        }
        return items
    }
}

private func responseJSON(_ data: Data) throws -> [String: Any] {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw LLMService.LLMError.invalidResponse
    }
    try rejectProviderError(json)
    return json
}

private func rejectProviderError(_ json: [String: Any]) throws {
    if let error = json["error"] as? [String: Any] {
        throw LLMService.LLMError.apiError(error["message"] as? String ?? "The provider could not complete the request.")
    }
    if json["type"] as? String == "error" {
        throw LLMService.LLMError.apiError(json["message"] as? String ?? "The provider could not complete the request.")
    }
}

private func validateFeatures(model: String, schema: LLMStructuredSchema?, webSearch: Bool) throws {
    let capabilities = SupportedModels.capabilities(for: model)
    if webSearch && capabilities?.supportsWebSearch != true {
        throw LLMService.LLMError.apiError("Web search is not supported by the selected model.")
    }
    if schema != nil && capabilities?.supportsStructuredOutput == false {
        throw LLMService.LLMError.apiError("Structured output is not supported by the selected model.")
    }
}

struct OpenAIProvider: LLMProviderClient {
    let subscriptionCredential: OpenAISubscriptionCredential?
    let sessionID: String?
    let conversationScope: String?

    init(subscriptionCredential: OpenAISubscriptionCredential? = nil, sessionID: String? = nil, apiKey: String? = nil) {
        self.subscriptionCredential = subscriptionCredential
        self.sessionID = sessionID
        if let subscriptionCredential {
            conversationScope = "chatgpt:\(subscriptionCredential.accountID)"
        } else {
            conversationScope = apiKey.map { key in
                "api:" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            }
        }
    }

    func makeRequest(prompt: LLMRequestPrompt, model: String, apiKey: String, temperature: Double, reasoning: ReasoningLevel, schema: LLMStructuredSchema?, stream: Bool, webSearch: Bool) throws -> URLRequest {
        let model = SupportedModels.canonicalLLMModelID(model)
        try validateFeatures(model: model, schema: schema, webSearch: webSearch)
        let capabilities = SupportedModels.capabilities(for: model)
        var input: [[String: Any]] = []
        let explicitCache = subscriptionCredential == nil && capabilities?.supportsExplicitPromptCaching == true
            && prompt.conversation.isEmpty && prompt.cachePrefix?.isEmpty == false
        if prompt.conversation.isEmpty {
            var content: [[String: Any]]
            if explicitCache, let prefix = prompt.cachePrefix {
                content = [["type": "input_text", "text": prefix, "prompt_cache_breakpoint": ["mode": "explicit"]]]
                if let suffix = prompt.cacheSuffix, !suffix.isEmpty { content.append(["type": "input_text", "text": suffix]) }
            } else {
                content = [["type": "input_text", "text": prompt.text]]
            }
            input.append(["role": "user", "content": content])
        } else {
            for turn in prompt.conversation {
                if turn.role == .assistant, let scope = conversationScope,
                   turn.providerState?.scope == scope,
                   let native = try turn.providerState?.items(for: .openai, model: model) {
                    input.append(contentsOf: native)
                } else {
                    input.append(["role": turn.role.rawValue, "content": turn.content])
                }
            }
        }
        var body: [String: Any] = [
            "model": model, "input": input, "stream": stream, "store": false,
            "max_output_tokens": capabilities?.maxOutputTokens ?? 16384,
            "include": ["reasoning.encrypted_content"]
        ]
        if explicitCache { body["prompt_cache_options"] = ["mode": "explicit"] }
        if !prompt.conversation.isEmpty { body["instructions"] = prompt.text }
        if webSearch { body["tools"] = [["type": "web_search"]] }
        if let schema {
            body["text"] = ["format": ["type": "json_schema", "name": schema.name, "schema": schema.schema, "strict": true]]
        }
        if capabilities?.reasoning == .openAI {
            body["reasoning"] = ["effort": reasoning.openAIEffort(for: model), "summary": "auto"]
        }
        if capabilities?.supportsTemperature == true,
           capabilities?.reasoning != .openAI || reasoning.openAIEffort(for: model) == "none" {
            body["temperature"] = temperature
        }
        let endpoint: String
        if subscriptionCredential != nil {
            endpoint = "https://chatgpt.com/backend-api/codex/responses"
            body["stream"] = true
            body["max_output_tokens"] = nil
            body["temperature"] = nil
            body["instructions"] = body["instructions"] ?? "You are Reverie's reading assistant. Follow the reader's task without spoilers."
            if let sessionID { body["prompt_cache_key"] = sessionID }
        } else {
            endpoint = "https://api.openai.com/v1/responses"
        }
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let credential = subscriptionCredential {
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue(credential.residency, forHTTPHeaderField: "x-openai-internal-codex-residency")
            request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Reverie", forHTTPHeaderField: "originator")
            request.setValue("Reverie", forHTTPHeaderField: "User-Agent")
            request.setValue(sessionID, forHTTPHeaderField: "session-id")
            request.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Commentary is progress, not part of the final answer or structured JSON.
    static func isFinalMessage(_ item: [String: Any]) -> Bool {
        guard item["type"] as? String == "message" else { return false }
        guard (item["role"] as? String ?? "assistant") == "assistant" else { return false }
        let phase = item["phase"] as? String ?? item["channel"] as? String
        return phase == nil || phase == "final_answer" || phase == "final"
    }

    static func responseText(_ json: [String: Any]) -> String {
        (json["output"] as? [[String: Any]] ?? []).filter(isFinalMessage)
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
            .joined()
    }

    static func validateResponse(_ json: [String: Any]) throws {
        try rejectProviderError(json)
        guard let status = json["status"] as? String else { throw LLMService.LLMError.invalidResponse }
        if status != "completed" {
            let details = json["incomplete_details"] as? [String: Any]
            throw LLMService.LLMError.apiError("OpenAI response \(status): \(details?["reason"] as? String ?? "generation did not complete").")
        }
        if json["end_turn"] as? Bool == false {
            throw LLMService.LLMError.apiError("OpenAI ended the response before completing the assistant turn.")
        }
        for item in json["output"] as? [[String: Any]] ?? [] {
            if item["type"] as? String == "message",
               let status = item["status"] as? String, status != "completed" {
                throw LLMService.LLMError.apiError("OpenAI returned an unfinished message.")
            }
            if item["type"] as? String == "function_call" {
                throw LLMService.LLMError.apiError("The model requested an unavailable client tool.")
            }
            if item["type"] as? String == "web_search_call",
               let status = item["status"] as? String, status != "completed" {
                throw LLMService.LLMError.apiError("OpenAI web search did not complete: \(status).")
            }
            for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "refusal" {
                throw LLMService.LLMError.apiError(part["refusal"] as? String ?? "OpenAI refused to answer.")
            }
        }
    }

    func parseResponseText(from data: Data) throws -> (String, LLMService.TokenUsage?) {
        let json = try responseJSON(data)
        try Self.validateResponse(json)
        let text = Self.responseText(json)
        guard !text.isEmpty else { throw LLMService.LLMError.invalidResponse }
        return (text, tokenUsage(json["usage"] as? [String: Any]))
    }

    func handleStreamEvent(_ json: [String: Any], emit: (LLMStreamChunk) -> Void) throws {
        try rejectProviderError(json)
        switch json["type"] as? String {
        case "response.output_text.delta":
            if let text = json["delta"] as? String { emit(.content(text)) }
        case "response.reasoning_summary_text.delta":
            if let text = json["delta"] as? String { emit(.thinking(text)) }
        case "response.refusal.delta", "response.refusal.done":
            // Drain through the terminal snapshot so refused requests retain billed usage.
            // validateResponse rejects its refusal blocks before a successful completion.
            break
        case "response.completed", "response.done", "response.failed", "response.incomplete":
            // Native item snapshots and sparse Codex completion metadata are reconciled
            // by the same accumulator used by the consumer before publishing success.
            var accumulator = LLMStreamAccumulator(provider: .openai)
            try accumulator.consume(json)
        default: break
        }
    }

    func usage(fromStreamEvent json: [String: Any]) -> LLMService.TokenUsage? {
        guard ["response.completed", "response.done"].contains(json["type"] as? String ?? "") else { return nil }
        return observedUsage(fromStreamEvent: json)
    }

    func observedUsage(fromStreamEvent json: [String: Any]) -> LLMService.TokenUsage? {
        guard let response = json["response"] as? [String: Any] else { return nil }
        return usage(fromResponse: response)
    }

    func usage(fromResponse json: [String: Any]) -> LLMService.TokenUsage? {
        tokenUsage(json["usage"] as? [String: Any])
    }

    private func tokenUsage(_ data: [String: Any]?) -> LLMService.TokenUsage? {
        guard let data else { return nil }
        let reasoning = (data["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0
        let details = data["input_tokens_details"] as? [String: Any]
        return LLMService.TokenUsage(
            input: data["input_tokens"] as? Int ?? 0,
            visibleOutput: max(0, (data["output_tokens"] as? Int ?? 0) - reasoning),
            cached: details?["cached_tokens"] as? Int,
            cacheWrite: details?["cache_write_tokens"] as? Int,
            reasoning: reasoning
        )
    }
}

struct GeminiProvider: LLMProviderClient {
    func makeRequest(prompt: LLMRequestPrompt, model: String, apiKey: String, temperature: Double, reasoning: ReasoningLevel, schema: LLMStructuredSchema?, stream: Bool, webSearch: Bool) throws -> URLRequest {
        let model = SupportedModels.canonicalLLMModelID(model)
        try validateFeatures(model: model, schema: schema, webSearch: webSearch)
        let capabilities = SupportedModels.capabilities(for: model)
        var generation: [String: Any] = ["maxOutputTokens": capabilities?.maxOutputTokens ?? 8192]
        if capabilities?.supportsTemperature == true { generation["temperature"] = temperature }
        if let schema {
            generation["responseFormat"] = ["text": ["mimeType": "APPLICATION_JSON", "schema": schema.schema]]
        }
        if capabilities?.reasoning == .geminiLevel {
            generation["thinkingConfig"] = ["thinkingLevel": reasoning.geminiLevel(for: model), "includeThoughts": true]
        } else if capabilities?.reasoning == .geminiBudget {
            generation["thinkingConfig"] = ["thinkingBudget": reasoning == .off && capabilities?.thinkingAlwaysOn != true ? 0 : -1, "includeThoughts": true]
        }
        var contents: [[String: Any]] = []
        for turn in prompt.conversation {
            let parts = turn.role == .assistant ? try turn.providerState?.items(for: .google, model: model) : nil
            contents.append(["role": turn.role == .assistant ? "model" : "user", "parts": parts ?? [["text": turn.content]]])
        }
        if contents.isEmpty { contents = [["role": "user", "parts": [["text": prompt.text]]]] }
        var body: [String: Any] = ["contents": contents, "generationConfig": generation]
        if !prompt.conversation.isEmpty { body["systemInstruction"] = ["parts": [["text": prompt.text]]] }
        if webSearch { body["tools"] = [["google_search": [:]]] }
        let endpoint = stream ? "streamGenerateContent?alt=sse" : "generateContent"
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):\(endpoint)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func validateResponse(_ json: [String: Any]) throws {
        try rejectProviderError(json)
        if let feedback = json["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            throw LLMService.LLMError.apiError("Gemini blocked the prompt: \(reason).")
        }
        if let candidate = (json["candidates"] as? [[String: Any]])?.first {
            if let reason = candidate["finishReason"] as? String, reason != "STOP" {
                throw LLMService.LLMError.apiError("Gemini generation did not complete: \(reason).")
            }
            let content = candidate["content"] as? [String: Any]
            if (content?["parts"] as? [[String: Any]] ?? []).contains(where: { $0["functionCall"] != nil }) {
                throw LLMService.LLMError.apiError("The model requested an unavailable client tool.")
            }
        }
    }

    func parseResponseText(from data: Data) throws -> (String, LLMService.TokenUsage?) {
        let json = try responseJSON(data)
        try Self.validateResponse(json)
        guard (json["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String == "STOP" else {
            throw LLMService.LLMError.invalidResponse
        }
        let content = (json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]
        let text = (content?["parts"] as? [[String: Any]] ?? []).compactMap { part -> String? in
            part["thought"] as? Bool == true ? nil : part["text"] as? String
        }.joined()
        guard !text.isEmpty else { throw LLMService.LLMError.invalidResponse }
        return (text, observedUsage(fromStreamEvent: json))
    }

    func handleStreamEvent(_ json: [String: Any], emit: (LLMStreamChunk) -> Void) throws {
        try Self.validateResponse(json)
        let content = (json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]
        for part in content?["parts"] as? [[String: Any]] ?? [] {
            if let text = part["text"] as? String { emit(part["thought"] as? Bool == true ? .thinking(text) : .content(text)) }
        }
    }

    func usage(fromStreamEvent json: [String: Any]) -> LLMService.TokenUsage? {
        guard (json["candidates"] as? [[String: Any]])?.first?["finishReason"] != nil else { return nil }
        return observedUsage(fromStreamEvent: json)
    }

    func observedUsage(fromStreamEvent json: [String: Any]) -> LLMService.TokenUsage? {
        usage(fromResponse: json)
    }

    func usage(fromResponse json: [String: Any]) -> LLMService.TokenUsage? {
        guard let usage = json["usageMetadata"] as? [String: Any] else { return nil }
        // Tool-use prompts are additional input, not part of promptTokenCount.
        return LLMService.TokenUsage(input: (usage["promptTokenCount"] as? Int ?? 0) + (usage["toolUsePromptTokenCount"] as? Int ?? 0), visibleOutput: usage["candidatesTokenCount"] as? Int ?? 0, cached: usage["cachedContentTokenCount"] as? Int, reasoning: usage["thoughtsTokenCount"] as? Int)
    }
}

struct AnthropicProvider: LLMProviderClient {
    static let structuredOutputToolName = "submit_analysis"
    let structuredOutputTool: Bool

    init(structuredOutputTool: Bool = false) {
        self.structuredOutputTool = structuredOutputTool
    }

    func makeRequest(prompt: LLMRequestPrompt, model: String, apiKey: String, temperature: Double, reasoning: ReasoningLevel, schema: LLMStructuredSchema?, stream: Bool, webSearch: Bool) throws -> URLRequest {
        let model = SupportedModels.canonicalLLMModelID(model)
        try validateFeatures(model: model, schema: schema, webSearch: webSearch)
        guard schema == nil || !webSearch || structuredOutputTool else {
            throw LLMService.LLMError.apiError("Claude search citations require a strict final-submission tool for structured output.")
        }
        guard !structuredOutputTool || (schema != nil && webSearch) else { throw LLMService.LLMError.invalidResponse }
        let capabilities = SupportedModels.capabilities(for: model)
        let maxTokens = capabilities?.maxOutputTokens ?? 8192
        var messages: [[String: Any]] = []
        for turn in prompt.conversation {
            if turn.role == .assistant, let native = try turn.providerState?.items(for: .anthropic, model: model) {
                messages.append(contentsOf: native)
            } else {
                messages.append(["role": turn.role.rawValue, "content": [["type": "text", "text": turn.content]]])
            }
        }
        if messages.isEmpty { messages = [["role": "user", "content": contentBlocks(for: prompt)]] }
        var body: [String: Any] = ["model": model, "max_tokens": maxTokens, "messages": messages, "stream": stream]
        if !prompt.conversation.isEmpty {
            body["system"] = [["type": "text", "text": prompt.text, "cache_control": ["type": "ephemeral"]]]
        }
        if webSearch { body["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 2]] }
        if structuredOutputTool, let schema {
            var tools = body["tools"] as? [[String: Any]] ?? []
            tools.append([
                "name": Self.structuredOutputToolName,
                "description": "Submit the completed analysis in the requested schema after any useful research. This ends the response and does not request an external action.",
                "input_schema": schema.schema,
                "strict": true
            ])
            body["tools"] = tools
            body["tool_choice"] = ["type": "auto"]
        }
        var output: [String: Any] = [:]
        let shouldThink = reasoning != .off || capabilities?.thinkingAlwaysOn == true
        if shouldThink && capabilities?.reasoning == .anthropicAdaptive {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
            output["effort"] = reasoning.anthropicEffort(for: model)
        } else if shouldThink && capabilities?.reasoning == .anthropicBudget {
            let budget: Int
            switch reasoning {
            case .off, .minimal: budget = 1024
            case .low: budget = 2048
            case .medium: budget = 8192
            case .high: budget = 16384
            case .xhigh, .max: budget = 32768
            }
            body["thinking"] = ["type": "enabled", "budget_tokens": min(budget, maxTokens - 1)]
        } else if capabilities?.reasoning == .anthropicAdaptive {
            body["thinking"] = ["type": "disabled"]
        }
        if !shouldThink && capabilities?.supportsTemperature == true { body["temperature"] = temperature }
        if let schema, !structuredOutputTool { output["format"] = ["type": "json_schema", "schema": schema.schema] }
        if !output.isEmpty { body["output_config"] = output }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func validateResponse(_ json: [String: Any], allowPause: Bool = false, structuredOutputTool: Bool = false) throws {
        try rejectProviderError(json)
        if let reason = json["stop_reason"] as? String,
           reason != "end_turn", reason != "stop_sequence", !(allowPause && reason == "pause_turn"),
           !(structuredOutputTool && reason == "tool_use") {
            throw LLMService.LLMError.apiError("Claude generation did not complete: \(reason).")
        }
        for block in json["content"] as? [[String: Any]] ?? [] {
            if block["type"] as? String == "tool_use",
               !structuredOutputTool || block["name"] as? String != Self.structuredOutputToolName {
                throw LLMService.LLMError.apiError("The model requested an unavailable client tool.")
            }
            if block["type"] as? String == "web_search_tool_result",
               let error = block["content"] as? [String: Any], error["type"] as? String == "web_search_tool_result_error" {
                throw LLMService.LLMError.apiError("Claude web search failed: \(error["error_code"] as? String ?? "unknown error").")
            }
        }
        if structuredOutputTool, json["stop_reason"] as? String == "tool_use", json["content"] != nil {
            _ = try submissionInput(in: json)
        }
    }

    static func submissionInput(in json: [String: Any]) throws -> [String: Any] {
        let calls = (json["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "tool_use" }
        guard calls.count == 1, calls[0]["name"] as? String == structuredOutputToolName,
              let input = calls[0]["input"] as? [String: Any] else { throw LLMService.LLMError.invalidResponse }
        return input
    }

    func parseResponseText(from data: Data) throws -> (String, LLMService.TokenUsage?) {
        let json = try responseJSON(data)
        try Self.validateResponse(json, structuredOutputTool: structuredOutputTool)
        if structuredOutputTool {
            guard json["stop_reason"] as? String == "tool_use" else { throw LLMService.LLMError.invalidResponse }
            let input = try Self.submissionInput(in: json)
            return (String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self), usage(fromResponse: json))
        }
        guard let reason = json["stop_reason"] as? String, ["end_turn", "stop_sequence"].contains(reason) else {
            throw LLMService.LLMError.invalidResponse
        }
        let text = (json["content"] as? [[String: Any]] ?? []).compactMap { part -> String? in
            part["type"] as? String == "text" ? part["text"] as? String : nil
        }.joined()
        guard !text.isEmpty else { throw LLMService.LLMError.invalidResponse }
        return (text, (json["usage"] as? [String: Any]).map(tokenUsage))
    }

    func handleStreamEvent(_ json: [String: Any], emit: (LLMStreamChunk) -> Void) throws {
        try rejectProviderError(json)
        if json["type"] as? String == "message_delta", let delta = json["delta"] as? [String: Any] {
            try Self.validateResponse(delta, allowPause: true, structuredOutputTool: structuredOutputTool)
        }
        if json["type"] as? String == "content_block_delta", let delta = json["delta"] as? [String: Any] {
            if let text = delta["text"] as? String { emit(.content(text)) }
            if let thinking = delta["thinking"] as? String { emit(.thinking(thinking)) }
        }
    }

    func usage(fromStreamEvent json: [String: Any]) -> LLMService.TokenUsage? {
        if json["type"] as? String == "message_start", let message = json["message"] as? [String: Any], let data = message["usage"] as? [String: Any] {
            return tokenUsage(data)
        }
        if json["type"] as? String == "message_delta", let data = json["usage"] as? [String: Any] { return tokenUsage(data) }
        return nil
    }

    func usage(fromResponse json: [String: Any]) -> LLMService.TokenUsage? {
        (json["usage"] as? [String: Any]).map(tokenUsage)
    }

    private func tokenUsage(_ data: [String: Any]) -> LLMService.TokenUsage {
        let cached = data["cache_read_input_tokens"] as? Int
        let write = data["cache_creation_input_tokens"] as? Int
        let thinking = (data["output_tokens_details"] as? [String: Any])?["thinking_tokens"] as? Int
        // Older responses omit the reasoning breakdown; keep their reported output intact.
        return LLMService.TokenUsage(input: (data["input_tokens"] as? Int ?? 0) + (cached ?? 0) + (write ?? 0), visibleOutput: max(0, (data["output_tokens"] as? Int ?? 0) - (thinking ?? 0)), cached: cached, cacheWrite: write, reasoning: thinking)
    }

    private func contentBlocks(for prompt: LLMRequestPrompt) -> [[String: Any]] {
        guard let prefix = prompt.cachePrefix, !prefix.isEmpty else { return [["type": "text", "text": prompt.text]] }
        var blocks: [[String: Any]] = [["type": "text", "text": prefix, "cache_control": ["type": "ephemeral"]]]
        if let suffix = prompt.cacheSuffix, !suffix.isEmpty { blocks.append(["type": "text", "text": suffix]) }
        return blocks
    }
}
