import SwiftUI

@main
struct ReverieApp: App {
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

