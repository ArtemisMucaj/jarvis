import SwiftUI
import AppKit

/// Replaces the standard rounded-border text field with one that does not
/// accept first responder status automatically when the window appears.
/// The user can still click into it to edit — clicking sets firstResponder
/// explicitly, bypassing this flag for the key-view loop only.
private struct PortField: NSViewRepresentable {
    @Binding var value: Int

    func makeNSView(context: Context) -> NSTextField {
        let tf = NoAutoFocusTextField()
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.alignment = .right
        tf.formatter = {
            let f = NumberFormatter()
            f.numberStyle = .none
            f.usesGroupingSeparator = false
            f.allowsFloats = false
            f.minimum = 1
            f.maximum = 65535
            return f
        }()
        tf.delegate = context.coordinator
        tf.integerValue = value
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.integerValue != value { nsView.integerValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PortField
        init(_ parent: PortField) { self.parent = parent }
        func controlTextDidEndEditing(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.value = tf.integerValue
            }
        }
    }

    /// Refuses to become first responder via the window's key-view loop
    /// (which is how SwiftUI auto-focuses the first field on appear), but
    /// still accepts focus on an explicit user click.
    private final class NoAutoFocusTextField: NSTextField {
        override var acceptsFirstResponder: Bool {
            // Allow only when the user is actively clicking us.
            guard let event = NSApp.currentEvent else { return false }
            return event.type == .leftMouseDown || event.type == .rightMouseDown
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    // Draft values — committed to `state` (which triggers a server restart
    // when they change) only when the user hits Done.
    @State private var draftPort: Int = 0
    @State private var draftCodeMode: Bool = false

    // Guardrails drafts.
    @State private var draftGuardrailsEnabled: Bool = false
    @State private var draftGuardrailsPort: Int = 0
    @State private var draftGuardrailsAdminPort: Int = 0
    @State private var draftGuardrailsBackend: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Server") {
                    LabeledContent("Port") {
                        PortField(value: $draftPort)
                            .frame(width: 80, height: 22)
                    }
                    Toggle("CodeMode", isOn: $draftCodeMode)
                    if draftCodeMode {
                        Text("The LLM writes sandboxed Python scripts to batch tool calls instead of calling tools one at a time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Guardrails Proxy") {
                    Toggle("Enabled", isOn: $draftGuardrailsEnabled)
                    Text("Transparent proxy that repairs malformed tool calls from local OpenAI-compatible model servers (e.g. LM Studio).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if draftGuardrailsEnabled {
                        LabeledContent("Listen Port") {
                            PortField(value: $draftGuardrailsPort)
                                .frame(width: 80, height: 22)
                        }
                        LabeledContent("Admin Port") {
                            PortField(value: $draftGuardrailsAdminPort)
                                .frame(width: 80, height: 22)
                        }
                        LabeledContent("Backend") {
                            TextField("http://127.0.0.1:1234", text: $draftGuardrailsBackend)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                        }
                        Text("Point your client at http://127.0.0.1:\(draftGuardrailsPort)/v1. Metrics are served on the admin port.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") {
                    if draftPort != state.port { state.port = draftPort }
                    if draftCodeMode != state.codeMode { state.codeMode = draftCodeMode }

                    // Apply guardrails config before toggling enabled so a
                    // start picks up the latest port/backend.
                    let trimmedBackend = draftGuardrailsBackend.trimmingCharacters(in: .whitespacesAndNewlines)
                    if draftGuardrailsPort != state.guardrailsPort { state.guardrailsPort = draftGuardrailsPort }
                    if draftGuardrailsAdminPort != state.guardrailsAdminPort { state.guardrailsAdminPort = draftGuardrailsAdminPort }
                    if !trimmedBackend.isEmpty, trimmedBackend != state.guardrailsBackend {
                        state.guardrailsBackend = trimmedBackend
                    }
                    if draftGuardrailsEnabled != state.guardrailsEnabled {
                        state.guardrailsEnabled = draftGuardrailsEnabled
                    }

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
        .onAppear {
            draftPort = state.port
            draftCodeMode = state.codeMode
            draftGuardrailsEnabled   = state.guardrailsEnabled
            draftGuardrailsPort      = state.guardrailsPort
            draftGuardrailsAdminPort = state.guardrailsAdminPort
            draftGuardrailsBackend   = state.guardrailsBackend
        }
    }
}
