import SwiftUI
import AppKit

/// Authentication selection is persisted by SettingsView; secrets remain in the auth actor/Keychain.
@MainActor
struct OpenAISubscriptionSection: View {
    @Binding var authenticationMode: OpenAIAuthenticationMode
    @Environment(\.theme) private var theme
    @State private var connected = OpenAISubscriptionAuth.isConnected
    @State private var loginTask: Task<Void, Never>?
    @State private var signingOut = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenAI Access")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.text)

            ThemedSegmentedPicker(selection: $authenticationMode, options: OpenAIAuthenticationMode.allCases)

            if authenticationMode == .apiKey {
                Text("API-key access is billed separately to your OpenAI Platform account. Selecting a ChatGPT subscription never falls back to your API key.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
            } else {
                Text("Use Codex access included with an eligible ChatGPT plan. Your plan’s model availability and usage limits apply. This does not provide general OpenAI API credits.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Image(systemName: connected ? "checkmark.circle.fill" : "person.crop.circle")
                        .foregroundColor(connected ? theme.foam : theme.muted)
                    Text(connected ? "ChatGPT connected" : "Not signed in")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.text)
                    Spacer()
                    if connected {
                        Button("Sign Out", action: signOut)
                            .disabled(signingOut || loginTask != nil)
                    } else if loginTask == nil {
                        Button("Sign In with ChatGPT", action: signIn)
                            .disabled(signingOut)
                    }
                }

                if loginTask != nil {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Complete sign-in in your browser. Reverie will connect automatically.")
                            .font(.system(size: 12))
                            .foregroundColor(theme.subtle)
                        Spacer()
                        Button("Cancel", action: cancelSignIn)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(theme.love)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("ChatGPT sign-in error: \(errorMessage)")
                }

                Text("Tokens are stored only in the macOS Keychain. Signing out removes Reverie’s saved session; it does not sign out your browser or other apps.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: authenticationMode) { _, mode in
            if mode != .chatGPTSubscription { cancelSignIn() }
        }
        .onDisappear { cancelSignIn() }
    }

    private func signIn() {
        errorMessage = nil
        loginTask = Task { @MainActor in
            defer { loginTask = nil }
            do {
                try await OpenAISubscriptionAuth.shared.signIn(openURL: { url in
                    try await MainActor.run {
                        try Task.checkCancellation()
                        guard NSWorkspace.shared.open(url) else {
                            throw OpenAISubscriptionAuthError.browserUnavailable
                        }
                    }
                })
                try Task.checkCancellation()
                connected = true
                NSApplication.shared.activate(ignoringOtherApps: true)
            } catch is CancellationError {
                // Cancellation is an explicit user action, not a sign-in failure.
            } catch {
                // Auth exposes only fixed, redacted errors, never server response text.
                errorMessage = (error as? OpenAISubscriptionAuthError)?.errorDescription
                    ?? "ChatGPT sign-in could not be completed. Try again."
                connected = OpenAISubscriptionAuth.isConnected
            }
        }
    }

    private func cancelSignIn() {
        loginTask?.cancel()
    }

    private func signOut() {
        errorMessage = nil
        signingOut = true
        Task { @MainActor in
            defer { signingOut = false }
            do {
                try await OpenAISubscriptionAuth.shared.signOut()
                connected = false
            } catch {
                connected = OpenAISubscriptionAuth.isConnected
                errorMessage = (error as? OpenAISubscriptionAuthError)?.errorDescription
                    ?? "The saved ChatGPT session could not be removed from Keychain."
            }
        }
    }
}
