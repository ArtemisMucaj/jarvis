import Foundation
import Combine

/// Launches and supervises the bundled `guardrail` proxy binary
/// (https://github.com/ArtemisMucaj/guardrails) and polls its admin server
/// for liveness and metrics. Mirrors `ProcessManager` but adds the admin
/// `/stats`, `/info`, and `/healthz` polling that powers the Stats screen.
class GuardrailsManager: ObservableObject {
    @Published var isRunning = false
    @Published var isStarting = false
    @Published var lastError: String?

    /// Whether the admin server answered the most recent /healthz probe.
    @Published var isReachable = false
    @Published var stats: GuardrailsStats?
    @Published var info: GuardrailsInfo?

    private var process: Process?
    private var processSource: DispatchSourceProcess?
    private var pollTimer: Timer?

    // Configuration (owned/persisted by AppState, pushed down here).
    var listenPort: Int
    var adminPort: Int
    var backend: String

    init(listenPort: Int = 8080, adminPort: Int = 8081, backend: String = "http://127.0.0.1:1234") {
        self.listenPort = listenPort
        self.adminPort = adminPort
        self.backend = backend
    }

    /// The OpenAI-compatible endpoint clients point at instead of the backend.
    var proxyEndpoint: String { "http://127.0.0.1:\(listenPort)/v1" }
    var adminBase: String { "http://127.0.0.1:\(adminPort)" }

    // MARK: - Lifecycle

    func startBundled() {
        guard !isRunning && !isStarting else {
            print("⚠️ Guardrails already running or starting - ignoring start request")
            return
        }
        // Set the re-entrancy guard synchronously: callers run on the main
        // thread, and a deferred (async) flag would let a second start slip
        // past this guard within the same runloop tick, spawning a duplicate
        // process. startBundled() must only ever be called on the main thread.
        isStarting = true
        lastError = nil

        guard listenPort != adminPort else {
            isStarting = false
            setError("Guardrails listen port and admin port must differ (both are \(listenPort)).")
            return
        }

        guard !backend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isStarting = false
            setError("Guardrails backend URL is empty. Set it in Settings (e.g. http://127.0.0.1:1234).")
            return
        }

        guard let resourcePath = Bundle.main.resourcePath else {
            isStarting = false
            setError("Could not locate app bundle resources.")
            return
        }

        let binaryPath = (resourcePath as NSString).appendingPathComponent("guardrail")
        let fileManager = FileManager.default

        guard fileManager.isExecutableFile(atPath: binaryPath) else {
            isStarting = false
            setError("Bundled guardrail binary not found at: \(binaryPath)\n\nRebuild the app after running scripts/download_guardrails_binary.sh")
            return
        }

        print("🔄 Starting guardrails (bundled binary)")
        print("📦 Binary: \(binaryPath)")

        let logURL = logFileURL()
        prepareLogFile(at: logURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = [
            "--listen", "127.0.0.1:\(listenPort)",
            "--admin-listen", "127.0.0.1:\(adminPort)",
            "--backend", backend,
        ]
        proc.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
        proc.environment = ProcessManager.shellEnvironment
        proc.standardOutput = logHandle(for: logURL)
        proc.standardError  = logHandle(for: logURL)

        do {
            try proc.run()
            process = proc
            print("✓ Guardrails proxy launched on \(proxyEndpoint), admin on \(adminBase)")
            DispatchQueue.main.async { self.markRunning() }
        } catch {
            DispatchQueue.main.async {
                self.isStarting = false
                self.lastError = error.localizedDescription
            }
            print("❌ Failed to start guardrails: \(error)")
        }
    }

    func stop() {
        stopPolling()
        processSource?.cancel()
        processSource = nil
        if let proc = process, proc.isRunning {
            let pgid = proc.processIdentifier
            kill(-pgid, SIGTERM)
            proc.terminate()
        }
        process = nil
        isRunning = false
        isStarting = false
        isReachable = false
        // Drop metrics from the previous run so a restart (e.g. new backend
        // or port) never shows stale numbers.
        stats = nil
        info = nil
    }

    // MARK: - Admin polling

    /// Fetch /healthz, /info, and /stats from the admin server once.
    func refresh() {
        fetchHealth()
        fetchInfo()
        fetchStats()
    }

    private func fetchHealth() {
        guard let url = URL(string: "\(adminBase)/healthz") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                if self.isReachable != ok { self.isReachable = ok }
            }
        }.resume()
    }

    private func fetchInfo() {
        guard let url = URL(string: "\(adminBase)/info") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data, let info = GuardrailsInfo(data: data) else { return }
            DispatchQueue.main.async {
                if self.info != info { self.info = info }
            }
        }.resume()
    }

    private func fetchStats() {
        guard let url = URL(string: "\(adminBase)/stats") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                print("📊 Guardrails stats fetch failed: \(error.localizedDescription)")
                return
            }
            guard let data,
                  let parsed = try? JSONDecoder().decode(GuardrailsStats.self, from: data)
            else {
                print("📊 Guardrails stats: unexpected response")
                return
            }
            DispatchQueue.main.async {
                if self.stats != parsed { self.stats = parsed }
            }
        }.resume()
    }

    // MARK: - Private

    private func markRunning() {
        isStarting = false
        isRunning = true
        if let pid = process?.processIdentifier { watchProcess(pid) }
        // The exit watcher is installed above, but the process may already
        // have died before we got here (e.g. a port was in use). Reconcile so
        // status doesn't stay stuck on "running" with the exit event missed.
        if let proc = process, !proc.isRunning {
            print("⚠️ Guardrails exited immediately after launch")
            markStopped()
            lastError = "Guardrails exited on startup. Check that ports \(listenPort)/\(adminPort) are free and the backend URL is valid."
            return
        }
        // Give the admin socket a moment to bind, then begin polling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isRunning else { return }
            self.refresh()
            self.startPolling()
        }
        print("✅ Guardrails is ready (proxy \(proxyEndpoint))")
    }

    private func markStopped() {
        stopPolling()
        process = nil
        isRunning = false
        isStarting = false
        isReachable = false
        processSource?.cancel()
        processSource = nil
        stats = nil
        info = nil
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func watchProcess(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.markStopped() }
        }
        source.resume()
        processSource = source
    }

    private func setError(_ msg: String) {
        DispatchQueue.main.async {
            self.isStarting = false
            self.lastError = msg
        }
        print("❌ \(msg)")
    }

    private func logFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".guardrails/guardrails.log")
    }

    private func prepareLogFile(at url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.truncateFile(atOffset: 0)
            handle.closeFile()
        }
    }

    private func logHandle(for url: URL) -> FileHandle? {
        try? FileHandle(forWritingTo: url)
    }
}
