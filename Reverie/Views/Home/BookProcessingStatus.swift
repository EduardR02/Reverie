import Foundation

struct BookProcessingStatus: Equatable {
    let progress: Double
    let completedChapters: Int
    let totalChapters: Int
}
