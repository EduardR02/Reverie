import Foundation

struct AIPanelIndexedItem: Identifiable, Equatable {
    let id: Int64
    let index: Int
}

enum AIPanelListOrder {
    static func orderedAnnotationItems(_ annotations: [Annotation]) -> [AIPanelIndexedItem] {
        annotations.indices
            .compactMap { index -> (id: Int64, sourceBlockId: Int, index: Int)? in
                guard let id = annotations[index].id else { return nil }
                return (id, annotations[index].sourceBlockId, index)
            }
            .sorted {
                $0.sourceBlockId == $1.sourceBlockId
                    ? $0.index < $1.index
                    : $0.sourceBlockId < $1.sourceBlockId
            }
            .map { AIPanelIndexedItem(id: $0.id, index: $0.index) }
    }

    static func orderedQuizItems(_ quizzes: [Quiz]) -> [AIPanelIndexedItem] {
        quizzes.indices
            .compactMap { index -> (id: Int64, sourceBlockId: Int, index: Int)? in
                guard let id = quizzes[index].id else { return nil }
                return (id, quizzes[index].sourceBlockId, index)
            }
            .sorted {
                $0.sourceBlockId == $1.sourceBlockId
                    ? $0.index < $1.index
                    : $0.sourceBlockId < $1.sourceBlockId
            }
            .map { AIPanelIndexedItem(id: $0.id, index: $0.index) }
    }

    static func sortedImages(_ images: [GeneratedImage]) -> [GeneratedImage] {
        images.enumerated()
            .sorted {
                $0.element.sourceBlockId == $1.element.sourceBlockId
                    ? $0.offset < $1.offset
                    : $0.element.sourceBlockId < $1.element.sourceBlockId
            }
            .map(\.element)
    }
}
