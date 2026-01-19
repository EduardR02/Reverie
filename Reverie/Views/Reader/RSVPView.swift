import SwiftUI

/// RSVPView displays a single word with the Optimal Recognition Point (ORP) fixed at the center.
/// Used for Rapid Serial Visual Presentation reading mode.
struct RSVPView: View {
    let word: RSVPWord?          // Current word to display (nil = show placeholder)
    let fontSize: CGFloat        // From settings (rsvpFontSize)
    let progress: Double         // 0.0 to 1.0 for progress bar
    let isPlaying: Bool          // For any play/pause visual indicator
    
    @Environment(\.theme) private var theme
    
    // Using a system monospaced font for perfect alignment stability
    // This is critical for RSVP to prevent eye jitter
    private var font: Font {
        let size = adjustedFontSize
        return .system(size: size, weight: .medium, design: .monospaced)
    }
    
    private var orpFont: Font {
        let size = adjustedFontSize
        return .system(size: size, weight: .bold, design: .monospaced)
    }

    /// Scales down the font size if the word is exceptionally long to prevent extreme overflow.
    private var adjustedFontSize: CGFloat {
        guard let word = word else { return fontSize }
        let length = word.beforeORP.count + 1 + word.afterORP.count
        if length > 15 {
            // Gradually scale down for words longer than 15 chars
            // Min scale 0.6 at 25+ chars
            let scale = max(0.6, 1.0 - CGFloat(length - 15) * 0.04)
            return fontSize * scale
        }
        return fontSize
    }

    var body: some View {
        ZStack {
            // Background
            theme.base
                .contentShape(Rectangle())
            
            // Pivot Guides (Top and Bottom only)
            // A full line can be distracting; guides help focus without cutting the word
            VStack {
                Capsule()
                    .fill(theme.rose.opacity(0.3))
                    .frame(width: 2, height: 12)
                Spacer()
                Capsule()
                    .fill(theme.rose.opacity(0.3))
                    .frame(width: 2, height: 12)
            }
            .frame(maxHeight: fontSize * 3) // Constrain guides to be near the word
            
            // Word Display
            if let word = word {
                GeometryReader { geo in
                    let centerX = geo.size.width / 2
                    let centerY = geo.size.height / 2
                    let charW = adjustedCharWidth
                    
                    // Calculate positions based on character widths
                    let beforeWidth = CGFloat(word.beforeORP.count) * charW
                    let afterWidth = CGFloat(word.afterORP.count) * charW
                    
                    // beforeORP: right edge at (centerX - charW/2), so center at (centerX - charW/2 - beforeWidth/2)
                    let beforeCenterX = centerX - charW / 2 - beforeWidth / 2
                    
                    // afterORP: left edge at (centerX + charW/2), so center at (centerX + charW/2 + afterWidth/2)
                    let afterCenterX = centerX + charW / 2 + afterWidth / 2
                    
                    // Before ORP
                    if !word.beforeORP.isEmpty {
                        Text(word.beforeORP)
                            .font(font)
                            .foregroundColor(theme.text.opacity(0.8))
                            .lineLimit(1)
                            .fixedSize()
                            .position(x: beforeCenterX, y: centerY)
                    }
                    
                    // ORP Character - always at exact center
                    Text(String(word.orpChar))
                        .font(orpFont)
                        .foregroundColor(theme.rose)
                        .lineLimit(1)
                        .fixedSize()
                        .shadow(color: theme.rose.opacity(0.3), radius: 4, x: 0, y: 0)
                        .position(x: centerX, y: centerY)
                    
                    // After ORP
                    if !word.afterORP.isEmpty {
                        Text(word.afterORP)
                            .font(font)
                            .foregroundColor(theme.text.opacity(0.8))
                            .lineLimit(1)
                            .fixedSize()
                            .position(x: afterCenterX, y: centerY)
                    }
                }
            } else {
                Text("Ready")
                    .font(font)
                    .foregroundColor(theme.muted)
                    .lineLimit(1)
                    .tracking(2)
            }
            // Removed animation to ensure word changes are instant and snappy
            
            // Progress Bar (Minimalist)
            VStack {
                Spacer()
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Track
                        Rectangle()
                            .fill(theme.surface)
                            .frame(height: 2)
                        
                        // Indicator
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [theme.rose.opacity(0.7), theme.love],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * progress, height: 2)
                            // Smooth out progress updates
                            .animation(.linear(duration: 0.2), value: progress)
                    }
                }
                .frame(height: 2)
            }
        }
    }
    
    /// Estimates the width of a single character in the chosen monospace font.
    private var adjustedCharWidth: CGFloat {
        // SF Mono width is roughly 0.6 * fontSize.
        return adjustedFontSize * 0.6
    }
}

#Preview {
    VStack(spacing: 20) {
        RSVPView(
            word: RSVPWord(id: 1, text: "reverie", orpIndex: 2, sourceBlockId: 0),
            fontSize: 40,
            progress: 0.4,
            isPlaying: true
        )
        .frame(height: 200)
        
        RSVPView(
            word: RSVPWord(id: 2, text: "exquisite", orpIndex: 2, sourceBlockId: 0),
            fontSize: 40,
            progress: 0.7,
            isPlaying: false
        )
        .frame(height: 200)
        
        RSVPView(
            word: nil,
            fontSize: 40,
            progress: 0.0,
            isPlaying: false
        )
        .frame(height: 200)
    }
    .padding()
}
