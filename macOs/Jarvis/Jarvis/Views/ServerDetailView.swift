import SwiftUI

struct ServerDetailView: View {
    let name: String
    let server: MCPServer
    @EnvironmentObject var state: AppState
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""

    private func binding<T>(for keyPath: WritableKeyPath<MCPServer, T>) -> Binding<T> {
        Binding(
            get: { server[keyPath: keyPath] },
            set: { newValue in
                state.servers[name]?[keyPath: keyPath] = newValue
                state.saveConfig()
            }
        )
    }

    private func optionalStringBinding(for keyPath: WritableKeyPath<MCPServer, String?>) -> Binding<String> {
        Binding(
            get: { server[keyPath: keyPath] ?? "" },
            set: { newValue in
                state.servers[name]?[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                state.saveConfig()
            }
        )
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
                    TextField("Args", text: Binding(
                        get: { server.args?.joined(separator: " ") ?? "" },
                        set: { newValue in
                            let parts = newValue.split(separator: " ").map(String.init)
                            state.servers[name]?.args = parts.isEmpty ? nil : parts
                            state.saveConfig()
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    LabeledContent("Transport", value: "stdio")
                }
            }

            // Environment
            Section {
                if let env = server.env, !env.isEmpty {
                    ForEach(env.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(key)
                                .frame(minWidth: 100, alignment: .leading)
                            TextField("Value", text: Binding(
                                get: { server.env?[key] ?? "" },
                                set: { newValue in
                                    state.servers[name]?.env?[key] = newValue
                                    state.saveConfig()
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            Button {
                                state.servers[name]?.env?.removeValue(forKey: key)
                                if state.servers[name]?.env?.isEmpty == true {
                                    state.servers[name]?.env = nil
                                }
                                state.saveConfig()
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
                        if state.servers[name]?.env == nil {
                            state.servers[name]?.env = [:]
                        }
                        state.servers[name]?.env?[newEnvKey] = newEnvValue
                        state.saveConfig()
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
                        get: { server.enabled ?? true },
                        set: { newValue in
                            state.servers[name]?.enabled = newValue
                            state.saveConfig()
                        }
                    ))
                    .labelsHidden()
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
