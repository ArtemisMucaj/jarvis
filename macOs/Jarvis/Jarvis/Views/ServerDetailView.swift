import SwiftUI

struct ServerDetailView: View {
    let name: String
    let server: MCPServer
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            // Connection
            Section("Connection") {
                if let url = server.url {
                    LabeledContent("URL", value: url)
                    LabeledContent("Transport", value: server.transport ?? "http")
                } else if let command = server.command {
                    LabeledContent("Command", value: command)
                    if let args = server.args, !args.isEmpty {
                        LabeledContent("Args", value: args.joined(separator: " "))
                    }
                    LabeledContent("Transport", value: "stdio")
                }
            }

            // Environment
            if let env = server.env, !env.isEmpty {
                Section("Environment") {
                    ForEach(env.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: env[key] ?? "")
                    }
                }
            }

            // Auth
            if server.isOAuth {
                Section("OAuth Authentication") {
                    HStack {
                        Button {
                            state.runAuth(for: name)
                        } label: {
                            Label(
                                state.isAuthRunning ? "Authenticating…" : "Authenticate",
                                systemImage: "key.fill"
                            )
                        }
                        .disabled(state.isAuthRunning)
                        .buttonStyle(.borderedProminent)

                        Spacer()
                        Text("Tokens are stored in ~/.jarvis/")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !state.authOutput.isEmpty {
                        ScrollView {
                            Text(state.authOutput)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(height: 130)
                        .background(Color(.textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
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
