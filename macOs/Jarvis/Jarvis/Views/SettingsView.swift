import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var showDebugInfo = false
    
    private var isUVPathValid: Bool {
        FileManager.default.isExecutableFile(atPath: state.uvPath)
    }

    private var isProjectPathValid: Bool {
        state.projectPath.isEmpty || FileManager.default.fileExists(atPath: state.projectPath + "/jarvis.py")
    }

    private func pickProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the local jarvis-mcp project folder"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            state.projectPath = url.path
        }
    }
    
    private func pickUVExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the UV executable"
        panel.prompt = "Select"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        
        // Start in common directories
        if let binURL = URL(string: "file:///usr/local/bin") {
            panel.directoryURL = binURL
        }
        
        if panel.runModal() == .OK, let url = panel.url {
            state.uvPath = url.path
        }
    }
    
    private func getDebugInfo() -> String {
        var info = "UV Detection Debug Info:\n\n"
        
        // Check PATH
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            info += "PATH: \(path)\n\n"
        }
        
        // Check common locations
        let candidates = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            "\(NSHomeDirectory())/.local/bin/uv",
            "\(NSHomeDirectory())/.cargo/bin/uv",
            "/usr/bin/uv"
        ]
        
        info += "Checked locations:\n"
        for candidate in candidates {
            let exists = FileManager.default.fileExists(atPath: candidate)
            let executable = FileManager.default.isExecutableFile(atPath: candidate)
            info += "• \(candidate)\n  Exists: \(exists), Executable: \(executable)\n"
        }
        
        return info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Server Source") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Local Project Path (dev mode)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    TextField("Leave empty to use GitHub", text: $state.projectPath)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.caption, design: .monospaced))
                                    Button("Browse...") { pickProjectFolder() }
                                    if !state.projectPath.isEmpty {
                                        Button { state.projectPath = "" } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Clear to use GitHub")
                                    }
                                }
                            }
                        }

                        if state.isLocalMode {
                            HStack(spacing: 4) {
                                Image(systemName: isProjectPathValid ? "hammer.fill" : "xmark.circle.fill")
                                    .foregroundStyle(isProjectPathValid ? .orange : .red)
                                Text(isProjectPathValid ? "Dev mode — running from local project" : "jarvis.py not found in this directory")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Running from GitHub — \(state.githubURL)")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Runtime") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Path to uv", text: $state.uvPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse…") {
                                pickUVExecutable()
                            }
                            Button("Auto-detect") {
                                state.uvPath = ProcessManager.detectUVPath()
                            }
                        }
                        HStack(spacing: 4) {
                            Image(systemName: isUVPathValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(isUVPathValid ? .green : .red)
                                .font(.caption)
                            Text(isUVPathValid ? "UV executable found" : "UV executable not found at this path")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !isUVPathValid {
                                Button("Install UV") {
                                    NSWorkspace.shared.open(URL(string: "https://docs.astral.sh/uv/getting-started/installation/")!)
                                }
                                .font(.caption)
                                .buttonStyle(.link)
                            }
                        }
                        if !isUVPathValid {
                            Text("💡 Tip: If you installed UV, try running 'which uv' in Terminal to find its path")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                            
                            Button("Show Debug Info") {
                                showDebugInfo = true
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                        }
                    }

                    LabeledContent("Port") {
                        TextField("Port", value: $state.port, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") {
                    state.saveConfig()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(width: 460)
        .navigationTitle("Settings")
        .alert("UV Debug Info", isPresented: $showDebugInfo) {
            Button("Copy to Clipboard") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(getDebugInfo(), forType: .string)
            }
            Button("OK", role: .cancel) { }
        } message: {
            Text(getDebugInfo())
        }
    }
}
