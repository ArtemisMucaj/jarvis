import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // Status
        if state.processManager.isStarting {
            HStack {
                ProgressView()
                    .scaleEffect(0.7)
                    .controlSize(.small)
                Text("Starting server...")
            }
        } else if state.processManager.isRunning {
            Text("● Running — port \(state.processManager.port)")
        } else {
            Text("○ Stopped")
        }

        Divider()

        // Start / Stop / Restart
        if state.processManager.isStarting {
            Text("Please wait...")
                .foregroundStyle(.secondary)
        } else {
            Button(state.processManager.isRunning ? "Stop" : "Start") {
                state.processManager.isRunning ? state.stopServer() : state.startServer()
            }
            .disabled(state.processManager.isStarting)
        }

        if state.processManager.isRunning {
            Button("Restart") { state.restartServer() }

            Divider()

            Button("Copy Endpoint URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(state.processManager.endpoint, forType: .string)
            }
        }

        Divider()

        Button("Show Window") {
            NSApp.activate(ignoringOtherApps: true)
            // Bring main window to front
            for window in NSApp.windows {
                if window.isVisible {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }

        Divider()

        Button("Quit Jarvis MCP") {
            state.stopServer()
            NSApp.terminate(nil)
        }
    }
}
