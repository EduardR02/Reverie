import SwiftUI

// MARK: - ThemedToggle

struct ThemedToggle: View {
    @Binding var isOn: Bool
    var label: String? = nil
    var subtitle: String? = nil
    
    @Environment(\.theme) private var theme
    
    var body: some View {
        HStack(spacing: 12) {
            if let label = label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.text)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(theme.muted)
                    }
                }
            }
            
            Spacer()
            
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isOn.toggle()
                }
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? theme.iris : theme.highlightMed)
                        .frame(width: 36, height: 20)
                    
                    Circle()
                        .fill(theme.text)
                        .padding(2)
                        .frame(width: 20, height: 20)
                        .shadow(radius: 1, y: 1)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isOn.toggle()
            }
        }
    }
}

// MARK: - ThemedPicker

struct ThemedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(id: T, name: String)]
    
    @Environment(\.theme) private var theme
    @State private var isHovering = false
    
    var body: some View {
        Menu {
            ForEach(options, id: \.id) { option in
                Button {
                    selection = option.id
                } label: {
                    HStack {
                        Text(option.name)
                        if selection == option.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(options.first(where: { $0.id == selection })?.name ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.text)
                
                Spacer()
                
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.subtle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovering ? theme.overlay : theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovering ? theme.subtle.opacity(0.5) : theme.overlay, lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.2), value: isHovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - ThemedSegmentedPicker

struct ThemedSegmentedPicker<T: Hashable & CustomStringConvertible>: View {
    @Binding var selection: T
    let options: [T]
    
    @Environment(\.theme) private var theme
    @Namespace private var pickerNamespace
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                SegmentedPickerButton(
                    option: option,
                    isSelected: selection == option,
                    namespace: pickerNamespace
                ) {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                        selection = option
                    }
                }
            }
        }
        .padding(2)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.overlay, lineWidth: 1)
        )
    }
}

private struct SegmentedPickerButton<T: CustomStringConvertible>: View {
    let option: T
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    
    @Environment(\.theme) private var theme
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                // Invisible text to reserve layout space for the bold font weight
                Text(option.description)
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0)
                    .frame(height: 16)
                
                // Visible text
                Text(option.description)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? theme.text : (isHovering ? theme.text : theme.subtle))
                    .frame(height: 16)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.highlightMed)
                            .matchedGeometryEffect(id: "picker_selection", in: namespace)
                            .shadow(color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1)
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.overlay.opacity(0.5))
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - ThemedSlider

struct ThemedSlider<L: View>: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double = 0.01
    var onEditingChanged: ((Double) -> Void)?
    let label: (Double) -> L
    
    @Environment(\.theme) private var theme
    @State private var localValue: Double?
    @State private var isHovering = false
    @State private var isDragging = false
    
    init(
        value: Binding<Double>,
        range: ClosedRange<Double> = 0...1,
        step: Double = 0.01,
        onEditingChanged: ((Double) -> Void)? = nil,
        @ViewBuilder label: @escaping (Double) -> L
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
        self.label = label
    }
    
    private var displayValue: Double {
        localValue ?? value
    }
    
    var body: some View {
        VStack(spacing: 8) {
            label(displayValue)
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(theme.muted.opacity(0.3))
                        .frame(height: 4)
                    
                    // Active Track
                    Capsule()
                        .fill(theme.iris)
                        .frame(width: max(0, min(geometry.size.width, CGFloat((displayValue - range.lowerBound) / (range.upperBound - range.lowerBound)) * geometry.size.width)), height: 4)
                    
                    // Thumb
                    Circle()
                        .fill(theme.text)
                        .frame(width: 16, height: 16)
                        .shadow(color: Color.black.opacity(0.1), radius: 2, y: 1)
                        .overlay(
                            Circle()
                                .stroke(theme.base, lineWidth: 1)
                        )
                        .scaleEffect(isDragging || isHovering ? 1.1 : 1.0)
                        .animation(.spring(response: 0.2), value: isDragging || isHovering)
                        .offset(x: max(0, min(geometry.size.width - 16, CGFloat((displayValue - range.lowerBound) / (range.upperBound - range.lowerBound)) * geometry.size.width - 8)))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { gesture in
                                    isDragging = true
                                    let percent = Double(gesture.location.x / geometry.size.width)
                                    let newValue = range.lowerBound + (range.upperBound - range.lowerBound) * percent
                                    let rounded = min(max(range.lowerBound, newValue.rounded(to: step)), range.upperBound)
                                    
                                    if localValue != rounded {
                                        localValue = rounded
                                        onEditingChanged?(rounded)
                                    }
                                }
                                .onEnded { _ in
                                    isDragging = false
                                    if let finalValue = localValue {
                                        value = finalValue
                                    }
                                    localValue = nil
                                }
                        )
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
            }
            .frame(height: 20)
        }
    }
}

extension ThemedSlider where L == EmptyView {
    init(
        value: Binding<Double>,
        range: ClosedRange<Double> = 0...1,
        step: Double = 0.01,
        onEditingChanged: ((Double) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.onEditingChanged = onEditingChanged
        self.label = { _ in EmptyView() }
    }
}

private extension Double {
    func rounded(to step: Double) -> Double {
        (self / step).rounded() * step
    }
}

// MARK: - ThemedSecureField

struct ThemedSecureField: View {
    let placeholder: String
    @Binding var text: String
    
    @Environment(\.theme) private var theme
    
    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 14, design: .monospaced))
            .padding(12)
            .background(theme.base)
            .foregroundColor(theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.overlay, lineWidth: 1)
            )
    }
}
