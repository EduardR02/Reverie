import Foundation
import AppKit

/// Image generation service using Google Gemini (Image Generation)
@MainActor
final class ImageService {
    private let session: ResilientSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 600
        self.session = ResilientSession(configuration: config)
    }

    init(session: URLSession) {
        self.session = ResilientSession(session: session)
    }

    struct ImageSuggestionInput {
        let excerpt: String
        let prompt: String
        let sourceBlockId: Int
        let aspectRatio: String?

        init(
            excerpt: String,
            prompt: String,
            sourceBlockId: Int,
            aspectRatio: String? = nil
        ) {
            self.excerpt = excerpt
            self.prompt = prompt
            self.sourceBlockId = sourceBlockId
            self.aspectRatio = aspectRatio
        }
    }

    struct GeneratedImageResult {
        let excerpt: String
        let prompt: String
        let imageData: Data?
        let sourceBlockId: Int
        let aspectRatio: String
        let status: GeneratedImage.Status
        let failureReason: String?
    }

    // MARK: - Generate Image

    nonisolated private static let defaultAspectRatio = "16:9"
    nonisolated private static let supportedAspectRatios: Set<String> = ["16:9", "1:1", "9:16"]
    private static let defaultGeminiImageSize = "2K"

    func generateImage(
        prompt: String,
        model: ImageModel,
        apiKey: String,
        aspectRatio: String? = nil,
        imageResolution: String = "2K"
    ) async throws -> Data {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ImageError.missingAPIKey
        }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model.apiModel):generateContent?key=\(trimmedKey)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let normalizedAspectRatio = Self.normalizedAspectRatio(aspectRatio)
        let normalizedImageResolution = normalizedImageResolution(imageResolution, model: model)

        var imageConfig: [String: Any] = [
            "aspectRatio": normalizedAspectRatio
        ]
        if let normalizedImageResolution {
            imageConfig["imageSize"] = normalizedImageResolution
        }

        var generationConfig: [String: Any] = [
            "temperature": 1.0,
            "maxOutputTokens": 32768,
            "responseModalities": ["IMAGE"]
        ]
        if !imageConfig.isEmpty {
            generationConfig["imageConfig"] = imageConfig
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

        let data = try await performRequest(request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageError.invalidResponse
        }

        let parts = responseParts(from: json)
        if let imageData = bestImageData(from: parts) {
            return imageData
        }

        if let refusal = extractResponseText(from: parts) {
            throw ImageError.noImageReturned(refusal)
        }

        if let blockedReason = Self.blockedPromptFeedbackReason(from: json) {
            throw ImageError.noImageReturned(blockedReason)
        }

        throw ImageError.invalidResponse
    }

    func generateImages(
        from suggestions: [ImageSuggestionInput],
        model: ImageModel,
        apiKey: String,
        maxConcurrent: Int = 5,
        onRequestStart: (@Sendable () -> Void)? = nil,
        onRequestFinish: (@Sendable () -> Void)? = nil
    ) async -> [GeneratedImageResult] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !suggestions.isEmpty else {
            return []
        }

        let limit = max(1, maxConcurrent)
        let results = await mapWithConcurrency(items: suggestions, maxConcurrent: limit) { suggestion in
            onRequestStart?()
            defer { onRequestFinish?() }

            let resolvedAspectRatio = Self.normalizedAspectRatio(suggestion.aspectRatio)

            do {
                let data = try await self.generateImage(
                    prompt: suggestion.prompt,
                    model: model,
                    apiKey: trimmedKey,
                    aspectRatio: resolvedAspectRatio
                )

                return GeneratedImageResult(
                    excerpt: suggestion.excerpt,
                    prompt: suggestion.prompt,
                    imageData: data,
                    sourceBlockId: suggestion.sourceBlockId,
                    aspectRatio: resolvedAspectRatio,
                    status: .success,
                    failureReason: nil
                )
            } catch {
                print("Failed to generate image: \(error)")

                let (status, reason) = Self.failureMetadata(from: error)
                return GeneratedImageResult(
                    excerpt: suggestion.excerpt,
                    prompt: suggestion.prompt,
                    imageData: nil,
                    sourceBlockId: suggestion.sourceBlockId,
                    aspectRatio: resolvedAspectRatio,
                    status: status,
                    failureReason: reason
                )
            }
        }

        return results
    }

    private struct ResponsePart {
        let text: String?
        let inlineData: [String: Any]?
        let isThought: Bool
        let candidateIndex: Int
        let partIndex: Int
    }

    private struct ResponseImage {
        let data: Data
        let isThought: Bool
        let candidateIndex: Int
        let partIndex: Int
    }

    private nonisolated static func normalizedAspectRatio(_ aspectRatio: String?) -> String {
        let trimmed = aspectRatio?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        guard Self.supportedAspectRatios.contains(trimmed) else {
            return Self.defaultAspectRatio
        }
        return trimmed
    }

    private func normalizedImageResolution(_ imageResolution: String, model: ImageModel) -> String? {
        guard SupportedModels.supportsGeminiImageSize(model.apiModel) else {
            return nil
        }

        let trimmed = imageResolution
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        switch trimmed {
        case "":
            return Self.defaultGeminiImageSize
        case "1K", "2K", "4K":
            return trimmed
        case "512" where model == .gemini31Flash:
            return trimmed
        default:
            return Self.defaultGeminiImageSize
        }
    }

    private func responseParts(from json: [String: Any]) -> [ResponsePart] {
        let candidates = json["candidates"] as? [[String: Any]] ?? []

        return candidates.enumerated().flatMap { candidateIndex, candidate in
            guard let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                return [ResponsePart]()
            }

            return parts.enumerated().map { partIndex, part in
                ResponsePart(
                    text: part["text"] as? String,
                    inlineData: inlineData(from: part),
                    isThought: part["thought"] as? Bool ?? false,
                    candidateIndex: candidateIndex,
                    partIndex: partIndex
                )
            }
        }
    }

    private func inlineData(from part: [String: Any]) -> [String: Any]? {
        if let inlineData = part["inlineData"] as? [String: Any] {
            return inlineData
        }
        return part["inline_data"] as? [String: Any]
    }

    private func mimeType(from inlineData: [String: Any]) -> String? {
        if let mimeType = inlineData["mimeType"] as? String {
            return mimeType
        }
        return inlineData["mime_type"] as? String
    }

    private func bestImageData(from parts: [ResponsePart]) -> Data? {
        let images = parts.compactMap { part -> ResponseImage? in
            guard let inlineData = part.inlineData,
                  let base64Image = inlineData["data"] as? String else {
                return nil
            }

            let mimeType = mimeType(from: inlineData)
            if let mimeType, !mimeType.lowercased().hasPrefix("image/") {
                return nil
            }

            guard let imageData = sanitizedImageData(from: base64Image, mimeType: mimeType) else {
                return nil
            }

            return ResponseImage(
                data: imageData,
                isThought: part.isThought,
                candidateIndex: part.candidateIndex,
                partIndex: part.partIndex
            )
        }

        return images.max(by: isLessPreferredImage)?.data
    }

    private func isLessPreferredImage(_ lhs: ResponseImage, _ rhs: ResponseImage) -> Bool {
        if lhs.isThought != rhs.isThought {
            return lhs.isThought && !rhs.isThought
        }
        if lhs.candidateIndex != rhs.candidateIndex {
            return lhs.candidateIndex > rhs.candidateIndex
        }
        return lhs.partIndex < rhs.partIndex
    }

    private func extractResponseText(from parts: [ResponsePart]) -> String? {
        let text = parts
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private nonisolated static func blockedPromptFeedbackReason(from json: [String: Any]) -> String? {
        guard let promptFeedback = json["promptFeedback"] as? [String: Any] else {
            return nil
        }

        if let message = nonEmptyString(promptFeedback["blockReasonMessage"]) {
            return message
        }

        if let blockReason = nonEmptyString(promptFeedback["blockReason"]) {
            return "Prompt blocked by Gemini: \(blockReason)."
        }

        let blockedCategories = (promptFeedback["safetyRatings"] as? [[String: Any]] ?? []).compactMap { rating -> String? in
            guard rating["blocked"] as? Bool == true else {
                return nil
            }
            return nonEmptyString(rating["category"])
        }

        guard !blockedCategories.isEmpty else {
            return nil
        }
        return "Prompt blocked by Gemini safety filters (\(blockedCategories.joined(separator: ", ")))."
    }

    private nonisolated static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func failureMetadata(from error: Error) -> (GeneratedImage.Status, String) {
        if let imageError = error as? ImageError {
            switch imageError {
            case .noImageReturned(let reason):
                return (isLikelyRefusal(reason) ? .refused : .failed, reason)
            case .apiError(let message):
                return (isLikelyRefusal(message) ? .refused : .failed, message)
            default:
                let fallback = imageError.errorDescription ?? "Image generation failed."
                return (.failed, fallback)
            }
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return (.failed, message.isEmpty ? "Image generation failed." : message)
    }

    private nonisolated static func isLikelyRefusal(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let refusalSignals = [
            "policy",
            "safety",
            "cannot",
            "can't",
            "refuse",
            "not able",
            "not allowed",
            "disallowed",
            "blocked",
            "unsafe",
            "content filter",
            "harmful"
        ]
        return refusalSignals.contains { normalized.contains($0) }
    }

    // MARK: - Save Image

    private func sanitizedImageData(from base64: String, mimeType: String?) -> Data? {
        let sanitized = sanitizeBase64Image(base64, mimeType: mimeType ?? "")
        return Data(base64Encoded: sanitized, options: .ignoreUnknownCharacters)
    }

    private func sanitizeBase64Image(_ raw: String, mimeType: String) -> String {
        let lowerMimeType = mimeType.lowercased()
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        var candidates: [String] = []

        if lowerMimeType.contains("png"), let trailerRange = cleaned.range(of: "AElFTkSuQmCC", options: .backwards) {
            candidates.append(String(cleaned[..<trailerRange.upperBound]))
        }

        if let firstInvalid = cleaned.firstIndex(where: { !isBase64Char($0) }) {
            candidates.append(String(cleaned[..<firstInvalid]))
        }

        candidates.append(cleaned)

        for candidate in candidates {
            let stripped = stripInvalidChars(candidate)
            let normalized = padBase64(stripped)
            if normalized.count % 4 == 1 {
                continue
            }

            guard let decoded = decodeSafe(normalized) else {
                continue
            }

            if lowerMimeType.contains("png") {
                if let endPosition = findPngEnd(decoded) {
                    if endPosition < decoded.count {
                        return Data(decoded.prefix(endPosition)).base64EncodedString()
                    }
                    return normalized
                }
                continue
            }

            return normalized
        }

        let strippedFallback = stripInvalidChars(cleaned)
        let fallback = padBase64(strippedFallback)

        if let firstPadding = cleaned.firstIndex(of: "=") {
            var endOfPadding = firstPadding
            while endOfPadding < cleaned.endIndex && cleaned[endOfPadding] == "=" {
                endOfPadding = cleaned.index(after: endOfPadding)
            }
            return padBase64(stripInvalidChars(String(cleaned[..<endOfPadding])))
        }

        return fallback.isEmpty ? cleaned : fallback
    }

    private func padBase64(_ str: String) -> String {
        let padNeeded = (4 - (str.count % 4)) % 4
        return str + String(repeating: "=", count: padNeeded)
    }

    private func decodeSafe(_ str: String) -> Data? {
        Data(base64Encoded: str)
    }

    private func stripInvalidChars(_ str: String) -> String {
        String(str.filter { isBase64Char($0) })
    }

    private func isBase64Char(_ char: Character) -> Bool {
        switch char {
        case "A"..."Z", "a"..."z", "0"..."9", "+", "/", "=":
            return true
        default:
            return false
        }
    }

    private func findPngEnd(_ data: Data) -> Int? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count, data.starts(with: signature) else { return nil }

        var offset = 8
        while offset + 8 <= data.count {
            let length = data[offset..<offset + 4].reduce(UInt32(0)) { result, byte in
                (result << 8) | UInt32(byte)
            }
            let typeStart = offset + 4
            let typeEnd = typeStart + 4
            guard typeEnd <= data.count else { return nil }

            let chunkType = String(bytes: data[typeStart..<typeEnd], encoding: .ascii) ?? ""
            let chunkEnd = offset + 8 + Int(length) + 4
            if chunkEnd > data.count {
                return nil
            }
            if chunkType == "IEND" {
                return chunkEnd
            }
            offset = chunkEnd
        }
        return nil
    }

    private func performRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw ImageError.apiError(message)
            }
            throw ImageError.httpError(httpResponse.statusCode)
        }

        return data
    }

    private func mapWithConcurrency<T: Sendable, U: Sendable>(
        items: [T],
        maxConcurrent: Int,
        transform: @Sendable @escaping (T) async -> U
    ) async -> [U] {
        var results: [U?] = Array(repeating: nil, count: items.count)
        var nextIndex = 0

        await withTaskGroup(of: (Int, U).self) { group in
            func enqueueNext() {
                guard nextIndex < items.count else { return }
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    let value = await transform(items[index])
                    return (index, value)
                }
            }

            for _ in 0..<min(maxConcurrent, items.count) {
                enqueueNext()
            }

            while let (index, value) = await group.next() {
                results[index] = value
                enqueueNext()
            }
        }

        return results.compactMap { $0 }
    }

    func saveImage(_ data: Data, for bookId: Int64, chapterId: Int64) throws -> String {
        let imagesDir = LibraryPaths.imagesDirectory
            .appendingPathComponent("\(bookId)", isDirectory: true)

        try LibraryPaths.ensureDirectory(imagesDir)

        let filename = "\(chapterId)_\(UUID().uuidString).png"
        let imagePath = imagesDir.appendingPathComponent(filename)

        try data.write(to: imagePath)

        return imagePath.path
    }

    // MARK: - Load Image

    func loadImage(at path: String) -> NSImage? {
        NSImage(contentsOfFile: path)
    }

    // MARK: - Test Helpers

    func testSanitizeBase64Image(_ raw: String, mimeType: String) -> String {
        sanitizeBase64Image(raw, mimeType: mimeType)
    }

    func testFindPngEnd(_ data: Data) -> Int? {
        findPngEnd(data)
    }

    enum ImageError: LocalizedError {
        case missingAPIKey
        case apiError(String)
        case httpError(Int)
        case invalidResponse
        case noImageReturned(String)
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Missing Google API key."
            case .apiError(let message):
                return "Image generation failed: \(message)"
            case .httpError(let status):
                return "Image generation failed with HTTP \(status)."
            case .invalidResponse:
                return "Image generation returned an invalid response."
            case .noImageReturned(let reason):
                return reason
            case .saveFailed:
                return "Failed to save generated image."
            }
        }
    }
}
