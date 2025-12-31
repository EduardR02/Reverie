import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme

    @State private var selectedSection: SettingsSection = .intelligence
    @State private var themeImportText: String = ""
    @State private var themeImportError: String?

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
                        .frame(width: 200)

                    // Divider
                    Rectangle()
                        .fill(theme.overlay)
                        .frame(width: 1)

                    // Content
                    ScrollView {
                        VStack(spacing: 24) {
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
                        .padding(32)
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
                    Text("Library")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.subtle)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Settings")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(theme.text)

            Spacer()

            // Placeholder for symmetry
            Color.clear.frame(width: 80)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(height: 52)
        .background(theme.surface)
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
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .font(.system(size: 14))
                            .foregroundColor(selectedSection == section ? theme.rose : theme.muted)
                            .frame(width: 20)

                        Text(section.rawValue)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(selectedSection == section ? theme.text : theme.subtle)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        selectedSection == section ? theme.overlay : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(16)
        .background(theme.surface)
    }

    // MARK: - Intelligence Section

    private var intelligenceSection: some View {
        @Bindable var state = appState

        return VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Models", icon: "cpu")

            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("LLM Provider")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)

                            Picker("", selection: $state.settings.llmProvider) {
                                ForEach(LLMProvider.allCases, id: \.self) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Model")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)

                            Picker("", selection: $state.settings.llmModel) {
                                ForEach(state.settings.llmProvider.models, id: \.id) { model in
                                    Text(model.name).tag(model.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
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
                        
                        Text("Controls how many insights are generated per chapter")
                            .font(.system(size: 12))
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

                            Picker("", selection: $state.settings.insightReasoningLevel) {
                                ForEach(ReasoningLevel.allCases, id: \.self) { level in
                                    Text(level.rawValue).tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        HStack {
                            Text("Chat")
                                .font(.system(size: 13))
                                .foregroundColor(theme.text)
                                .frame(width: 70, alignment: .leading)

                            Picker("", selection: $state.settings.chatReasoningLevel) {
                                ForEach(ReasoningLevel.allCases, id: \.self) { level in
                                    Text(level.rawValue).tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
            }

            sectionHeader("Parameters", icon: "slider.horizontal.3")

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Temperature")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.muted)

                        Spacer()
                        
                        Text(String(format: "%.1f", state.settings.temperature))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.text)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.overlay)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Slider(
                        value: $state.settings.temperature,
                        in: 0.0...2.0,
                        step: 0.1
                    )
                    .tint(theme.rose)
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
            sectionHeader("Automation", icon: "wand.and.stars")

            settingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    Toggle(isOn: $state.settings.autoSwitchToQuiz) {
                        toggleLabel(title: "Quiz Auto-open", subtitle: "Tug past chapter end to open quiz")
                    }
                    .toggleStyle(RightAlignedToggleStyle())
                    .padding(.vertical, 12)

                    Divider().background(theme.overlay)

                    Toggle(isOn: $state.settings.autoSwitchContextTabs) {
                        toggleLabel(title: "Context Auto-follow", subtitle: "Tabs follow your scroll position")
                    }
                    .toggleStyle(RightAlignedToggleStyle())
                    .padding(.vertical, 12)

                    Divider().background(theme.overlay)

                    Toggle(isOn: $state.settings.autoScrollHighlightEnabled) {
                        toggleLabel(title: "Auto-scroll Highlighting", subtitle: "Outline active items while scrolling")
                    }
                    .toggleStyle(RightAlignedToggleStyle())
                    .padding(.vertical, 12)

                    Divider().background(theme.overlay)

                    Toggle(isOn: $state.settings.autoSwitchFromChatOnScroll) {
                        toggleLabel(title: "Smart Chat Return", subtitle: "Back to context when scrolling text")
                    }
                    .toggleStyle(RightAlignedToggleStyle())
                    .padding(.vertical, 12)
                }
            }
            .tint(theme.rose)

            sectionHeader("Stats & Movement", icon: "chart.bar")

            settingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    Toggle(isOn: $state.settings.smartAutoScrollEnabled) {
                        toggleLabel(title: "Smart Auto-Scroll", subtitle: "Scroll based on reading speed")
                    }
                    .toggleStyle(RightAlignedToggleStyle())
                    .padding(.vertical, 12)

                    Divider().background(theme.overlay)

                    Toggle(isOn: $state.settings.showReadingSpeedFooter) {
                        toggleLabel(title: "Reading Speed", subtitle: "Show average speed in footer")
                    }
                    .toggleStyle(RightAlignedToggleStyle())
                    .padding(.vertical, 12)
                }
            }
            .tint(theme.rose)

            sectionHeader("Interface", icon: "macwindow")

            settingsCard {
                let readerPercent = Int((state.splitRatio * 100).rounded())
                let aiPercent = max(0, 100 - readerPercent)

                VStack(alignment: .leading, spacing: 12) {
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
                            .background(theme.overlay)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    Slider(
                        value: $state.splitRatio,
                        in: 0.5...0.8,
                        step: 0.01
                    )
                    .tint(theme.iris)
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
            sectionHeader("Image Generation", icon: "photo.stack")

            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: $state.settings.imagesEnabled) {
                        toggleLabel(title: "Enable AI Images", subtitle: "Generate illustrations for scenes")
                    }
                    .toggleStyle(RightAlignedToggleStyle())
                    .tint(theme.rose)

                    if state.settings.imagesEnabled {
                        Divider().background(theme.overlay)

                        Toggle(isOn: $state.settings.inlineAIImages) {
                            toggleLabel(title: "Inline in Text", subtitle: "Show images directly inside the chapter")
                        }
                        .toggleStyle(RightAlignedToggleStyle())
                        .tint(theme.rose)

                        Divider().background(theme.overlay)

                        Toggle(isOn: $state.settings.rewriteImageExcerpts) {
                            toggleLabel(title: "Prompt Refinement", subtitle: "Rewrite excerpts into detailed image prompts")
                        }
                        .toggleStyle(RightAlignedToggleStyle())
                        .tint(theme.rose)
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

                            Picker("", selection: $state.settings.imageModel) {
                                ForEach(ImageModel.allCases, id: \.self) { model in
                                    Text(model.rawValue).tag(model)
                                }
                            }
                            .pickerStyle(.segmented)
                            
                            Text(state.settings.imageModel.description)
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
            sectionHeader("API Keys", icon: "key.fill")

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
                    }
                }

                SecureField("Enter API key...", text: key)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .padding(12)
                    .background(theme.base)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Link(destination: URL(string: linkURL)!) {
                    HStack(spacing: 4) {
                        Text(linkText)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.rose)
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
            sectionHeader("Theme", icon: "circle.lefthalf.filled")

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

                    Divider()

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
                                    .background(theme.overlay)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
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

                        Picker("", selection: $state.settings.fontFamily) {
                            ForEach(fonts, id: \.self) { font in
                                Text(font).tag(font)
                            }
                        }
                        .labelsHidden()
                    }

                    Divider()

                    // Font size
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Font Size")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)
                            Spacer()
                            Text("\(Int(state.settings.fontSize))px")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(theme.text)
                        }

                        Slider(
                            value: $state.settings.fontSize,
                            in: 12...36,
                            step: 1
                        )
                        .tint(theme.rose)
                    }

                    Divider()

                    // Line spacing
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Line Spacing")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(theme.muted)
                            Spacer()
                            Text(String(format: "%.1f", state.settings.lineSpacing))
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(theme.text)
                        }

                        Slider(
                            value: $state.settings.lineSpacing,
                            in: 1.0...2.5,
                            step: 0.1
                        )
                        .tint(theme.rose)
                    }
                }
            }

            sectionHeader("Preview", icon: "eye")

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("""
                    The garden stretched out before her, a tapestry of colors and scents that shifted with the breeze. She followed the narrow path past the hedges, where the light thinned and the air turned cool.

                    At the far end, a stone bench waited beneath the old oak. She sat, opened the book, and let the words settle into a steady rhythm that carried her deeper into the story.
                    """)
                        .font(.custom(state.settings.fontFamily, size: state.settings.fontSize))
                        .lineSpacing((state.settings.lineSpacing - 1) * state.settings.fontSize)
                        .foregroundColor(theme.text)
                }
                .padding(16)
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
                                .stroke(isSelected ? self.theme.rose : Color.clear, lineWidth: 2)
                        }
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
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }
                }
            }
            .buttonStyle(.plain)

            Text(theme.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? self.theme.rose : self.theme.text)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.rose)

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.text)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}
