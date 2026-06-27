import SwiftUI

/// Dedicated screen for the guardrails proxy: live running/stopped status,
/// start/stop controls, and the metrics rollup served by the admin `/stats`
/// endpoint.
struct GuardrailsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    private var manager: GuardrailsManager { state.guardrailsManager }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear {
            if manager.isRunning { manager.refresh() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 28))
                .foregroundStyle(manager.isRunning ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    statusDot
                    Text(statusText)
                        .font(.headline)
                }
                if manager.isRunning {
                    Text("Proxy \(manager.proxyEndpoint)  ·  Admin \(manager.adminBase)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("OpenAI-compatible tool-call repair proxy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            controls
        }
        .padding()
    }

    @ViewBuilder
    private var statusDot: some View {
        if manager.isStarting {
            ProgressView().scaleEffect(0.5).controlSize(.small)
        } else {
            Circle()
                .fill(manager.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10)
        }
    }

    private var statusText: String {
        if manager.isStarting { return "Starting…" }
        if manager.isRunning {
            return manager.isReachable ? "Running" : "Running (admin unreachable)"
        }
        return "Stopped"
    }

    @ViewBuilder
    private var controls: some View {
        if manager.isRunning {
            Button {
                manager.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                state.guardrailsEnabled = false
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else if manager.isStarting {
            Button("Starting…") {}.disabled(true)
        } else {
            Button {
                state.guardrailsEnabled = true
            } label: {
                Label("Start", systemImage: "play.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !manager.isRunning && !manager.isStarting {
            emptyState(
                icon: "shield.slash",
                title: "Guardrails is stopped",
                message: "Start the proxy to repair malformed tool calls from your local model and collect metrics."
            )
        } else if let stats = manager.stats, !stats.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    summaryCards(stats)
                    if !stats.perModel.isEmpty { perModelSection(stats.perModel) }
                    if !stats.errors.isEmpty { errorsSection(stats.errors) }
                    if let info = manager.info { infoSection(info) }
                }
                .padding()
            }
        } else if manager.lastError != nil {
            emptyState(
                icon: "exclamationmark.triangle",
                title: "Could not start guardrails",
                message: manager.lastError ?? ""
            )
        } else {
            emptyState(
                icon: "chart.bar.xaxis",
                title: "No metrics yet",
                message: "Stats appear here once the proxy has handled tool-enabled requests."
            )
        }
    }

    // MARK: - Summary cards

    private func summaryCards(_ stats: GuardrailsStats) -> some View {
        HStack(spacing: 12) {
            metricCard(title: "Requests", value: "\(stats.totalRequests)", color: .blue)
            metricCard(title: "Tool Calls", value: "\(stats.totalToolCalls)", color: .purple)
            metricCard(title: "Succeeded", value: "\(stats.totalSucceeded)", color: .green)
            metricCard(title: "Errors", value: "\(stats.totalErrors)", color: .orange)
            metricCard(
                title: "Success Rate",
                value: stats.overallSuccessRate.map { Self.percent($0) } ?? "—",
                color: .teal
            )
        }
    }

    private func metricCard(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Per-model

    private func perModelSection(_ rows: [ModelStat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per Model").font(.headline)
            VStack(spacing: 0) {
                modelHeaderRow
                Divider()
                ForEach(rows) { row in
                    ModelStatRow(stat: row)
                    if row.id != rows.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    private var modelHeaderRow: some View {
        HStack {
            Text("Model").frame(maxWidth: .infinity, alignment: .leading)
            Text("Total").frame(width: 60, alignment: .trailing)
            Text("Tools").frame(width: 60, alignment: .trailing)
            Text("OK").frame(width: 60, alignment: .trailing)
            Text("Err").frame(width: 60, alignment: .trailing)
            Text("Rate").frame(width: 64, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Errors

    private func errorsSection(_ rows: [ErrorStat]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Errors").font(.headline)
            VStack(spacing: 0) {
                HStack {
                    Text("Category").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Tool").frame(width: 140, alignment: .leading)
                    Text("Model").frame(width: 140, alignment: .leading)
                    Text("Count").frame(width: 60, alignment: .trailing)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                ForEach(rows) { row in
                    HStack {
                        Text(row.errorCategory)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(row.detail ?? "")
                        Text(row.toolName ?? "—")
                            .frame(width: 140, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(row.model)
                            .frame(width: 140, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text("\(row.count)").frame(width: 60, alignment: .trailing).monospacedDigit()
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    if row.id != rows.last?.id { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    // MARK: - Info

    private func infoSection(_ info: GuardrailsInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Proxy Info").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(info.rows.enumerated()), id: \.offset) { idx, row in
                    HStack(alignment: .top) {
                        Text(row.key)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 180, alignment: .leading)
                        Text(row.value)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    if idx != info.rows.count - 1 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    // MARK: - Helpers

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

/// One expandable row in the per-model table; tapping reveals the outcome
/// breakdown for that model.
private struct ModelStatRow: View {
    let stat: ModelStat
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if !stat.byOutcome.isEmpty { expanded.toggle() }
            } label: {
                HStack {
                    HStack(spacing: 6) {
                        if !stat.byOutcome.isEmpty {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(stat.model).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(stat.total)").frame(width: 60, alignment: .trailing).monospacedDigit()
                    Text("\(stat.toolCalls)").frame(width: 60, alignment: .trailing).monospacedDigit()
                    Text("\(stat.succeeded)").frame(width: 60, alignment: .trailing).monospacedDigit()
                    Text("\(stat.errors)")
                        .frame(width: 60, alignment: .trailing)
                        .monospacedDigit()
                        .foregroundStyle(stat.errors > 0 ? .orange : .primary)
                    Text(stat.successRate.map { GuardrailsView.percent($0) } ?? "—")
                        .frame(width: 64, alignment: .trailing)
                        .monospacedDigit()
                }
                .font(.callout)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 4) {
                    ForEach(stat.byOutcome) { oc in
                        HStack {
                            Text(oc.outcome)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(oc.count)").font(.caption).monospacedDigit()
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
            }
        }
    }
}
