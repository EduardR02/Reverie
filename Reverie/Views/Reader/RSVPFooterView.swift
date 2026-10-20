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
        GeometryReader { geometry in
            let compact = geometry.size.width < 440
            HStack(spacing: 8) {
                leftSection(compact: compact)
                Spacer(minLength: 0)
                centerSection
                Spacer(minLength: 0)
                rightSection(compact: compact)
            }
            .padding(.horizontal, ReaderMetrics.footerHorizontalPadding)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: ReaderMetrics.footerHeight)
        // Use a material-like background for the footer to give it depth
        .background(theme.surface.opacity(0.95))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.highlightLow.opacity(0.5))
                .frame(height: 1)
        }
    }
    
    private func leftSection(compact: Bool) -> some View {
        HStack(spacing: 0) {
            // Mode Toggle - styled like a segmented control
            HStack(spacing: 0) {
                modeButton(title: "Scroll", icon: "scroll", isActive: !isRSVPMode, compact: compact) {
                    withAnimation(.spring(response: 0.3)) { isRSVPMode = false }
                }
                
                Divider()
                    .frame(height: 16)
                    .background(theme.highlightLow)
                
                modeButton(title: "RSVP", icon: "text.alignleft", isActive: isRSVPMode, compact: compact) {
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
    
    private func modeButton(title: String, icon: String, isActive: Bool, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: isActive ? .bold : .regular))
                
                if !compact {
                    Text(title)
                        .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                        .lineLimit(1)
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
        .accessibilityLabel(title)
        .help(title)
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
    
    private func rightSection(compact: Bool) -> some View {
        Button(action: onTogglePlay) {
            Group {
                if compact {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32)
                } else {
                HStack(spacing: 8) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    
                    Text(isPlaying ? "Pause" : "Read")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 16)
                }
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
        .accessibilityLabel(isPlaying ? "Pause reading" : "Start reading")
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
