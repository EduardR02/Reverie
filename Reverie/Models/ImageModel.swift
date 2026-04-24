import Foundation

// MARK: - Image Model

enum ImageModel: String, Codable, CaseIterable, CustomStringConvertible {
    case gemini3Pro = "Gemini 3 Pro"
    case gemini31Flash = "Gemini 3.1 Flash"
    case gemini25Flash = "Gemini 2.5 Flash"

    static func fromAPIModel(_ apiModel: String) -> ImageModel? {
        allCases.first { $0.apiModel == apiModel }
    }

    var description: String {
        switch self {
        case .gemini3Pro: return "Nano Banana Pro"
        case .gemini31Flash: return "Nano Banana 2"
        case .gemini25Flash: return "Nano Banana"
        }
    }

    var apiModel: String {
        switch self {
        case .gemini3Pro: return "gemini-3-pro-image-preview"
        case .gemini31Flash: return "gemini-3.1-flash-image-preview"
        case .gemini25Flash: return "gemini-2.5-flash-image"
        }
    }

    var detailDescription: String {
        switch self {
        case .gemini3Pro: return "Best quality, slower"
        case .gemini31Flash: return "Fast, high quality, up to 4K"
        case .gemini25Flash: return "Fast, good quality"
        }
    }
}
