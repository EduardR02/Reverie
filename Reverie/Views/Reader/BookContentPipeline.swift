import Foundation

struct BookContentStyleState: Equatable, Hashable, Encodable, Sendable {
    let themeBase: String
    let themeSurface: String
    let themeText: String
    let themeMuted: String
    let themeRose: String
    let themeIris: String
    let fontFamily: String
    let fontSize: Double
    let lineSpacing: Double
}

struct BookContentDocumentState: Equatable, Hashable, Sendable {
    let chapterId: Int64?
    let chapterIndex: Int
    let contentHTML: String
    let baseHref: String

    var renderSignature: Int {
        var hasher = Hasher()
        hasher.combine(self)
        return hasher.finalize()
    }

    var bridgeToken: String {
        "document-\(renderSignature)"
    }
}

struct BookContentDecorationState: Equatable, Sendable {
    struct AnnotationMarker: Equatable, Encodable, Sendable {
        let annotationId: Int64
        let sourceBlockId: Int
    }

    struct ImageMarker: Equatable, Encodable, Sendable {
        let imageId: Int64
        let sourceBlockId: Int
    }

    struct InlineImage: Equatable, Encodable, Sendable {
        let key: String
        let imageId: Int64?
        let sourceBlockId: Int
        let imageURL: String
    }

    struct BridgePayload: Equatable, Encodable, Sendable {
        let annotations: [AnnotationMarker]
        let imageMarkers: [ImageMarker]
        let inlineAIImagesEnabled: Bool
        let inlineImages: [InlineImage]
    }

    struct MarkerPayload: Equatable, Encodable, Sendable {
        let annotations: [AnnotationMarker]
        let imageMarkers: [ImageMarker]

        static let empty = MarkerPayload(annotations: [], imageMarkers: [])
    }

    struct InlineImagePayload: Equatable, Encodable, Sendable {
        let inlineAIImagesEnabled: Bool
        let inlineImages: [InlineImage]

        static let empty = InlineImagePayload(inlineAIImagesEnabled: false, inlineImages: [])
    }

    static let empty = BookContentDecorationState(
        annotationMarkers: [],
        imageMarkers: [],
        inlineAIImagesEnabled: false,
        inlineImages: []
    )

    let annotationMarkers: [AnnotationMarker]
    let imageMarkers: [ImageMarker]
    let inlineAIImagesEnabled: Bool
    let inlineImages: [InlineImage]

    init(
        annotationMarkers: [AnnotationMarker],
        imageMarkers: [ImageMarker],
        inlineAIImagesEnabled: Bool,
        inlineImages: [InlineImage]
    ) {
        self.annotationMarkers = annotationMarkers
        self.imageMarkers = imageMarkers
        self.inlineAIImagesEnabled = inlineAIImagesEnabled
        self.inlineImages = inlineImages
    }

    init(
        annotations: [Annotation],
        images: [GeneratedImage],
        inlineAIImagesEnabled: Bool,
        pendingMarkers: [MarkerInjection],
        pendingImageMarkers: [ImageMarkerInjection]
    ) {
        var seenAnnotationIDs = Set<Int64>()
        var annotationMarkers: [AnnotationMarker] = []
        annotationMarkers.reserveCapacity(annotations.count + pendingMarkers.count)

        for annotation in annotations {
            guard let annotationId = annotation.id,
                  seenAnnotationIDs.insert(annotationId).inserted else {
                continue
            }

            annotationMarkers.append(.init(
                annotationId: annotationId,
                sourceBlockId: annotation.sourceBlockId
            ))
        }

        for marker in pendingMarkers where seenAnnotationIDs.insert(marker.annotationId).inserted {
            annotationMarkers.append(.init(
                annotationId: marker.annotationId,
                sourceBlockId: marker.sourceBlockId
            ))
        }

        var seenImageIDs = Set<Int64>()
        var imageMarkers: [ImageMarker] = []
        imageMarkers.reserveCapacity(images.count + pendingImageMarkers.count)

        for image in images {
            guard let imageId = image.id,
                  seenImageIDs.insert(imageId).inserted else {
                continue
            }

            imageMarkers.append(.init(
                imageId: imageId,
                sourceBlockId: image.sourceBlockId
            ))
        }

        for marker in pendingImageMarkers where seenImageIDs.insert(marker.imageId).inserted {
            imageMarkers.append(.init(
                imageId: marker.imageId,
                sourceBlockId: marker.sourceBlockId
            ))
        }

        let inlineImages: [InlineImage]
        if inlineAIImagesEnabled {
            inlineImages = images.compactMap { image in
                guard image.status == .success else {
                    return nil
                }

                return .init(
                    key: Self.inlineImageKey(for: image),
                    imageId: image.id,
                    sourceBlockId: image.sourceBlockId,
                    imageURL: image.imageURL.absoluteString
                )
            }
        } else {
            inlineImages = []
        }

        self.init(
            annotationMarkers: annotationMarkers,
            imageMarkers: imageMarkers,
            inlineAIImagesEnabled: inlineAIImagesEnabled,
            inlineImages: inlineImages
        )
    }

    var bridgePayload: BridgePayload {
        .init(
            annotations: annotationMarkers,
            imageMarkers: imageMarkers,
            inlineAIImagesEnabled: inlineAIImagesEnabled,
            inlineImages: inlineImages
        )
    }

    var markerPayload: MarkerPayload {
        .init(annotations: annotationMarkers, imageMarkers: imageMarkers)
    }

    var inlineImagePayload: InlineImagePayload {
        .init(
            inlineAIImagesEnabled: inlineAIImagesEnabled,
            inlineImages: inlineImages
        )
    }

    private static func inlineImageKey(for image: GeneratedImage) -> String {
        if let imageId = image.id {
            return "image-\(imageId)"
        }

        return "block-\(image.sourceBlockId)-\(image.imagePath)"
    }
}

struct BookContentViewState: Equatable, Sendable {
    let document: BookContentDocumentState
    let style: BookContentStyleState
    let decorations: BookContentDecorationState
}

struct BookContentDecorationUpdatePlan: Equatable, Sendable {
    let needsMarkerSync: Bool
    let needsInlineImageSync: Bool

    init(previous: BookContentDecorationState, desired: BookContentDecorationState) {
        needsMarkerSync = previous.markerPayload != desired.markerPayload
        needsInlineImageSync = previous.inlineImagePayload != desired.inlineImagePayload
    }
}
