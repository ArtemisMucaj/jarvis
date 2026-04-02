import SwiftUI

@main
struct JarvisMCPApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        // Main window - opens by default
        WindowGroup {
            ContentView()
                .environmentObject(state)
        }
        .defaultSize(width: 780, height: 520)
        
        // Menu bar extra for quick access
        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            if state.processManager.isStarting {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .controlSize(.small)
                    Image(systemName: "hexagon")
                }
            } else {
                Image(systemName: state.processManager.isRunning ? "hexagon.fill" : "hexagon")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        state.processManager.isRunning ? .green : .primary,
                        .primary
                    )
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
