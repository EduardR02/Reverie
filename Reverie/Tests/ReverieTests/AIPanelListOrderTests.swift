import XCTest
@testable import Reverie

final class AIPanelListOrderTests: XCTestCase {
    func test_orderedAnnotationItemsSortsBySourceBlockAndKeepsBindingIndex() {
        let annotations = [
            Annotation(id: 10, chapterId: 1, type: .science, title: "Third", content: "", sourceBlockId: 3),
            Annotation(id: nil, chapterId: 1, type: .history, title: "Unsaved", content: "", sourceBlockId: 1),
            Annotation(id: 20, chapterId: 1, type: .world, title: "First", content: "", sourceBlockId: 1)
        ]

        let items = AIPanelListOrder.orderedAnnotationItems(annotations)

        XCTAssertEqual(items, [
            AIPanelIndexedItem(id: 20, index: 2),
            AIPanelIndexedItem(id: 10, index: 0)
        ])
    }

    func test_orderedAnnotationItemsPreservesOriginalOrderWithinSameSourceBlock() {
        let annotations = [
            Annotation(id: 10, chapterId: 1, type: .science, title: "First", content: "", sourceBlockId: 3),
            Annotation(id: 20, chapterId: 1, type: .history, title: "Second", content: "", sourceBlockId: 3),
            Annotation(id: 30, chapterId: 1, type: .world, title: "Earlier block", content: "", sourceBlockId: 1),
            Annotation(id: 40, chapterId: 1, type: .philosophy, title: "Third", content: "", sourceBlockId: 3)
        ]

        let items = AIPanelListOrder.orderedAnnotationItems(annotations)

        XCTAssertEqual(items, [
            AIPanelIndexedItem(id: 30, index: 2),
            AIPanelIndexedItem(id: 10, index: 0),
            AIPanelIndexedItem(id: 20, index: 1),
            AIPanelIndexedItem(id: 40, index: 3)
        ])
    }

    func test_orderedQuizItemsSortsBySourceBlockAndKeepsBindingIndex() {
        let quizzes = [
            Quiz(id: 100, chapterId: 1, question: "Later?", answer: "A", sourceBlockId: 9),
            Quiz(id: 200, chapterId: 1, question: "Earlier?", answer: "B", sourceBlockId: 2),
            Quiz(id: nil, chapterId: 1, question: "Unsaved?", answer: "C", sourceBlockId: 1)
        ]

        let items = AIPanelListOrder.orderedQuizItems(quizzes)

        XCTAssertEqual(items, [
            AIPanelIndexedItem(id: 200, index: 1),
            AIPanelIndexedItem(id: 100, index: 0)
        ])
    }

    func test_orderedQuizItemsPreservesOriginalOrderWithinSameSourceBlock() {
        let quizzes = [
            Quiz(id: 100, chapterId: 1, question: "First?", answer: "A", sourceBlockId: 5),
            Quiz(id: 200, chapterId: 1, question: "Second?", answer: "B", sourceBlockId: 5),
            Quiz(id: 300, chapterId: 1, question: "Earlier?", answer: "C", sourceBlockId: 2)
        ]

        let items = AIPanelListOrder.orderedQuizItems(quizzes)

        XCTAssertEqual(items, [
            AIPanelIndexedItem(id: 300, index: 2),
            AIPanelIndexedItem(id: 100, index: 0),
            AIPanelIndexedItem(id: 200, index: 1)
        ])
    }

    func test_sortedImagesSortsBySourceBlock() {
        let images = [
            GeneratedImage(id: 1, chapterId: 1, prompt: "Middle", imagePath: "/tmp/2.png", sourceBlockId: 20),
            GeneratedImage(id: 2, chapterId: 1, prompt: "First", imagePath: "/tmp/1.png", sourceBlockId: 10),
            GeneratedImage(id: 3, chapterId: 1, prompt: "Last", imagePath: "/tmp/3.png", sourceBlockId: 30)
        ]

        let sorted = AIPanelListOrder.sortedImages(images)

        XCTAssertEqual(sorted.map(\.id), [2, 1, 3])
    }

    func test_sortedImagesPreservesOriginalOrderWithinSameSourceBlock() {
        let images = [
            GeneratedImage(id: 1, chapterId: 1, prompt: "First", imagePath: "/tmp/1.png", sourceBlockId: 20),
            GeneratedImage(id: 2, chapterId: 1, prompt: "Second", imagePath: "/tmp/2.png", sourceBlockId: 20),
            GeneratedImage(id: 3, chapterId: 1, prompt: "Earlier", imagePath: "/tmp/3.png", sourceBlockId: 10),
            GeneratedImage(id: 4, chapterId: 1, prompt: "Third", imagePath: "/tmp/4.png", sourceBlockId: 20)
        ]

        let sorted = AIPanelListOrder.sortedImages(images)

        XCTAssertEqual(sorted.map(\.id), [3, 1, 2, 4])
    }
}
