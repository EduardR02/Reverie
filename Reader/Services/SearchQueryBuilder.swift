import Foundation

enum SearchQueryBuilder {
    static func deterministicQuery(
        insightTitle: String,
        insightContent: String,
        bookTitle: String,
        author: String
    ) -> String {
        let stopWords: Set<String> = ["a", "an", "the", "and", "or", "but", "if", "then", "else", "when", "at", "from", "by", "for", "with", "about", "against", "between", "into", "through", "during", "before", "after", "above", "below", "to", "in", "on", "of", "is", "are", "was", "were", "be", "been", "being"]
        
        func cleanAndFilter(_ text: String) -> [String] {
            let components = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty && !stopWords.contains($0) }
            return components
        }
        
        let titleTerms = cleanAndFilter(insightTitle)
        let contentTerms = cleanAndFilter(insightContent)
        let bookTerms = cleanAndFilter(bookTitle)
        let authorTerms = cleanAndFilter(author)
        
        // Take up to 3 terms from title, 2 from content, 2 from book, 1 from author
        let selectedTerms = titleTerms.prefix(3) + contentTerms.prefix(2) + bookTerms.prefix(2) + authorTerms.prefix(1)
        
        let query = selectedTerms.joined(separator: " ")
        return query.isEmpty ? insightTitle : query
    }
    
    static func searchURL(for query: String) -> URL? {
        let cleaned = validateQuery(query)
        guard !cleaned.isEmpty else { return nil }
        
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: cleaned)]
        return components?.url
    }

    static func validateQuery(_ query: String) -> String {
        var cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove surrounding quotes if model included them
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") {
            cleaned = String(cleaned.dropFirst().dropLast())
        } else if cleaned.hasPrefix("'") && cleaned.hasSuffix("'") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
