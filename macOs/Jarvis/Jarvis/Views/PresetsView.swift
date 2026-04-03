import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct PresetsView: View {
    @EnvironmentObject var state: AppState

    @State private var logContent = "Loading logs..."
    @State private var isAutoRefreshing = true
    @State private var refreshTimer: Timer?

    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".jarvis/jarvis.log")

    var body: some View {
        VStack(spacing: 0) {
            // Top: presets form (natural height)
            Form {
                Section {
                    if state.presets.isEmpty {
                        Text("No presets added yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    } else {
                        ForEach($state.presets) { $preset in
                            PresetRowView(preset: $preset)
                        }
                    }
                } header: {
                    HStack {
                        Text("Config Presets")
                        Spacer()
                        Button {
                            pickPresetFile()
                        } label: {
                            Label("Add Preset", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Section("Active Config") {
                    LabeledContent("File") {
                        Text(state.configURL.path(percentEncoded: false))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Servers") {
                        Text("\(state.servers.count) configured, \(state.servers.values.filter { $0.enabled ?? true }.count) enabled")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Bottom: log section fills remaining space
            LogSectionView(
                logContent: logContent,
                isAutoRefreshing: $isAutoRefreshing,
                onRefresh: loadLogs,
                onClear: clearLogs,
                onOpenInEditor: { NSWorkspace.shared.open(logURL) }
            )
        }
        .navigationTitle("Presets")
        .onAppear {
            loadLogs()
            startAutoRefresh()
        }
        .onDisappear {
            isAutoRefreshing = false
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onChange(of: isAutoRefreshing) { _, newValue in
            if newValue { startAutoRefresh() }
        }
    }

    // MARK: - Log helpers

    private func loadLogs() {
        DispatchQueue.global(qos: .utility).async {
            let content: String
            if let raw = try? String(contentsOf: logURL, encoding: .utf8) {
                let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
                content = lines.suffix(10_000).joined(separator: "\n")
            } else {
                content = "No logs found at \(logURL.path(percentEncoded: false))\n\nThe log file will be created when the server starts."
            }
            DispatchQueue.main.async {
                logContent = content
            }
        }
    }

    private func clearLogs() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        loadLogs()
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard isAutoRefreshing else {
                refreshTimer?.invalidate()
                refreshTimer = nil
                return
            }
            loadLogs()
        }
    }

    private func pickPresetFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Select a servers.json config file"
        panel.prompt = "Add Preset"

        if panel.runModal() == .OK, let url = panel.url {
            let name = url.deletingPathExtension().lastPathComponent
            state.addPreset(name: name, filePath: url.path)
        }
    }
}

struct PresetRowView: View {
    @Binding var preset: Preset
    @EnvironmentObject var state: AppState
    @State private var showDeleteConfirm = false

    var isActive: Bool { state.activePresetID == preset.id }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                state.switchPreset(isActive ? nil : preset)
            } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help(isActive ? "Deactivate preset (use default)" : "Switch to this preset")

            VStack(alignment: .leading, spacing: 2) {
                TextField("Preset name", text: $preset.name)
                    .font(.body)
                    .textFieldStyle(.plain)
                Text((preset.filePath as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Remove preset")
            .confirmationDialog(
                isActive ? "Remove active preset?" : "Remove preset?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove\(isActive ? " and restart server" : "")", role: .destructive) {
                    state.removePreset(preset)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(isActive
                     ? "This will switch back to the default config and restart the server if it is running."
                     : "The preset will be removed. The config file on disk is not affected.")
            }
        }
        .padding(.vertical, 2)
    }
}

struct LogSectionView: View {
    let logContent: String
    @Binding var isAutoRefreshing: Bool
    let onRefresh: () -> Void
    let onClear: () -> Void
    let onOpenInEditor: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 12) {
                Text("Server Logs")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                Toggle(isOn: $isAutoRefreshing) {
                    Label("Auto-refresh", systemImage: "arrow.clockwise")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Automatically refresh logs every second")

                Button("Refresh", action: onRefresh)
                    .buttonStyle(.borderless)

                Button("Clear", action: onClear)
                    .buttonStyle(.borderless)

                Button("Open in Editor", action: onOpenInEditor)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logContent)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                    Color.clear
                        .frame(height: 1)
                        .id("logBottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: logContent) { _, _ in
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}
