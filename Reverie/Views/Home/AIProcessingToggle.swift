import SwiftUI

struct AIProcessingToggle: View {
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // The AI Sparkles icon
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 36, height: 36)
                    .foregroundColor(isEnabled ? theme.subtle : theme.love)
                    .overlay {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(theme.foam)
                            .opacity(isEnabled && isHovered ? 1.0 : 0.0)
                    }
                    .animation(isEnabled && isHovered ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .none, value: isHovered)

                // Label
                if !isEnabled {
                    Text("AI Paused")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(theme.love)
                        .padding(.trailing, 12)
                        .fixedSize(horizontal: true, vertical: false)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity
                        ))
                }
            }
            .background(
                Capsule()
                    .fill(isEnabled ? theme.surface : theme.love.opacity(0.08))
            )
            .overlay {
                Capsule()
                    .stroke(isEnabled ? Color.clear : theme.love.opacity(0.15), lineWidth: 1)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            // Applying animation to the container ensures all layout changes (HStack width, transition) are captured
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: isEnabled)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeIn(duration: 0.1), value: isHovered)
        .help(isEnabled ? "AI processing is active" : "AI processing is paused")
    }
}
