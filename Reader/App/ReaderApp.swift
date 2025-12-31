import SwiftUI
import GRDB

@main
struct ReaderApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .themed()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Book...") {
                    appState.showImportSheet = true
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
                .themed()
        }
    }
}

// MARK: - Main Content Router

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch appState.currentScreen {
            case .home:
                HomeView()
                    .transition(.opacity)
            case .settings:
                SettingsView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .stats:
                StatsView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .reader:
                ReaderView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: appState.currentScreen.hashValue)
        .background(theme.base)
        .preferredColorScheme(.dark)
    }
}

// Make AppScreen hashable for animation
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
