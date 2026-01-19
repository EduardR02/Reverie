import SwiftUI

struct RSVPFooterView: View {
    @Binding var isRSVPMode: Bool           // Toggle between RSVP and autoscroll
    @Binding var isPlaying: Bool            // Play/pause state
    let wpm: Double                         // Current WPM
    let onWPMIncrement: () -> Void
    let onWPMDecrement: () -> Void
    let onWPMSet: (Double) -> Void
    let onTogglePlay: () -> Void
    
    @Environment(\.theme) private var theme
    
    @State private var wpmText: String = ""
    @FocusState private var isFocused: Bool
    
    private let minWPM = 50.0
    private let maxWPM = 2000.0
    private let defaultWPM = 300.0
    
    var body: some View {
        HStack(spacing: 0) {
            // Left section - RSVP Toggle
            leftSection
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Center section - WPM Controls
            centerSection
                .frame(maxWidth: .infinity, alignment: .center)
            
            // Right section - Play/Pause
            rightSection
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, ReaderMetrics.footerHorizontalPadding)
        .frame(height: ReaderMetrics.footerHeight)
        // Use a material-like background for the footer to give it depth
        .background(theme.surface.opacity(0.95))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.highlightLow.opacity(0.5))
                .frame(height: 1)
        }
    }
    
    private var leftSection: some View {
        HStack(spacing: 0) {
            // Mode Toggle - styled like a segmented control
            HStack(spacing: 0) {
                modeButton(title: "Scroll", icon: "scroll", isActive: !isRSVPMode) {
                    withAnimation(.spring(response: 0.3)) { isRSVPMode = false }
                }
                
                Divider()
                    .frame(height: 16)
                    .background(theme.highlightLow)
                
                modeButton(title: "RSVP", icon: "text.alignleft", isActive: isRSVPMode) {
                    withAnimation(.spring(response: 0.3)) { isRSVPMode = true }
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.overlay.opacity(0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.highlightLow, lineWidth: 0.5)
            )
        }
    }
    
    private func modeButton(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Fix for Issue 1: Avoid using non-existent text.alignleft.fill
                // Differentiate by color and weight instead of .fill for this specific symbol
                Image(systemName: icon)
                    .font(.system(size: 10, weight: isActive ? .bold : .regular))
                
                ViewThatFits(in: .horizontal) {
                    Text(title)
                        .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    
                    EmptyView()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundColor(isActive ? theme.text : theme.muted)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? theme.surface : Color.clear)
                    .shadow(color: Color.black.opacity(isActive ? 0.1 : 0), radius: 1, y: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var centerSection: some View {
        HStack(spacing: 4) {
            // Decrease
            controlButton(icon: "minus") {
                onWPMDecrement()
            }
            
            // Display
            ViewThatFits(in: .horizontal) {
                VStack(spacing: 0) {
                    TextField("", text: $wpmText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(theme.text)
                        .frame(width: 50)
                        .focused($isFocused)
                        .onSubmit { applyWPM() }
                        .onChange(of: isFocused) { _, focused in
                            if !focused { applyWPM() }
                        }
                    
                    Text("WPM")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.muted)
                        .tracking(1)
                }
                .frame(width: 60)
                
                // Narrower version
                TextField("", text: $wpmText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(theme.text)
                    .frame(width: 40)
                    .focused($isFocused)
                    .onSubmit { applyWPM() }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { applyWPM() }
                    }
            }
            .onChange(of: wpm) { _, newValue in
                if !isFocused {
                    wpmText = "\(Int(newValue))"
                }
            }
            .onAppear {
                wpmText = "\(Int(wpm))"
            }
            
            // Increase
            controlButton(icon: "plus") {
                onWPMIncrement()
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(theme.overlay.opacity(0.2))
        )
    }
    
    private func applyWPM() {
        if wpmText.isEmpty {
            wpmText = "\(Int(defaultWPM))"
            onWPMSet(defaultWPM)
            return
        }
        
        // Filter out non-digits
        let filtered = wpmText.filter { $0.isNumber }
        if let newValue = Double(filtered) {
            let clamped = max(minWPM, min(maxWPM, newValue))
            onWPMSet(clamped)
            wpmText = "\(Int(clamped))"
        } else {
            // Revert if invalid
            wpmText = "\(Int(wpm))"
        }
    }
    
    private func controlButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(theme.surface)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.text)
                )
                .shadow(color: Color.black.opacity(0.05), radius: 1, y: 1)
        }
        .buttonStyle(PlainButtonStyle()) // Simple press effect
    }
    
    private var rightSection: some View {
        Button(action: onTogglePlay) {
            ViewThatFits(in: .horizontal) {
                // Full version
                HStack(spacing: 8) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    
                    Text(isPlaying ? "Pause" : "Read")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 16)
                
                // Icon only version for small sizes
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32)
            }
            .foregroundColor(isPlaying ? theme.base : theme.text)
            .frame(height: 32)
            .background(
                Capsule()
                    .fill(isPlaying ? theme.rose : theme.highlightMed)
            )
            .shadow(color: (isPlaying ? theme.rose : theme.highlightMed).opacity(0.3), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack {
        Spacer()
        RSVPFooterView(
            isRSVPMode: .constant(false),
            isPlaying: .constant(false),
            wpm: 300,
            onWPMIncrement: {},
            onWPMDecrement: {},
            onWPMSet: { _ in },
            onTogglePlay: {}
        )
        .themed()
        
        RSVPFooterView(
            isRSVPMode: .constant(true),
            isPlaying: .constant(true),
            wpm: 450,
            onWPMIncrement: {},
            onWPMDecrement: {},
            onWPMSet: { _ in },
            onTogglePlay: {}
        )
        .themed()
        
        RSVPFooterView(
            isRSVPMode: .constant(true),
            isPlaying: .constant(true),
            wpm: 450,
            onWPMIncrement: {},
            onWPMDecrement: {},
            onWPMSet: { _ in },
            onTogglePlay: {}
        )
        .themed()
        Spacer()
    }
    .background(Color.black)
    .frame(width: 400, height: 200)
}
