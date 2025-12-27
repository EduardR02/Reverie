import Foundation

/// Multi-provider LLM service for chapter analysis
final class LLMService {

    struct ChapterAnalysis: Codable {
        let annotations: [AnnotationData]
        let quizQuestions: [QuizData]
        let imageSuggestions: [ImageSuggestion]
        let summary: String
    }

    struct AnnotationData: Codable {
        let type: String
        let title: String
        let content: String
        let sourceQuote: String
    }

    struct QuizData: Codable {
        let question: String
        let answer: String
        let sourceQuote: String
    }

    struct ImageSuggestion: Codable {
        let prompt: String
        let sourceQuote: String
    }

    struct ExplainResult: Codable {
        let explanation: String
    }

    /// Chunk of streaming response
    struct StreamChunk {
        let text: String
        let isThinking: Bool

        static func content(_ text: String) -> StreamChunk {
            StreamChunk(text: text, isThinking: false)
        }

        static func thinking(_ text: String) -> StreamChunk {
            StreamChunk(text: text, isThinking: true)
        }
    }

    // MARK: - Analyze Chapter

    func analyzeChapter(
        content: String,
        rollingSummary: String?,
        settings: UserSettings
    ) async throws -> ChapterAnalysis {
        let prompt = buildAnalysisPrompt(
            content: content,
            rollingSummary: rollingSummary,
            insightDensity: settings.insightDensity,
            imageDensity: settings.imagesEnabled ? settings.imageDensity : nil
        )

        let response = try await sendRequest(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature
        )

        return try parseAnalysisResponse(response)
    }

    // MARK: - Word Explanation

    func explainWord(
        word: String,
        context: String,
        rollingSummary: String?,
        settings: UserSettings
    ) async throws -> String {
        let prompt = """
        The reader clicked on the word "\(word)" in the following paragraph:

        "\(context)"

        Previous story context:
        \(rollingSummary ?? "This is the beginning of the book.")

        Explain this word/concept in context. Be concise (2-3 sentences max).
        CRITICAL: Only use information from the story up to this point. NO SPOILERS.

        Respond with just the explanation, no formatting.
        """

        return try await sendRequest(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature
        )
    }

    // MARK: - Generate Image Prompt

    func generateImagePrompt(
        word: String,
        context: String,
        settings: UserSettings
    ) async throws -> String {
        let prompt = """
        The reader wants to visualize the scene around "\(word)" in this paragraph:

        "\(context)"

        Create an image generation prompt that captures this scene.
        Include: setting, characters present, mood, lighting, key visual elements.
        Style: cinematic, detailed, atmospheric.
        Max 100 words.

        Respond with just the prompt, no formatting or explanation.
        """

        return try await sendRequest(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature
        )
    }

    // MARK: - Chat (Q&A)

    func chat(
        message: String,
        chapterContent: String,
        rollingSummary: String?,
        settings: UserSettings
    ) async throws -> String {
        let prompt = """
        You are a reading companion. The reader is currently reading this chapter:

        ---
        \(chapterContent)
        ---

        Previous story summary:
        \(rollingSummary ?? "This is the beginning of the book.")

        The reader asks: "\(message)"

        Answer their question using only information from the current chapter and previous context.
        CRITICAL: DO NOT reveal anything that happens after this point in the story. No spoilers.

        Be helpful and concise.
        """

        return try await sendRequest(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature
        )
    }

    // MARK: - Streaming Chat

