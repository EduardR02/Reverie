import Foundation

enum LibraryPaths {
    private static let readerFolderName = "Reader"

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    static var readerRoot: URL {
        appSupport.appendingPathComponent(readerFolderName, isDirectory: true)
    }

    static var booksDirectory: URL {
        readerRoot.appendingPathComponent("books", isDirectory: true)
    }

    static var coversDirectory: URL {
        readerRoot.appendingPathComponent("covers", isDirectory: true)
    }

    static var publicationsDirectory: URL {
        readerRoot.appendingPathComponent("publications", isDirectory: true)
    }

    static var imagesDirectory: URL {
        readerRoot.appendingPathComponent("images", isDirectory: true)
    }

    static func imagesDirectory(for bookId: Int64) -> URL {
        imagesDirectory.appendingPathComponent("\(bookId)", isDirectory: true)
    }

    static var databaseURL: URL {
        readerRoot.appendingPathComponent("reader.sqlite")
    }

    static func bookURL(for bookId: Int64) -> URL {
        booksDirectory.appendingPathComponent("\(bookId).epub")
    }

    static func publicationDirectory(for bookId: Int64) -> URL {
        publicationsDirectory.appendingPathComponent("\(bookId)", isDirectory: true)
    }

    static func coverURL(for bookId: Int64, fileExtension: String) -> URL {
        let cleanedExtension = fileExtension.isEmpty ? "jpg" : fileExtension
        return coversDirectory.appendingPathComponent("\(bookId).\(cleanedExtension)")
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
