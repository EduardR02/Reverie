import Foundation

protocol LLMProviderClient {
    func makeRequest(
        prompt: LLMRequestPrompt,
        model: String,
        apiKey: String,
        temperature: Double,
        reasoning: ReasoningLevel,
        schema: LLMStructuredSchema?,
        stream: Bool
    ) throws -> URLRequest

    func parseResponseText(from data: Data) throws -> (String, LLMService.TokenUsage?)

    func handleStreamEvent(
        _ json: [String: Any],
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation
    ) throws
}

struct OpenAIProvider: LLMProviderClient {
    func makeRequest(
        prompt: LLMRequestPrompt,
        model: String,
        apiKey: String,
        temperature: Double,
        reasoning: ReasoningLevel,
        schema: LLMStructuredSchema?,
        stream: Bool
    ) throws -> URLRequest {
        let url = URL(string: "https://api.openai.com/v1/responses")!
        let isReasoner = model.contains("gpt-5") || model.contains("o1") || model.contains("o3")

        var body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "user", "content": [["type": "input_text", "text": prompt.text]]]
            ],
            "max_output_tokens": isReasoner ? 100000 : 16384,
            "stream": stream
        ]

        if let schema {
            body["text"] = [
                "format": [
                    "type": "json_schema",
                    "name": schema.name,
                    "schema": schema.schema,
                    "strict": true
                ]
            ]
        }

        if isReasoner {
            body["reasoning"] = ["effort": reasoning.openAIEffort]
        } else {
            body["temperature"] = temperature
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseResponseText(from data: Data) throws -> (String, LLMService.TokenUsage?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMService.LLMError.invalidResponse
        }

        let output = json["output"] as? [[String: Any]] ?? []
        let messageItem = output.first { ($0["type"] as? String) == "message" }
        guard let content = messageItem?["content"] as? [[String: Any]] else {
            throw LLMService.LLMError.invalidResponse
        }

        if let refusal = content.first(where: { ($0["type"] as? String) == "refusal" })?["refusal"] as? String {
            throw LLMService.LLMError.apiError(refusal)
        }

        let text = content.compactMap { part -> String? in
            guard (part["type"] as? String) == "output_text" else { return nil }
            return part["text"] as? String
        }.joined()

        if text.isEmpty {
            throw LLMService.LLMError.invalidResponse
        }

        var usage: LLMService.TokenUsage?
        if let usageData = json["usage"] as? [String: Any] {
            let inputDetails = usageData["input_tokens_details"] as? [String: Any]
            let outputDetails = usageData["output_tokens_details"] as? [String: Any]
            usage = LLMService.TokenUsage(
                input: usageData["input_tokens"] as? Int ?? 0,
                output: usageData["output_tokens"] as? Int ?? 0,
                cached: inputDetails?["cached_tokens"] as? Int,
                reasoning: outputDetails?["reasoning_tokens"] as? Int
            )
        }

        return (text, usage)
    }

    func handleStreamEvent(
        _ json: [String: Any],
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation
    ) throws {
        let type = json["type"] as? String ?? ""
        if type == "response.output_text.delta", let delta = json["delta"] as? String {
            continuation.yield(.content(delta))
        } else if type == "response.completed", let response = json["response"] as? [String: Any], let usageData = response["usage"] as? [String: Any] {
            let inputDetails = usageData["input_tokens_details"] as? [String: Any]
            let outputDetails = usageData["output_tokens_details"] as? [String: Any]
            let usage = LLMService.TokenUsage(
                input: usageData["input_tokens"] as? Int ?? 0,
                output: usageData["output_tokens"] as? Int ?? 0,
                cached: inputDetails?["cached_tokens"] as? Int,
                reasoning: outputDetails?["reasoning_tokens"] as? Int
            )
            continuation.yield(.usage(usage))
        } else if type == "error",
                  let error = json["error"] as? [String: Any],
                  let message = error["message"] as? String {
            throw LLMService.LLMError.apiError(message)
        }
    }
}

