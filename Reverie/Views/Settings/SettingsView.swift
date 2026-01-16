import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var selectedSection: SettingsSection = .intelligence
    @State private var hoveredSection: SettingsSection?
    @State private var hoveredTheme: String?
    @State private var hoveredBackButton = false
    @State private var themeImportText: String = ""
    @State private var themeImportError: String?
    
    // Preview states for smooth updates without persistence spam
    @State private var previewFontSize: Double?
    @State private var previewLineSpacing: Double?

    enum SettingsSection: String, CaseIterable {
        case intelligence = "Intelligence"
        case reading = "Reading"
        case media = "Media"
        case appearance = "Appearance"
        case apiKeys = "API Keys"

        var icon: String {
            switch self {
            case .intelligence: return "brain"
            case .reading: return "book.closed"
            case .media: return "photo.on.rectangle"
            case .appearance: return "paintbrush"
            case .apiKeys: return "key"
            }
        }
    }

    var body: some View {
        ZStack {
            theme.base.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                settingsHeader

                // Content
                HStack(spacing: 0) {
                    // Sidebar
                    sidebar
                        .frame(width: 250) // More breathing room for "Intelligence"

                    // Divider
                    Rectangle()
                        .fill(theme.overlay)
                        .frame(width: 1)

                    // Content
                    ScrollView {
                        VStack(spacing: 32) { // Increased vertical rhythm
                            switch selectedSection {
                            case .intelligence:
                                intelligenceSection
                            case .reading:
                                readingSection
                            case .media:
                                mediaSection
                            case .appearance:
                                appearanceSection
                            case .apiKeys:
                                apiKeysSection
                            }
                        }
                        .padding(40) // More generous padding
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Header

    private var settingsHeader: some View {
        HStack {
            Button {
                appState.goHome()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold)) 
                    Text("Library")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.subtle)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(hoveredBackButton ? theme.surface : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered in
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                    hoveredBackButton = hovered
                }
            }

            Spacer()

            Text("Settings")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.text)
                .frame(maxWidth: .infinity)
                .padding(.trailing, 100) // Visual centering compensation

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(height: 64)
        .background(theme.base.opacity(0.8)) // Glass-like effect base
        .overlay(
            Rectangle()
                .fill(theme.overlay.opacity(0.5))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsSection.allCases, id: \.self) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedSection = section
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: section.icon)
                            .font(.system(size: 15))
                            .foregroundColor(selectedSection == section ? theme.rose : theme.muted)
                            .frame(width: 24)

                        Text(section.rawValue)
                            .font(.system(size: 14, weight: selectedSection == section ? .semibold : .medium))
                            .foregroundColor(selectedSection == section ? theme.text : theme.subtle)
                            .lineLimit(1) // Prevent wrapping

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        ZStack {
                            if selectedSection == section {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.surface)
                                    .shadow(color: Color.black.opacity(0.05), radius: 2, y: 1)
                                    
                                // Left accent border for selection
                                HStack {
                                    Rectangle()
                                        .fill(theme.rose)
                                        .frame(width: 3)
                                        .cornerRadius(1.5)
                                        .padding(.vertical, 6)
                                    Spacer()
                                }
                            } else if hoveredSection == section {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.highlightLow)
                            }
                        }
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                        hoveredSection = hovering ? section : nil
                    }
                }
            }

            Spacer()
        }
        .padding(16)
    }

    // MARK: - Intelligence Section

    private var intelligenceSection: some View {
        @Bindable var state = appState

        return VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Models", icon: "cpu", isFirst: true)

            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("LLM Provider")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)

                            ThemedSegmentedPicker(
                                selection: $state.settings.llmProvider,
                                options: LLMProvider.allCases
                            )
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Model")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)

                            ThemedPicker(
                                selection: $state.settings.llmModel,
                                options: state.settings.llmProvider.models.map { ($0.id, $0.name) }
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            sectionHeader("Insight Analysis", icon: "lightbulb")

            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Density")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.muted)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Controls how many insights are generated per chapter.")
                                .font(.system(size: 12))
                            Text("Density is highly model-dependent—one model may interpret 'Medium' as more or less dense than another. We recommend fine-tuning this setting for your active model to ensure the best results.")
                                .font(.system(size: 11))
                                .italic()
                        }
                        .foregroundColor(theme.subtle)
                    }

                    HStack(spacing: 8) {
                        ForEach(DensityLevel.allCases, id: \.self) { level in
                            Button {
                                withAnimation(.spring(duration: 0.2)) {
                                    state.settings.insightDensity = level
                                }
                            } label: {
                                Text(level.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(state.settings.insightDensity == level ? theme.base : theme.text)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(state.settings.insightDensity == level ? theme.rose : theme.overlay)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reasoning Depth")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.muted)
                        
                        Text("Higher levels produce deeper analysis but are slower")
                            .font(.system(size: 12))
                            .foregroundColor(theme.subtle)
                    }

                    VStack(spacing: 12) {
                        HStack {
                            Text("Insights")
                                .font(.system(size: 13))
                                .foregroundColor(theme.text)
                                .frame(width: 70, alignment: .leading)

                            ThemedSegmentedPicker(
                                selection: $state.settings.insightReasoningLevel,
                                options: ReasoningLevel.allCases
                            )
                        }

                        HStack {
                            Text("Chat")
                                .font(.system(size: 13))
                                .foregroundColor(theme.text)
                                .frame(width: 70, alignment: .leading)

                            ThemedSegmentedPicker(
                                selection: $state.settings.chatReasoningLevel,
                                options: ReasoningLevel.allCases
                            )
                        }
                    }

                    Divider().background(theme.overlay)

                    ThemedToggle(
                        isOn: $state.settings.webSearchEnabled,
                        label: "Web Search",
                        subtitle: "Allow models to search the web for external context"
                    )
                }
            }

            sectionHeader("Parameters", icon: "slider.horizontal.3")

            settingsCard {
                VStack(spacing: 24) {
                    ThemedSlider(
                        value: $state.settings.temperature,
                        range: 0.0...2.0,
                        step: 0.1
                    ) { val in
                        HStack {
                            Text("Temperature")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)

                            Spacer()
                            
                            Text(String(format: "%.1f", val))
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(theme.text)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(minWidth: 48)
                                .background(theme.overlay)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Divider().background(theme.overlay)
                    
                    #if DEBUG
                    ThemedToggle(
                        isOn: $state.settings.useSimulationMode,
                        label: "Simulation Mode",
                        subtitle: "Test processing UI without using actual tokens"
                    )
                    
                    Divider().background(theme.overlay)
                    #endif

                    ThemedSlider(
                        value: Binding(
                            get: { Double(state.settings.maxConcurrentRequests) },
                            set: { state.settings.maxConcurrentRequests = Int($0) }
                        ),
                        range: 1.0...10.0,
                        step: 1.0
                    ) { val in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Concurrency Limit")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(theme.muted)
                                Text("Maximum simultaneous LLM and image requests per provider")
                                    .font(.system(size: 11))
                                    .foregroundColor(theme.subtle)
                            }

                            Spacer()
                            
                            Text("\(Int(val))")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(theme.text)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(minWidth: 48)
                                .background(theme.overlay)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
        }
        .onChange(of: state.settings.llmProvider) { _, _ in
            state.settings.llmModel = state.settings.llmProvider.models.first?.id ?? ""
            state.settings.save()
        }
        .onChange(of: state.settings) { _, _ in
            state.settings.save()
        }
    }

    // MARK: - Reading Section

    private var readingSection: some View {
        @Bindable var state = appState

        return VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Automation", icon: "wand.and.stars", isFirst: true)

            settingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    ThemedToggle(
                        isOn: $state.settings.autoSwitchToQuiz,
                        label: "Quiz Auto-open",
                        subtitle: "Tug past chapter end to open quiz"
                    )
                    .padding(.vertical, 12)

                    Divider().background(theme.overlay)

                    ThemedToggle(
                        isOn: $state.settings.autoSwitchContextTabs,
                        label: "Context Auto-follow",
                        subtitle: "Tabs follow your scroll position"
                    )
                    .padding(.vertical, 12)

                    Divider().background(theme.overlay)

                    ThemedToggle(
                        isOn: $state.settings.autoScrollHighlightEnabled,
                        label: "Auto-scroll Highlighting",
                        subtitle: "Auto-selects insights as you scroll through the book"
                    )
                    .padding(.vertical, 12)

                    Divider().background(theme.overlay)

                    ThemedToggle(
                        isOn: $state.settings.activeContentBorderEnabled,
                        label: "Active Content Border",
                        subtitle: "Highlight border of active insights and images"
                    )
                    .padding(.vertical, 12)

                    Divider().background(theme.overlay)

                    ThemedToggle(
                        isOn: $state.settings.autoSwitchFromChatOnScroll,
                        label: "Smart Chat Return",
                        subtitle: "Back to context when scrolling text"
                    )
                    .padding(.vertical, 12)
                }
            }

            sectionHeader("Stats & Movement", icon: "chart.bar")

            settingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    ThemedToggle(
                        isOn: $state.settings.smartAutoScrollEnabled,
                        label: "Smart Auto-Scroll",
                        subtitle: "Auto-scrolls the reader based on your reading speed"
                    )
                    .padding(.vertical, 12)

                    Divider().background(theme.overlay)

                    ThemedToggle(
                        isOn: $state.settings.showReadingSpeedFooter,
                        label: "Reading Speed",
                        subtitle: "Show average speed in footer"
                    )
                    .padding(.vertical, 12)
                }
            }

            sectionHeader("Interface", icon: "macwindow")

            settingsCard {
                ThemedSlider(
                    value: Binding(
                        get: { Double(state.splitRatio) },
                        set: { state.splitRatio = CGFloat($0) }
                    ),
                    range: 0.5...0.8,
                    step: 0.01
                ) { val in
                    let readerPercent = Int((val * 100).rounded())
                    let aiPercent = max(0, 100 - readerPercent)
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reader / AI Split")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)
                            Text("Default divider position")
                                .font(.system(size: 11))
                                .foregroundColor(theme.subtle)
                        }

                        Spacer()

                        Text("\(readerPercent)% / \(aiPercent)%")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.text)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(minWidth: 80)
                            .background(theme.overlay)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
        .onChange(of: state.settings) { _, _ in
            state.settings.save()
        }
    }

    private func toggleLabel(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.text)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(theme.muted)
        }
    }

    // MARK: - Media Section

    private var mediaSection: some View {
        @Bindable var state = appState

        return VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Image Generation", icon: "photo.stack", isFirst: true)

            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    ThemedToggle(
                        isOn: $state.settings.imagesEnabled,
                        label: "Enable AI Images",
                        subtitle: "Generate illustrations for scenes"
                    )

                    if state.settings.imagesEnabled {
                        Divider().background(theme.overlay)

                        ThemedToggle(
                            isOn: $state.settings.inlineAIImages,
                            label: "Inline in Text",
                            subtitle: "Show images directly inside the chapter"
                        )

                        Divider().background(theme.overlay)

                        ThemedToggle(
                            isOn: $state.settings.rewriteImageExcerpts,
                            label: "Prompt Refinement",
                            subtitle: "Rewrite excerpts into detailed image prompts"
                        )
                    }
                }
            }

            if state.settings.imagesEnabled {
                sectionHeader("Generation Settings", icon: "gearshape")

                settingsCard {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Image Model")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)

                            ThemedSegmentedPicker(
                                selection: $state.settings.imageModel,
                                options: ImageModel.allCases
                            )
                            
                            Text(state.settings.imageModel.detailDescription)
                                .font(.system(size: 11))
                                .foregroundColor(theme.subtle)
                        }

                        Divider().background(theme.overlay)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Image Density")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)

                            HStack(spacing: 6) {
                                ForEach(DensityLevel.allCases, id: \.self) { level in
                                    Button {
                                        withAnimation(.spring(duration: 0.2)) {
                                            state.settings.imageDensity = level
                                        }
                                    } label: {
                                        Text(level.rawValue)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(state.settings.imageDensity == level ? theme.base : theme.text)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(state.settings.imageDensity == level ? theme.rose : theme.overlay)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: state.settings) { _, _ in
            state.settings.save()
        }
    }

    // MARK: - API Keys Section

    private var apiKeysSection: some View {
        @Bindable var state = appState

        return VStack(alignment: .leading, spacing: 24) {
            sectionHeader("API Keys", icon: "key.fill", isFirst: true)

            Text("Your API keys are stored locally and never sent anywhere except to the respective AI providers.")
                .font(.system(size: 13))
                .foregroundColor(theme.muted)

            // Google
            apiKeyCard(
                title: "Gemini",
                subtitle: "For Gemini 3 and image generation",
                key: $state.settings.googleAPIKey,
                linkURL: "https://aistudio.google.com/apikey",
                linkText: "Get API Key"
            )

            // OpenAI
            apiKeyCard(
                title: "OpenAI",
                subtitle: "For GPT 5.2",
                key: $state.settings.openAIAPIKey,
                linkURL: "https://platform.openai.com/api-keys",
                linkText: "Get API Key"
            )

            // Anthropic
            apiKeyCard(
                title: "Claude",
                subtitle: "For Claude 4.5",
                key: $state.settings.anthropicAPIKey,
                linkURL: "https://console.anthropic.com/settings/keys",
                linkText: "Get API Key"
            )
        }
        .onChange(of: state.settings) { _, _ in
            state.settings.save()
        }
        .onChange(of: state.splitRatio) { _, _ in
            state.saveSplitRatio()
        }
    }

    private func apiKeyCard(
        title: String,
        subtitle: String,
        key: Binding<String>,
        linkURL: String,
        linkText: String
    ) -> some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.text)
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(theme.muted)
                    }

                    Spacer()

                    if !key.wrappedValue.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(theme.foam)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: key.wrappedValue.isEmpty)

                ThemedSecureField(placeholder: "Enter API key...", text: key)

                Link(destination: URL(string: linkURL)!) {
                    HStack(spacing: 4) {
                        Text(linkText)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.rose)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        @Bindable var state = appState

        let fonts = [
            "SF Pro Text",
            "SF Pro Display",
            "New York",
            "Georgia",
            "Palatino",
            "Charter",
            "Helvetica Neue",
            "Avenir Next"
        ]

        return VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Theme", icon: "circle.lefthalf.filled", isFirst: true)

            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    let themeGalleryURL = URL(string: "https://windowsterminalthemes.dev/")!

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(ThemeManager.shared.availableThemes, id: \.name) { theme in
                            let isCustom = ThemeManager.shared.isCustomTheme(name: theme.name)
                            themeOption(
                                theme,
                                isSelected: state.settings.theme == theme.name,
                                isDeletable: isCustom,
                                onSelect: {
                                    state.settings.theme = theme.name
                                    ThemeManager.shared.setTheme(theme.name)
                                },
                                onDelete: {
                                    ThemeManager.shared.removeCustomTheme(name: theme.name)
                                    if state.settings.theme == theme.name {
                                        state.settings.theme = ThemeManager.shared.defaultThemeName
                                        ThemeManager.shared.setTheme(state.settings.theme)
                                    }
                                }
                            )
                        }
                    }

                    Divider().overlay(theme.overlay)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Add Custom Theme")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)

                            Spacer()

                            Link(destination: themeGalleryURL) {
                                HStack(spacing: 4) {
                                    Image(systemName: "link")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("windowsterminalthemes.dev")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .contentShape(Rectangle())
                            }
                            .foregroundColor(theme.subtle)
                            .buttonStyle(.plain)
                            .help("Open theme gallery")

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(themeGalleryURL.absoluteString, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(theme.iris)
                                    .frame(width: 22, height: 22)
                                    .padding(4)
                                    .background(theme.overlay)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Copy link")
                        }

                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $themeImportText)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(theme.text)
                                .scrollContentBackground(.hidden)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                                .background(theme.base)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.overlay, lineWidth: 1)
                                )

                            if themeImportText.isEmpty {
                                Text("Paste theme JSON here...")
                                    .font(.system(size: 12))
                                    .foregroundColor(theme.muted)
                                    .padding(.horizontal, 13)  // Match TextEditor padding
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(height: 140)

                        HStack(spacing: 12) {
                            Button("Paste") {
                                if let pasted = NSPasteboard.general.string(forType: .string) {
                                    themeImportText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle())

                            Spacer()

                            Button("Add Theme") {
                                let raw = themeImportText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !raw.isEmpty else {
                                    themeImportError = "Paste a theme JSON block to add a custom theme."
                                    return
                                }

                                do {
                                    let addedTheme = try ThemeManager.shared.addCustomTheme(from: raw)
                                    themeImportText = ""
                                    themeImportError = nil
                                    state.settings.theme = addedTheme.name
                                    ThemeManager.shared.setTheme(addedTheme.name)
                                } catch {
                                    themeImportError = error.localizedDescription
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }

                        if let error = themeImportError {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundColor(theme.love)
                        }
                    }
                }
            }

            sectionHeader("Typography", icon: "textformat")

            settingsCard {
                VStack(alignment: .leading, spacing: 20) {
                    // Font family
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Font Family")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.muted)

                        ThemedPicker(
                            selection: $state.settings.fontFamily,
                            options: fonts.map { ($0, $0) }
                        )
                    }

                    Divider().overlay(theme.overlay)

                    // Font size
                    ThemedSlider(
                        value: Binding(
                            get: { Double(state.settings.fontSize) },
                            set: { state.settings.fontSize = CGFloat($0) }
                        ),
                        range: 12...36,
                        step: 1,
                        onEditingChanged: { previewFontSize = $0 }
                    ) { val in
                        HStack {
                            Text("Font Size")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)
                            Spacer()
                            Text("\(Int(val))px")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(theme.text)
                                .frame(minWidth: 48, alignment: .trailing)
                        }
                    }

                    Divider().overlay(theme.overlay)

                    // Line spacing
                    ThemedSlider(
                        value: Binding(
                            get: { Double(state.settings.lineSpacing) },
                            set: { state.settings.lineSpacing = CGFloat($0) }
                        ),
                        range: 1.0...2.5,
                        step: 0.1,
                        onEditingChanged: { previewLineSpacing = $0 }
                    ) { val in
                        HStack {
                            Text("Line Spacing")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)
                            Spacer()
                            Text(String(format: "%.1f", val))
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(theme.text)
                                .frame(minWidth: 48, alignment: .trailing)
                        }
                    }
                }
            }

            sectionHeader("Preview", icon: "eye")

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    let fontSize = CGFloat(previewFontSize ?? Double(state.settings.fontSize))
                    let lineSpacing = CGFloat(previewLineSpacing ?? Double(state.settings.lineSpacing))
                    
                    Text("""
                    The garden stretched out before her, a tapestry of colors and scents that shifted with the breeze. She followed the narrow path past the hedges, where the light thinned and the air turned cool.

                    At the far end, a stone bench waited beneath the old oak. She sat, opened the book, and let the words settle into a steady rhythm that carried her deeper into the story.
                    """)
                        .font(.custom(state.settings.fontFamily, size: fontSize))
                        .lineSpacing((lineSpacing - 1) * fontSize)
                        .foregroundColor(theme.text)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.base)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .onChange(of: state.settings) { _, _ in
            state.settings.save()
        }
        .onChange(of: themeImportText) { _, _ in
            if themeImportError != nil {
                themeImportError = nil
            }
        }
        .onChange(of: state.settings.fontSize) { _, _ in previewFontSize = nil }
        .onChange(of: state.settings.lineSpacing) { _, _ in previewLineSpacing = nil }
    }

    private func themeOption(
        _ theme: Theme,
        isSelected: Bool,
        isDeletable: Bool,
        onSelect: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Button(action: onSelect) {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 8) {
                        // Color preview
                        HStack(spacing: 4) {
                            Circle().fill(theme.base).frame(width: 16, height: 16)
                            Circle().fill(theme.surface).frame(width: 16, height: 16)
                            Circle().fill(theme.rose).frame(width: 16, height: 16)
                        }
                        .padding(12)
                        .background(theme.overlay)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? self.theme.rose : (hoveredTheme == theme.name ? self.theme.highlightMed : Color.clear), lineWidth: 2)
                        }
                        .scaleEffect(hoveredTheme == theme.name && !isSelected ? 1.03 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: hoveredTheme)
                    }

                    // Delete button overlay for custom themes
                    if isDeletable {
                        Button {
                            onDelete()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(self.theme.love)
                                .background(Circle().fill(self.theme.base).padding(2))
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 14, y: -14)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                hoveredTheme = hovering ? theme.name : nil
            }

            Text(theme.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? self.theme.rose : self.theme.text)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String, isFirst: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(theme.rose.opacity(0.1))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.rose)
                }

                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(theme.text)
                
                Spacer()
            }
            
            // Decorative line that fades out
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [theme.overlay, theme.overlay.opacity(0.1)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .padding(.top, isFirst ? 4 : 32) // Significantly more space for rhythm
        .padding(.bottom, 16)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    theme.surface
                    
                    // Subtle gradient sheen
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.03),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        LinearGradient(
                            colors: [theme.overlay, theme.overlay.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6) // Premium depth
    }
}

// MARK: - Right Aligned Toggle Style

struct RightAlignedToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            configuration.isOn.toggle()
        }
    }
}

// MARK: - Primary Button Style

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(theme.base)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(isEnabled ? theme.rose : theme.muted)
            .clipShape(Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

// MARK: - Secondary Button Style

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(theme.text)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(theme.overlay)
            .clipShape(Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}
