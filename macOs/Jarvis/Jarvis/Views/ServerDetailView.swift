import SwiftUI

struct ServerDetailView: View {
    let name: String
    let server: MCPServer
    @EnvironmentObject var state: AppState
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""
    @State private var stagedServer: MCPServer
    @State private var hasChanges = false

    init(name: String, server: MCPServer) {
        self.name = name
        self.server = server
        _stagedServer = State(initialValue: server)
    }

    private func binding<T: Equatable>(for keyPath: WritableKeyPath<MCPServer, T>) -> Binding<T> {
        Binding(
            get: { stagedServer[keyPath: keyPath] },
            set: { newValue in
                stagedServer[keyPath: keyPath] = newValue
                hasChanges = true
            }
        )
    }

    private func optionalStringBinding(for keyPath: WritableKeyPath<MCPServer, String?>) -> Binding<String> {
        Binding(
            get: { stagedServer[keyPath: keyPath] ?? "" },
            set: { newValue in
                stagedServer[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                hasChanges = true
            }
        )
    }

    private func applyChanges() {
        state.servers[name] = stagedServer
        state.saveConfig()
        hasChanges = false
        // Restart server if running to apply changes
        if state.processManager.isRunning {
            state.restartServer()
        }
    }

    var body: some View {
        Form {
            // Connection
            Section("Connection") {
                if server.isHTTP {
                    TextField("URL", text: optionalStringBinding(for: \.url))
                        .textFieldStyle(.roundedBorder)
                    LabeledContent("Transport", value: server.transport ?? "http")
                } else {
                    TextField("Command", text: optionalStringBinding(for: \.command))
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Args")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                if stagedServer.args == nil {
                                    stagedServer.args = [""]
                                } else {
                                    stagedServer.args?.append("")
                                }
                                hasChanges = true
                            } label: {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.borderless)
                        }

                        if let args = stagedServer.args, !args.isEmpty {
                            ForEach(args.indices, id: \.self) { index in
                                HStack {
                                    TextField("Arg \(index)", text: Binding(
                                        get: { stagedServer.args?[index] ?? "" },
                                        set: { newValue in
                                            stagedServer.args?[index] = newValue
                                            hasChanges = true
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)

                                    Button {
                                        stagedServer.args?.remove(at: index)
                                        if stagedServer.args?.isEmpty == true {
                                            stagedServer.args = nil
                                        }
                                        hasChanges = true
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        } else {
                            Text("No arguments")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                    }

                    LabeledContent("Transport", value: "stdio")
                }
            }

            // Environment
            Section {
                if let env = stagedServer.env, !env.isEmpty {
                    ForEach(env.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(key)
                                .frame(minWidth: 100, alignment: .leading)
                            TextField("Value", text: Binding(
                                get: { stagedServer.env?[key] ?? "" },
                                set: { newValue in
                                    stagedServer.env?[key] = newValue
                                    hasChanges = true
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            Button {
                                stagedServer.env?.removeValue(forKey: key)
                                if stagedServer.env?.isEmpty == true {
                                    stagedServer.env = nil
                                }
                                hasChanges = true
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("Key", text: $newEnvKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 100)
                    TextField("Value", text: $newEnvValue)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        guard !newEnvKey.isEmpty else { return }
                        if stagedServer.env == nil {
                            stagedServer.env = [:]
                        }
                        stagedServer.env?[newEnvKey] = newEnvValue
                        hasChanges = true
                        newEnvKey = ""
                        newEnvValue = ""
                    } label: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .disabled(newEnvKey.isEmpty)
                }
            } header: {
                Text("Environment")
            }

            // Tools
            Section {
                if let tools = state.discoveredTools[name], !tools.isEmpty {
                    ForEach(tools) { tool in
                        ToolRowView(
                            serverName: name,
                            tool: tool,
                            isDisabled: state.isToolDisabled(server: name, tool: tool.name)
                        )
                    }
                } else if state.isDiscoveringTools {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Discovering tools...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No tools discovered yet")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Tools")
                    Spacer()
                    if let tools = state.discoveredTools[name] {
                        let enabled = tools.filter { !state.isToolDisabled(server: name, tool: $0.name) }.count
                        Text("\(enabled)/\(tools.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        state.discoverTools()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(state.isDiscoveringTools || !(server.enabled ?? true))
                }
            }

            // Status
            Section("Status") {
                LabeledContent("Enabled") {
                    Toggle("", isOn: Binding(
                        get: { stagedServer.enabled ?? true },
                        set: { newValue in
                            stagedServer.enabled = newValue
                            hasChanges = true
                        }
                    ))
                    .labelsHidden()
                }

                if hasChanges {
                    HStack {
                        Spacer()
                        Button("Discard Changes") {
                            stagedServer = server
                            hasChanges = false
                        }
                        .foregroundStyle(.secondary)

                        Button("Apply & Restart") {
                            applyChanges()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(name)
        .navigationSubtitle(server.isOAuth ? "OAuth" : (server.isHTTP ? "HTTP" : "stdio"))
    }
}

struct ToolRowView: View {
    let serverName: String
    let tool: DiscoveredTool
    let isDisabled: Bool
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .fontWeight(.medium)
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                if !tool.description.isEmpty {
                    Text(tool.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { !isDisabled },
                set: { _ in
                    state.toggleTool(server: serverName, tool: tool.name)
                }
            ))
            .labelsHidden()
        }
    }
}