struct GeminiProvider: LLMProviderClient {
    func makeRequest(
        prompt: LLMRequestPrompt,
        model: String,
        apiKey: String,
        temperature: Double,
        reasoning: ReasoningLevel,
        schema: LLMStructuredSchema?,
        stream: Bool
    ) throws -> URLRequest {
        let isGemini3 = model.contains("gemini-3")
        let isGemini25 = model.contains("gemini-2.5") && !model.contains("image")
        let isGemini25Pro = isGemini25 && model.contains("pro")
        let canToggle = isGemini25 && model.contains("flash")
        let shouldThink = reasoning != .off
        let isThinking = isGemini3 || isGemini25Pro || (canToggle && shouldThink)

        let maxTokens = isThinking ? 65536 : geminiMaxTokens(for: model)
        var generationConfig: [String: Any] = [
            "temperature": temperature,
            "maxOutputTokens": maxTokens
        ]

        if let schema {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseJsonSchema"] = schema.schema
        } else {
            generationConfig["responseMimeType"] = "text/plain"
        }

        if isGemini3 {
            let isFlash = model.contains("flash")
            generationConfig["thinking_config"] = [
                "thinkingLevel": reasoning.gemini3Level(isFlash: isFlash),
                "include_thoughts": true
            ]
        } else if isThinking {
            generationConfig["thinking_config"] = [
                "thinkingBudget": -1,
                "include_thoughts": true
            ]
        }

        let endpoint = stream ? "streamGenerateContent?alt=sse&" : "generateContent?"
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):\(endpoint)key=\(apiKey)")!

        let body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": [["text": prompt.text]]]
            ],
            "safetySettings": [
                ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"]
            ],
            "generationConfig": generationConfig
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseResponseText(from data: Data) throws -> (String, LLMService.TokenUsage?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMService.LLMError.invalidResponse
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw LLMService.LLMError.apiError(message)
        }

        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMService.LLMError.invalidResponse
        }

        let text = parts.compactMap { part -> String? in
            guard let text = part["text"] as? String else { return nil }
            if part["thought"] as? Bool == true {
                return nil
            }
            return text
        }.joined()
        if text.isEmpty {
            throw LLMService.LLMError.invalidResponse
        }

        var usage: LLMService.TokenUsage?
        if let usageData = json["usageMetadata"] as? [String: Any] {
            usage = LLMService.TokenUsage(
                input: usageData["promptTokenCount"] as? Int ?? 0,
                output: (usageData["candidatesTokenCount"] as? Int ?? 0) + (usageData["thoughtsTokenCount"] as? Int ?? 0),
                cached: nil,
                reasoning: usageData["thoughtsTokenCount"] as? Int
            )
        }

        return (text, usage)
    }

    func handleStreamEvent(
        _ json: [String: Any],
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation
    ) throws {
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw LLMService.LLMError.apiError(message)
        }

        if let usageData = json["usageMetadata"] as? [String: Any] {
            let usage = LLMService.TokenUsage(
                input: usageData["promptTokenCount"] as? Int ?? 0,
                output: (usageData["candidatesTokenCount"] as? Int ?? 0) + (usageData["thoughtsTokenCount"] as? Int ?? 0),
                cached: nil,
                reasoning: usageData["thoughtsTokenCount"] as? Int
            )
            continuation.yield(.usage(usage))
        }

        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return
        }

        for part in parts {
            if let text = part["text"] as? String {
                let isThought = part["thought"] as? Bool ?? false
                continuation.yield(isThought ? .thinking(text) : .content(text))
            }
        }
    }

    private func geminiMaxTokens(for model: String) -> Int {
        if model.contains("image") {
            return 32768
        }
        if model.contains("gemini-3") || model.contains("gemini-2.5") {
            return 65536
        }
        return 8192
    }
}

struct AnthropicProvider: LLMProviderClient {
    func makeRequest(
        prompt: LLMRequestPrompt,
        model: String,
        apiKey: String,
        temperature: Double,
        reasoning: ReasoningLevel,
        schema: LLMStructuredSchema?,
        stream: Bool
    ) throws -> URLRequest {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let canThink = model.contains("sonnet-4") || model.contains("opus-4") || model.contains("haiku-4")
        let shouldThink = canThink && reasoning != .off

        let maxTokens: Int
        if shouldThink {
            maxTokens = 64000
        } else if canThink {
            maxTokens = 32000
        } else {
            maxTokens = 8192
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": contentBlocks(for: prompt)]
            ],
            "stream": stream
        ]

