
// MARK: - Navigation

enum AppScreen {
    case home
    case settings
    case stats
    case reader(Book)
}

// MARK: - Hashable (for animation)

extension AppScreen: Hashable {
    static func == (lhs: AppScreen, rhs: AppScreen) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home): return true
        case (.settings, .settings): return true
        case (.stats, .stats): return true
        case (.reader(let a), .reader(let b)): return a.id == b.id
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .home: hasher.combine("home")
        case .settings: hasher.combine("settings")
        case .stats: hasher.combine("stats")
        case .reader(let book): hasher.combine("reader-\(book.id ?? 0)")
        }
    }
}