    func chatStreaming(
        message: String,
        chapterContent: String,
        rollingSummary: String?,
        settings: UserSettings
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        let prompt = """
        You are a reading companion. The reader is currently reading this chapter:

        ---
        \(chapterContent)
        ---

        Previous story summary:
        \(rollingSummary ?? "This is the beginning of the book.")

        The reader asks: "\(message)"

        Answer their question using only information from the current chapter and previous context.
        CRITICAL: DO NOT reveal anything that happens after this point in the story. No spoilers.

        Be helpful and concise.
        """

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let key = apiKey(for: settings.llmProvider, settings: settings)
                    let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedKey.isEmpty else {
                        continuation.finish(throwing: LLMError.noAPIKey(settings.llmProvider))
                        return
                    }

                    let reasoningLevel = settings.chatReasoningLevel
                    let temperature = settings.temperature

                    switch settings.llmProvider {
                    case .google:
                        try await streamGoogleRequest(
                            prompt: prompt,
                            model: settings.llmModel,
                            apiKey: trimmedKey,
                            temperature: temperature,
                            reasoningLevel: reasoningLevel,
                            continuation: continuation
                        )
                    case .openai:
                        try await streamOpenAIRequest(
                            prompt: prompt,
                            model: settings.llmModel,
                            apiKey: trimmedKey,
                            temperature: temperature,
                            reasoningLevel: reasoningLevel,
                            continuation: continuation
                        )
                    case .anthropic:
                        try await streamAnthropicRequest(
                            prompt: prompt,
                            model: settings.llmModel,
                            apiKey: trimmedKey,
                            temperature: temperature,
                            reasoningLevel: reasoningLevel,
                            continuation: continuation
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Generate More Content

    func generateMoreInsights(
        content: String,
        rollingSummary: String?,
        existingTitles: [String],
        settings: UserSettings
    ) async throws -> [AnnotationData] {
        let existingList = existingTitles.map { "- \($0)" }.joined(separator: "\n")

        let prompt = """
        You are a reading companion. Generate 3-5 NEW insights for this chapter.

        ## Previous Context
        \(rollingSummary ?? "This is the start of the book.")

        ## Chapter Content
        \(content)

        ## Already Generated Insights (DO NOT DUPLICATE)
        \(existingList.isEmpty ? "None yet" : existingList)

        Generate NEW annotations that are DIFFERENT from the existing ones.
        Types: insight, context, trivia, worldBuilding, character

        CRITICAL: No spoilers. Only use information from this chapter and before.

        Respond with JSON:
        ```json
        {
          "annotations": [
            {"type": "...", "title": "...", "content": "...", "sourceQuote": "..."}
          ]
        }
        ```
        """

        let response = try await sendRequest(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature
        )

        let analysis = try parseAnalysisResponse(response)
        return analysis.annotations
    }

    func generateMoreQuestions(
        content: String,
        rollingSummary: String?,
        existingQuestions: [String],
        settings: UserSettings
    ) async throws -> [QuizData] {
        let existingList = existingQuestions.map { "- \($0)" }.joined(separator: "\n")

        let prompt = """
        You are a reading companion. Generate 3-5 NEW quiz questions for this chapter.

        ## Previous Context
        \(rollingSummary ?? "This is the start of the book.")

        ## Chapter Content
        \(content)

        ## Already Generated Questions (DO NOT DUPLICATE)
        \(existingList.isEmpty ? "None yet" : existingList)

        Generate NEW questions that are DIFFERENT from the existing ones.
        Test comprehension with specific quotes from the chapter.

        CRITICAL: No spoilers. Only use information from this chapter and before.

        Respond with JSON:
        ```json
        {
          "quizQuestions": [
            {"question": "...", "answer": "...", "sourceQuote": "..."}
          ]
        }
        ```
        """

        let response = try await sendRequest(
            prompt: prompt,
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: apiKey(for: settings.llmProvider, settings: settings),
            temperature: settings.temperature
        )

        let analysis = try parseAnalysisResponse(response)
        return analysis.quizQuestions
    }

    // MARK: - Build Analysis Prompt

    private func buildAnalysisPrompt(
        content: String,
        rollingSummary: String?,
        insightDensity: DensityLevel,
        imageDensity: DensityLevel?
    ) -> String {
        let insightRange = insightDensity.annotationRange
        let imageSection: String
        if let imageDensity = imageDensity {
            let imageRange = imageDensity.imageRange
            imageSection = """

        3. **Image Suggestions** (\(imageRange.min)-\(imageRange.max) scenes that would benefit from illustration):
           Use your judgment within this range based on chapter content.
           Return image prompts that capture key visual moments.
        """
        } else {
            imageSection = ""
        }

        return """
        You are a reading companion analyzing a book chapter. Your goal is to enhance the reading experience.

        ## Previous Story Context
        \(rollingSummary ?? "This is the start of the book.")

        ## Current Chapter
        \(content)

        ## Your Tasks

        1. **Annotations** (\(insightRange.min)-\(insightRange.max) annotations):
           Use your judgment within this range based on chapter richness.
           Types: insight (connections, themes), context (real-world background),
           trivia (interesting facts), worldBuilding (in-universe lore), character (background)

           For each, provide:
           - type: one of the types above
           - title: brief title (3-5 words)
           - content: explanation (2-4 sentences)
           - sourceQuote: exact quote from chapter this relates to

        2. **Quiz Questions** (3-5 questions):
           Test comprehension. Include the exact quote that answers each question.
        \(imageSection)

        4. **Chapter Summary** (2-3 sentences):
           What happened? Key events only.

        CRITICAL RULE: You only know what happens UP TO this chapter.
        DO NOT reveal future plot points, character fates, or any spoilers.
        Treat this as if you've never read beyond this point.

        ## Response Format (JSON)
        ```json
        {
          "annotations": [
            {"type": "...", "title": "...", "content": "...", "sourceQuote": "..."}
          ],
          "quizQuestions": [
            {"question": "...", "answer": "...", "sourceQuote": "..."}
          ],
          "imageSuggestions": [
            {"prompt": "...", "sourceQuote": "..."}
          ],
          "summary": "..."
        }
        ```
        """
    }

    // MARK: - API Request

    private func sendRequest(
        prompt: String,
        provider: LLMProvider,
        model: String,
        apiKey: String,
        temperature: Double = 1.0
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw LLMError.noAPIKey(provider)
        }

        switch provider {
        case .google:
            return try await sendGoogleRequest(prompt: prompt, model: model, apiKey: trimmedKey, temperature: temperature)
        case .openai:
            return try await sendOpenAIRequest(prompt: prompt, model: model, apiKey: trimmedKey, temperature: temperature)
        case .anthropic:
            return try await sendAnthropicRequest(prompt: prompt, model: model, apiKey: trimmedKey, temperature: temperature)
        }
    }

    // MARK: - Google (Gemini)

    private func sendGoogleRequest(prompt: String, model: String, apiKey: String, temperature: Double = 1.0, isMultiTurn: Bool = false) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        let isGemini3 = model.contains("gemini-3")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var generationConfig: [String: Any] = [
            "temperature": temperature,
            "maxOutputTokens": isGemini3 ? 65536 : 8192,
            "responseMimeType": "text/plain"
        ]

        // Gemini 3 uses thinking_config with thinkingLevel
        if isGemini3 {
            generationConfig["thinking_config"] = [
                "thinkingLevel": "medium",
                "include_thoughts": false
            ]
        }

        let body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": [["text": prompt]]]
            ],
            "safetySettings": [
                ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"]
            ],
            "generationConfig": generationConfig
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw LLMError.apiError(message)
            }
            throw LLMError.httpError(httpResponse.statusCode)
        }

        let responseJson = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let candidates = responseJson?["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw LLMError.invalidResponse
        }

        return text
    }

    // MARK: - OpenAI (Responses API)

    private func sendOpenAIRequest(prompt: String, model: String, apiKey: String, temperature: Double = 1.0) async throws -> String {
        // OpenAI Responses API endpoint
        let url = URL(string: "https://api.openai.com/v1/responses")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "user", "content": [["type": "input_text", "text": prompt]]]
            ],
            "max_output_tokens": 16384,
            "stream": false
        ]

        // GPT-5.x supports reasoning
        if model.contains("gpt-5") {
            body["reasoning"] = ["effort": "medium"]
        } else {
            body["temperature"] = temperature
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw LLMError.apiError(message)
            }
            throw LLMError.httpError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }

        // Find message item in output
        guard let messageItem = output.first(where: { ($0["type"] as? String) == "message" }),
              let contentParts = messageItem["content"] as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }

        let text = contentParts
            .filter { ($0["type"] as? String) == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()

        return text
    }

    // MARK: - Anthropic

    private func sendAnthropicRequest(prompt: String, model: String, apiKey: String, temperature: Double = 1.0) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let canThink = model.contains("sonnet-4") || model.contains("opus-4")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let maxTokens = canThink ? 32000 : 8192

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": [["type": "text", "text": prompt]]]
            ]
        ]

        // Enable thinking for Claude 4.5 models
        if canThink {
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": maxTokens - 4000
            ]
        } else {
            body["temperature"] = temperature
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw LLMError.apiError(message)
            }
            throw LLMError.httpError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }

        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        return text
    }

    // MARK: - Parse Response

    private func parseAnalysisResponse(_ response: String) throws -> ChapterAnalysis {
        // Extract JSON from response (may be wrapped in markdown code block)
        var jsonString = response

        if let start = response.range(of: "```json"),
           let end = response.range(of: "```", range: start.upperBound..<response.endIndex) {
            jsonString = String(response[start.upperBound..<end.lowerBound])
        } else if let start = response.range(of: "{"),
                  let end = response.range(of: "}", options: .backwards) {
            jsonString = String(response[start.lowerBound...end.lowerBound])
        }

        let data = jsonString.data(using: .utf8)!
        return try JSONDecoder().decode(ChapterAnalysis.self, from: data)
    }

    // MARK: - Helpers

    private func apiKey(for provider: LLMProvider, settings: UserSettings) -> String {
        switch provider {
        case .google: return settings.googleAPIKey
        case .openai: return settings.openAIAPIKey
        case .anthropic: return settings.anthropicAPIKey
        }
    }

    // MARK: - Streaming Requests

    private func streamGoogleRequest(
        prompt: String,
        model: String,
        apiKey: String,
        temperature: Double,
        reasoningLevel: ReasoningLevel,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        let isGemini3 = model.contains("gemini-3")
        let isFlash = model.contains("flash")

        // Use streamGenerateContent endpoint with SSE
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var generationConfig: [String: Any] = [
            "temperature": temperature,
            "maxOutputTokens": isGemini3 ? 65536 : 8192,
            "responseMimeType": "text/plain"
        ]

        // Add thinking config for Gemini 3
        if isGemini3 && reasoningLevel != .off {
            let thinkingLevel = reasoningLevel.gemini3Level(isFlash: isFlash)
            generationConfig["thinking_config"] = [
                "thinkingLevel": thinkingLevel,
                "include_thoughts": true
            ]
        }

        let body: [String: Any] = [
            "contents": [
                ["role": "user", "parts": [["text": prompt]]]
            ],
            "safetySettings": [
                ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"],
                ["category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"]
            ],
            "generationConfig": generationConfig
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw LLMError.httpError(httpResponse.statusCode)
        }

        var buffer = ""
        for try await byte in bytes {
            buffer.append(Character(UnicodeScalar(byte)))

            // Process complete SSE lines
            while let lineEnd = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<lineEnd]).trimmingCharacters(in: .whitespaces)
                buffer = String(buffer[buffer.index(after: lineEnd)...])

                if line.hasPrefix("data: ") {
                    let jsonStr = String(line.dropFirst(6))
                    if jsonStr == "[DONE]" { continue }

                    if let data = jsonStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let candidates = json["candidates"] as? [[String: Any]],
                       let content = candidates.first?["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]] {
                        for part in parts {
                            if let text = part["text"] as? String {
                                let isThought = part["thought"] as? Bool ?? false
                                continuation.yield(isThought ? .thinking(text) : .content(text))
                            }
                        }
                    }
                }
            }
        }
    }

    private func streamOpenAIRequest(
        prompt: String,
        model: String,
        apiKey: String,
        temperature: Double,
        reasoningLevel: ReasoningLevel,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        let url = URL(string: "https://api.openai.com/v1/responses")!
        let isReasoner = model.contains("gpt-5") || model.contains("o1") || model.contains("o3")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "user", "content": [["type": "input_text", "text": prompt]]]
            ],
            "max_output_tokens": isReasoner ? 100000 : 16384,
            "stream": true
        ]

        if isReasoner && reasoningLevel != .off {
            body["reasoning"] = ["effort": reasoningLevel.openAIEffort]
        } else {
            body["temperature"] = temperature
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw LLMError.httpError(httpResponse.statusCode)
        }

        var buffer = ""
        for try await byte in bytes {
            buffer.append(Character(UnicodeScalar(byte)))

            while let lineEnd = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<lineEnd]).trimmingCharacters(in: .whitespaces)
                buffer = String(buffer[buffer.index(after: lineEnd)...])

                if line.hasPrefix("data: ") {
                    let jsonStr = String(line.dropFirst(6))
                    if jsonStr == "[DONE]" { continue }

                    if let data = jsonStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // Handle text delta
                        if let type = json["type"] as? String,
                           type == "response.output_text.delta",
                           let delta = json["delta"] as? String {
                            continuation.yield(.content(delta))
                        }
                    }
                }
            }
        }
    }

    private func streamAnthropicRequest(
        prompt: String,
        model: String,
        apiKey: String,
        temperature: Double,
        reasoningLevel: ReasoningLevel,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let canThink = model.contains("sonnet-4") || model.contains("opus-4")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let maxTokens = canThink ? 32000 : 8192

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": [["type": "text", "text": prompt]]]
            ],
            "stream": true
        ]

        if canThink && reasoningLevel.anthropicEnabled {
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": maxTokens - 4000
            ]
        } else {
            body["temperature"] = temperature
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw LLMError.httpError(httpResponse.statusCode)
        }

        var buffer = ""
        for try await byte in bytes {
            buffer.append(Character(UnicodeScalar(byte)))

            while let lineEnd = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<lineEnd]).trimmingCharacters(in: .whitespaces)
                buffer = String(buffer[buffer.index(after: lineEnd)...])

                if line.hasPrefix("data: ") {
                    let jsonStr = String(line.dropFirst(6))
                    if jsonStr == "[DONE]" { continue }

                    if let data = jsonStr.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let type = json["type"] as? String, type == "content_block_delta",
                           let delta = json["delta"] as? [String: Any] {
                            if let deltaType = delta["type"] as? String {
                                if deltaType == "text_delta", let text = delta["text"] as? String {
                                    continuation.yield(.content(text))
                                } else if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String {
                                    continuation.yield(.thinking(thinking))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    enum LLMError: LocalizedError {
        case invalidResponse
        case noAPIKey(LLMProvider)
        case apiError(String)
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from API"
            case .noAPIKey(let provider):
                return "Missing API key for \(provider.displayName). Add it in Settings."
            case .apiError(let message): return message
            case .httpError(let code):
                switch code {
                case 401, 403:
                    return "API key rejected. Check your key or provider."
                case 402:
                    return "Billing issue or insufficient funds."
                case 429:
                    return "Rate limit exceeded. Try again soon."
                default:
                    return "HTTP error: \(code)"
                }
            }
        }
    }
}