        if shouldThink {
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": max(1024, maxTokens - 4000)
            ]
        } else {
            body["temperature"] = temperature
        }

        if let schema {
            body["output_format"] = [
                "type": "json_schema",
                "schema": schema.schema
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if schema != nil {
            request.setValue("structured-outputs-2025-11-13", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseResponseText(from data: Data) throws -> (String, LLMService.TokenUsage?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMService.LLMError.invalidResponse
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw LLMService.LLMError.apiError(message)
        }

        if let stopReason = json["stop_reason"] as? String, stopReason == "refusal" {
            let content = json["content"] as? [[String: Any]]
            let refusal = content?.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
            throw LLMService.LLMError.apiError(refusal ?? "Claude refused to answer.")
        }

        guard let content = json["content"] as? [[String: Any]] else {
            throw LLMService.LLMError.invalidResponse
        }

        let text = content.compactMap { part -> String? in
            guard (part["type"] as? String) == "text" else { return nil }
            return part["text"] as? String
        }.joined()

        if text.isEmpty {
            throw LLMService.LLMError.invalidResponse
        }

        var usage: LLMService.TokenUsage?
        if let usageData = json["usage"] as? [String: Any] {
            let input = usageData["input_tokens"] as? Int ?? 0
            let cacheCreation = usageData["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = usageData["cache_read_input_tokens"] as? Int ?? 0
            let output = usageData["output_tokens"] as? Int ?? 0
            
            // Note: For Anthropic, input_tokens usually includes cached tokens
            usage = LLMService.TokenUsage(
                input: input + cacheCreation + cacheRead,
                output: output,
                cached: cacheRead,
                reasoning: nil
            )
        }

        return (text, usage)
    }

    func handleStreamEvent(
        _ json: [String: Any],
        continuation: AsyncThrowingStream<LLMStreamChunk, Error>.Continuation
    ) throws {
        let type = json["type"] as? String ?? ""
        if type == "content_block_delta",
           let delta = json["delta"] as? [String: Any] {
            if let deltaType = delta["type"] as? String {
                if deltaType == "text_delta", let text = delta["text"] as? String {
                    continuation.yield(.content(text))
                } else if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String {
                    continuation.yield(.thinking(thinking))
                }
            } else if let text = delta["text"] as? String {
                continuation.yield(.content(text))
            } else if let thinking = delta["thinking"] as? String {
                continuation.yield(.thinking(thinking))
            }
        } else if type == "message_start", let message = json["message"] as? [String: Any], let usageData = message["usage"] as? [String: Any] {
            let input = usageData["input_tokens"] as? Int ?? 0
            let cacheCreation = usageData["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = usageData["cache_read_input_tokens"] as? Int ?? 0
            let usage = LLMService.TokenUsage(
                input: input + cacheCreation + cacheRead,
                output: usageData["output_tokens"] as? Int ?? 0,
                cached: cacheRead,
                reasoning: nil
            )
            continuation.yield(.usage(usage))
        } else if type == "message_delta", let usageData = json["usage"] as? [String: Any] {
            let usage = LLMService.TokenUsage(
                input: 0,
                output: usageData["output_tokens"] as? Int ?? 0,
                cached: nil,
                reasoning: nil
            )
            continuation.yield(.usage(usage))
        } else if type == "error",
                  let error = json["error"] as? [String: Any],
                  let message = error["message"] as? String {
            throw LLMService.LLMError.apiError(message)
        }
    }

    private func contentBlocks(for prompt: LLMRequestPrompt) -> [[String: Any]] {
        if let prefix = prompt.cachePrefix,
           !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var blocks: [[String: Any]] = [
                [
                    "type": "text",
                    "text": prefix,
                    "cache_control": ["type": "ephemeral"]
                ]
            ]
            if let suffix = prompt.cacheSuffix, !suffix.isEmpty {
                blocks.append([
                    "type": "text",
                    "text": suffix
                ])
            }
            return blocks
        }

        return [["type": "text", "text": prompt.text]]
    }
}
