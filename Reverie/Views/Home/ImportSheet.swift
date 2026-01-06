import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
    let onImport: (URL) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedURL: URL?
    @State private var estimatedCost: String?
    @State private var dragOver = false

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(theme.rose)

                Text("Import Book")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(theme.text)
            }
            .padding(.top, 8)

            // Drop zone
            dropZone
                .frame(height: 120)

            // Selected file info
            if let url = selectedURL {
                selectedFileInfo(url)
            }

            // Actions
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("Import") {
                    if let url = selectedURL {
                        // Copy to temp to preserve access after sheet dismisses
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")

                        // Start accessing security scoped resource for file picker URLs
                        let hasAccess = url.startAccessingSecurityScopedResource()
                        defer {
                            if hasAccess {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }

                        do {
                            try? FileManager.default.removeItem(at: tempURL)
                            try FileManager.default.copyItem(at: url, to: tempURL)
                            onImport(tempURL)
                        } catch {
                            // Fall back to original URL if copy fails
                            onImport(url)
                        }
                        dismiss()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selectedURL == nil)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(theme.surface)
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    dragOver ? theme.rose : theme.overlay,
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(dragOver ? theme.rose.opacity(0.1) : theme.base)
                )

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(theme.muted)

                Text("Drop EPUB here or")
                    .font(.system(size: 13))
                    .foregroundColor(theme.muted)

                Button("Browse Files") {
                    openFilePicker()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.rose)
                .buttonStyle(.plain)
            }
        }
        .onDrop(of: [.epub], isTargeted: $dragOver) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: - Selected File Info

    private func selectedFileInfo(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 20))
                .foregroundColor(theme.rose)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.text)

                if let size = fileSize(url) {
                    Text(size)
                        .font(.system(size: 11))
                        .foregroundColor(theme.muted)
                }
            }

            Spacer()

            Button {
                selectedURL = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(theme.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(theme.base)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.epub]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK {
            selectedURL = panel.url
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.epub.identifier) { url, error in
                guard let url = url else { return }

                // Copy to temp (provider URL is temporary)
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: tempURL)
                try? FileManager.default.copyItem(at: url, to: tempURL)

                DispatchQueue.main.async {
                    selectedURL = tempURL
                }
            }
        }
    }

    private func fileSize(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return nil
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
