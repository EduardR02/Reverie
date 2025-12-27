import Foundation
import AppKit

/// Image generation service using Google Imagen (Nano Banana)
final class ImageService {

    struct GeneratedImageResult {
        let imageData: Data
        let prompt: String
    }

    // MARK: - Generate Image

    func generateImage(
        prompt: String,
        model: ImageModel,
        apiKey: String
    ) async throws -> Data {
        // Google Imagen API endpoint
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model.apiModel):predict?key=\(apiKey)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "instances": [
                ["prompt": prompt]
            ],
            "parameters": [
                "sampleCount": 1,
                "aspectRatio": "16:9",  // Cinematic aspect ratio
                "safetyFilterLevel": "block_some"
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ImageError.generationFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let predictions = json["predictions"] as? [[String: Any]],
              let firstPrediction = predictions.first,
              let base64Image = firstPrediction["bytesBase64Encoded"] as? String,
              let imageData = Data(base64Encoded: base64Image) else {
            throw ImageError.invalidResponse
        }

        return imageData
    }

    // MARK: - Save Image

    func saveImage(_ data: Data, for bookId: Int64, chapterId: Int64) throws -> String {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let imagesDir = appSupport
            .appendingPathComponent("Reader", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent("\(bookId)", isDirectory: true)

        try fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let filename = "\(chapterId)_\(UUID().uuidString).png"
        let imagePath = imagesDir.appendingPathComponent(filename)

        try data.write(to: imagePath)

        return imagePath.path
    }

    // MARK: - Load Image

    func loadImage(at path: String) -> NSImage? {
        NSImage(contentsOfFile: path)
    }

    enum ImageError: Error {
        case generationFailed
        case invalidResponse
        case saveFailed
    }
}
