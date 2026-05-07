import Foundation
import AppKit

@MainActor
final class LauncherStore: ObservableObject {
    @Published var snapshot = LauncherSnapshot()
    @Published var isBusy = false
    @Published var lastError: String?
    @Published var resultCard: LauncherResultCard?
    @Published var elapsedSeconds: Int = 0

    private let projectRoot: URL
    private let launcherScript: URL
    private var refreshTimer: Timer?
    private var launchProcess: Process?
    private var stdoutBuffer: String = ""
    private var pendingFields: [String: String] = [:]
    private var elapsedTimer: Timer?
    private var sessionKept5MinTimer: Timer?
    /// Track installed-state transitions so we only fire `hermes_install_completed` on the
    /// transition `false → true`, not on every refresh that happens to see installed=true.
    private var lastSeenInstalled: Bool? = nil
    /// Capture the final `LAST_RESULT` value we've already reported, so we don't re-fire
    /// hermes_install_failed on every refresh while LAST_STAGE=install LAST_RESULT=failed sits in state.env.
    private var reportedInstallResult: String? = nil

    init(projectRoot: URL = LauncherStore.resolveProjectRoot()) {
        self.projectRoot = projectRoot
        self.launcherScript = projectRoot.appendingPathComponent("HermesMacGuiLauncher.command")
        // Telemetry: record that the launcher window/app came up. Sent at most once per session.
        TelemetryClient.shared.sendOnce(.launcherOpened)
        // Telemetry: record program shutdown. NSApplication.willTerminate fires before exit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                TelemetryClient.shared.send(.launcherClosed)
            }
        }
        refresh()
    }

    deinit {
        refreshTimer?.invalidate()
        elapsedTimer?.invalidate()
        sessionKept5MinTimer?.invalidate()
    }

    nonisolated private static func resolveProjectRoot() -> URL {
        let fileManager = FileManager.default
        if let resourceURL = Bundle.main.resourceURL {
            let bundledScript = resourceURL.appendingPathComponent("HermesMacGuiLauncher.command").path
            if fileManager.fileExists(atPath: bundledScript) {
                return resourceURL
            }
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidates = [
            cwd,
            cwd.deletingLastPathComponent(),
            cwd.deletingLastPathComponent().deletingLastPathComponent()
        ]

        for candidate in candidates {
            let launcherPath = candidate.appendingPathComponent("HermesMacGuiLauncher.command").path
            if fileManager.fileExists(atPath: launcherPath) {
                return candidate
            }
        }

        return cwd
    }

    // MARK: - Refresh (read-only --state-test)

    func refresh() {
        runLauncher(arguments: ["--state-test"], updateBusy: false) { [weak self] output in
            self?.applyStateTest(output: output)
        }
    }

    private func applyStateTest(output: String) {
        let fields = parseKeyValueLines(output)

        let installed = fields["installed"] == "true"
        let webuiInstalled = fields["webui_installed"] == "true"
        let webuiRunning = fields["webui_running"] == "true"
        let lastResult = fields["last_result"] ?? "idle"
        let lastStage = fields["last_stage"] ?? ""

        // Telemetry — Hermes-install transition events.
        // hermes_install_completed: fire on the false→true transition of `installed`.
        if let prior = lastSeenInstalled, !prior, installed {
            TelemetryClient.shared.send(.hermesInstallCompleted)
        }
        lastSeenInstalled = installed
        // hermes_install_failed: fire when the most recent terminal action was install + failed,
        // de-duplicated by stage+result tuple so we don't re-fire on every refresh.
        if lastStage == "install" && lastResult == "failed" && reportedInstallResult != "install:failed" {
            reportedInstallResult = "install:failed"
            TelemetryClient.shared.send(.hermesInstallFailed,
                                        failureReason: fields["last_log_path"] ?? "")
        }
        if lastStage == "install" && lastResult == "success" && reportedInstallResult != "install:success" {
            reportedInstallResult = "install:success"
        }

        var snap = LauncherSnapshot()
        snap.dataDirectory = NSHomeDirectory() + "/.hermes"
        snap.installDirectory = snap.dataDirectory + "/hermes-agent"
        snap.lastAction = fields["last_log_path"].flatMap { $0.isEmpty ? nil : "最近日志：\($0)" } ?? "启动器已就绪"
        snap.webuiURL = fields["webui_url"] ?? snap.webuiURL
        snap.webuiVersion = fields["webui_version"] ?? ""
        snap.webuiPid = fields["webui_pid"] ?? ""
        snap.nodeRuntimeKind = fields["node_runtime_kind"] ?? "missing"
        snap.nodeRuntimeVersion = fields["node_runtime_version"] ?? ""

        // Preserve in-flight launch progress across refreshes.
        if let inflight = self.snapshot.launchProgress, !inflight.isFinished, !inflight.hasFailure {
            snap.launchProgress = inflight
        }

        if !installed {
            snap.primaryButtonTitle = "开始安装"
            snap.primaryAction = "install"
            snap.webuiStatus = "尚未安装"
            snap.heroState = .notInstalled
            snap.stages = [
                StageCardModel(stage: .install, status: .active, stateText: "现在要先完成这一步"),
                StageCardModel(stage: .launch, status: .muted, stateText: "前一步完成后再试")
            ]
        } else if webuiRunning {
            snap.primaryButtonTitle = "在浏览器中打开 WebUI"
            snap.primaryAction = "open-webui"
            snap.webuiStatus = "浏览器对话已在运行"
            snap.heroState = .running
            snap.stages = [
                StageCardModel(stage: .install, status: .complete, stateText: "已完成"),
                StageCardModel(stage: .launch, status: .complete, stateText: "已在运行")
            ]
        } else if snap.launchProgress != nil {
            snap.primaryButtonTitle = "启动浏览器对话"
            snap.primaryAction = "launch"
            snap.webuiStatus = "正在启动"
            snap.heroState = .inProgress
            snap.stages = [
                StageCardModel(stage: .install, status: .complete, stateText: "已完成"),
                StageCardModel(stage: .launch, status: .active, stateText: "正在启动")
            ]
        } else if webuiInstalled {
            snap.primaryButtonTitle = "启动浏览器对话"
            snap.primaryAction = "launch"
            snap.webuiStatus = "已准备，点击后启动"
            snap.heroState = .readyToLaunch
            snap.stages = [
                StageCardModel(stage: .install, status: .complete, stateText: "已完成"),
                StageCardModel(stage: .launch, status: .active, stateText: "现在可以启动")
            ]
        } else {
            snap.primaryButtonTitle = "启动浏览器对话"
            snap.primaryAction = "launch"
            snap.webuiStatus = "首次启动会自动准备"
            snap.heroState = .notInstalled
            snap.stages = [
                StageCardModel(stage: .install, status: .complete, stateText: "已完成"),
                StageCardModel(stage: .launch, status: .active, stateText: "首次启动会自动准备")
            ]
        }

        self.snapshot = snap
        self.isBusy = false
        updateRefreshTimer(isRunningExternalFlow: lastResult == "running")
    }

    // MARK: - Primary action dispatch

    func performPrimaryAction() {
        switch snapshot.primaryAction {
        case "install":
            startInstall()
        case "launch":
            launch()
        case "open-webui":
            openWebUIBrowser()
        default:
            perform(action: snapshot.primaryAction)
        }
    }

    func perform(action: String) {
        switch action {
        case "stop-webui":
            stopWebUI()
        case "restart-webui":
            restartWebUI()
        case "install-webui":
            installWebUIOnly()
        case "open-webui":
            openWebUIBrowser()
        case "open-webui-log":
            // The button label says "查看 Hermes 日志" — the user-relevant log is the gateway's
            // (where messaging-platform debug output goes), not the WebUI daemon's bootstrap log.
            openLog(path: NSHomeDirectory() + "/.hermes/logs/gateway.log")
        case "open-server-log":
            // Reserved: WebUI bootstrap log, not currently surfaced in the UI but available
            // for future "查看 WebUI 启动日志" entry.
            openLog(path: NSHomeDirectory() + "/.hermes-web-ui/server.log")
        case "open-install-log":
            openLog(path: NSHomeDirectory() + "/.hermes/launcher-runtime/install.log")
        case "open-home":
            openLog(path: NSHomeDirectory() + "/.hermes")
        case "doctor":
            runDoctorCheck()
        case "uninstall", "setup", "tools", "update":
            runLauncher(arguments: ["--dispatch-action", action], updateBusy: true) { [weak self] _ in
                self?.refresh()
            }
        default:
            runLauncher(arguments: ["--dispatch-action", action], updateBusy: true) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    // MARK: - Install (Stage-1 install Hermes via Terminal flow)

    private func startInstall() {
        // Telemetry: install kicked off.
        TelemetryClient.shared.send(.hermesInstallStarted)
        runLauncher(arguments: ["--dispatch-action", "install"], updateBusy: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Launch state machine (`--start-webui` push-based parser)

    func launch() {
        guard launchProcess == nil else { return }

        // Telemetry: preflight starts each time the user presses launch. Reset once-flags so
        // webui_started / 5min-kept can fire again for this new session.
        TelemetryClient.shared.clearOnceFlags()
        TelemetryClient.shared.send(.preflightCheck)

        // Clear any persisted mismatch from a previous run; it'll be re-set if the new launch
        // also fails verification.
        snapshot.platformMismatch = nil
        snapshot.launchProgress = makeInitialLaunchProgress()
        snapshot.heroState = .inProgress
        snapshot.webuiStatus = "正在启动"
        // Cancel any prior 5-min timer; a fresh launch resets the proxy clock.
        sessionKept5MinTimer?.invalidate()
        sessionKept5MinTimer = nil
        startElapsedTimer()

        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcherScript.path, "--start-webui"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        stdoutBuffer = ""
        pendingFields = [:]

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.ingestLaunchOutput(chunk: chunk)
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.finishLaunch(exitCode: proc.terminationStatus)
            }
        }

        do {
            try process.run()
            launchProcess = process
        } catch {
            launchProcess = nil
            stopElapsedTimer()
            snapshot.launchProgress = nil
            snapshot.heroState = .error(reason: "process_spawn_failed", message: "无法启动子进程：\(error.localizedDescription)")
        }
    }

    func cancelLaunch() {
        guard let proc = launchProcess, proc.isRunning else { return }
        proc.terminate()
    }

    /// Pre-fill `LaunchProgress` rows 1-4 when the bash ladder will fast-path them
    /// (WebUI already installed at the right version, Node already resolved). The bash side
    /// still emits the same STAGE events and they overwrite these rows on arrival; this just
    /// removes the one-frame "all 7 rows pending" flicker for the "已就绪 待启动" path.
    private func makeInitialLaunchProgress() -> LaunchProgress {
        var progress = LaunchProgress.initial()

        let webuiInstalled = !snapshot.webuiVersion.isEmpty
        let kind = snapshot.nodeRuntimeKind
        let version = snapshot.nodeRuntimeVersion

        guard webuiInstalled else { return progress }

        // Row 1 — Node runtime check.
        progress.rowStatus[0] = .ok
        if kind == "system" || kind == "portable" {
            let kindLabel = kind == "system" ? "系统 Node" : "便携 Node"
            let versionLabel = version.isEmpty ? "" : " \(version)"
            progress.rowDetail[0] = "已就绪（\(kindLabel)\(versionLabel)）"
        } else {
            progress.rowDetail[0] = "已就绪"
        }

        // Rows 2-3 — download / extract Node.
        switch kind {
        case "system":
            progress.rowStatus[1] = .skipped
            progress.rowDetail[1] = "不需要下载"
            progress.rowStatus[2] = .skipped
            progress.rowDetail[2] = "不需要解压"
        case "portable":
            progress.rowStatus[1] = .ok
            progress.rowDetail[1] = "已使用缓存"
            progress.rowStatus[2] = .ok
            progress.rowDetail[2] = "已解压"
        default:
            // Unknown runtime kind — leave rows pending so STAGE events drive them.
            break
        }

        // Row 4 — install hermes-web-ui.
        progress.rowStatus[3] = .ok
        progress.rowDetail[3] = "已是 v\(snapshot.webuiVersion)"

        progress.currentPhase = .startGateway
        return progress
    }

    private func ingestLaunchOutput(chunk: String) {
        stdoutBuffer.append(chunk)
        while let newlineIndex = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[..<newlineIndex])
            stdoutBuffer.removeSubrange(...newlineIndex)
            handleLaunchLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func handleLaunchLine(_ line: String) {
        guard !line.isEmpty else { return }
        if line.hasPrefix("STAGE:") {
            applyStageEvent(line)
            return
        }
        // key=value snapshot delta (buffered, applied on exit).
        if let eqIndex = line.firstIndex(of: "=") {
            let key = String(line[..<eqIndex])
            let value = String(line[line.index(after: eqIndex)...])
            pendingFields[key] = value
        }
    }

    private func applyStageEvent(_ line: String) {
        // Format: STAGE:<phase> STATUS=<s> [DETAIL=...] [PROGRESS=...] [URL=...] [REASON=...] [PLATFORM=...]
        let body = line.dropFirst("STAGE:".count)
        let tokens = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let phaseToken = tokens.first else { return }

        var pairs: [String: String] = [:]
        for token in tokens.dropFirst() {
            if let eqIndex = token.firstIndex(of: "=") {
                pairs[String(token[..<eqIndex])] = String(token[token.index(after: eqIndex)...])
            }
        }
        guard let statusRaw = pairs["STATUS"] else { return }

        // Track A/B events live outside the original 8-phase row enum — handle them first.
        switch phaseToken {
        case "platform_dep", "install_platform_deps", "install_platform_deps_summary",
             "verify_platforms", "gateway_allow_all_users":
            applyPlatformEvent(phaseToken: phaseToken, status: statusRaw, pairs: pairs)
            return
        case "restart_gateway":
            // Telemetry: bash auto-restarts the gateway after installing new messaging deps.
            switch statusRaw {
            case "ok":
                TelemetryClient.shared.send(.gatewayStarted, properties: ["trigger": "post_install"])
            case "failed":
                TelemetryClient.shared.send(.gatewayFailed,
                                            failureReason: pairs["REASON"] ?? "")
            default: break
            }
            return
        default: break
        }

        guard let phase = LaunchProgress.Phase(rawValue: phaseToken) else { return }

        let row = phase.displayRow
        var progress = snapshot.launchProgress ?? .initial()
        let detail = pairs["DETAIL"] ?? ""

        switch statusRaw {
        case "running":
            progress.rowStatus[row] = .running
            progress.currentPhase = phase
            if !detail.isEmpty {
                progress.rowDetail[row] = displayDetail(for: phase, raw: detail)
            }
            if phase == .checkNode, detail.hasPrefix("system_") {
                if progress.rowStatus[1] == .pending { progress.rowStatus[1] = .skipped }
                if progress.rowStatus[2] == .pending { progress.rowStatus[2] = .skipped }
                progress.rowDetail[1] = "不需要下载"
                progress.rowDetail[2] = "不需要解压"
            }
        case "ok":
            progress.rowStatus[row] = .ok
            if !detail.isEmpty {
                progress.rowDetail[row] = displayDetail(for: phase, raw: detail)
            }
            if phase == .checkNode, detail.hasPrefix("system_") {
                if progress.rowStatus[1] != .ok { progress.rowStatus[1] = .skipped }
                if progress.rowStatus[2] != .ok { progress.rowStatus[2] = .skipped }
                progress.rowDetail[1] = "不需要下载"
                progress.rowDetail[2] = "不需要解压"
            }
            if phase == .downloadNode, detail.hasPrefix("cached_") {
                if progress.rowStatus[2] == .pending { progress.rowStatus[2] = .skipped }
                progress.rowDetail[2] = "已使用缓存"
            }
            // Telemetry: webui_started fires when the daemon's /health responds.
            // wait_healthy ok = the explicit "daemon is up" signal from bash;
            // start_webui ok DETAIL=already_running = same daemon was healthy on launch entry.
            if phase == .waitHealthy ||
                (phase == .startWebUI && detail.hasPrefix("already_running")) {
                TelemetryClient.shared.sendOnce(.webuiStarted, properties: [
                    "node_runtime_kind": snapshot.nodeRuntimeKind,
                    "webui_version": snapshot.webuiVersion,
                ])
                schedule5MinKeepAliveTelemetry()
            }
        case "failed":
            progress.rowStatus[row] = .failed
            progress.failureReason = pairs["REASON"]
            if !detail.isEmpty {
                progress.rowDetail[row] = displayDetail(for: phase, raw: detail)
            }
            // Telemetry: webui_failed when start_webui or wait_healthy fails.
            if phase == .startWebUI || phase == .waitHealthy {
                TelemetryClient.shared.send(.webuiFailed,
                                            properties: ["phase": phase.rawValue],
                                            failureReason: pairs["REASON"] ?? "unknown")
            }
        default:
            break
        }

        snapshot.launchProgress = progress
        snapshot.heroState = progress.hasFailure
            ? .error(reason: progress.failureReason ?? "unknown", message: humanMessage(forReason: progress.failureReason ?? "unknown"))
            : .inProgress
    }

    /// Parse Track A/B STAGE events that don't belong to the 8-phase row model. Updates
    /// `progress.platformsState`, `progress.platformStatuses`, and the snapshot's `platformMismatch`.
    private func applyPlatformEvent(phaseToken: String, status: String, pairs: [String: String]) {
        var progress = snapshot.launchProgress ?? .initial()
        let detail = pairs["DETAIL"] ?? ""

        switch phaseToken {
        case "platform_dep":
            // Per-channel install row event.
            guard let label = pairs["PLATFORM"] else { return }
            // Locate or insert into platformStatuses keeping insertion order.
            var idx = progress.platformStatuses.firstIndex(where: { $0.label == label })
            if idx == nil {
                progress.platformStatuses.append(PlatformDepStatus(label: label, state: .verifying, detail: ""))
                idx = progress.platformStatuses.count - 1
            }
            switch status {
            case "running":
                progress.platformStatuses[idx!].state = (detail == "installing") ? .installing : .verifying
                progress.platformStatuses[idx!].detail = detail
            case "ok":
                progress.platformStatuses[idx!].state = (detail == "zero_dep") ? .zeroDep : .ok
                progress.platformStatuses[idx!].detail = detail
            case "failed":
                progress.platformStatuses[idx!].state = .failed
                progress.platformStatuses[idx!].detail = pairs["REASON"] ?? "failed"
            default:
                break
            }
            // Re-derive aggregate stage-2 state from the per-channel statuses.
            recomputePlatformsRunning(into: &progress)

        case "install_platform_deps":
            // Aggregate stage-2 verdict from bash (skipped / ok / failed).
            switch status {
            case "skipped":
                let why = (detail == "no_env" || detail == "no_channels") ? "未启用任何聊天平台" : "无需配置"
                progress.platformsState = .skipped(detail: why)
            case "ok":
                progress.platformsState = .ok(count: progress.platformStatuses.count)
            case "failed":
                let firstFailed = progress.platformStatuses.first(where: { $0.state == .failed })
                let label = firstFailed?.label ?? detail
                let reason = firstFailed?.detail ?? "install_platform_dep_failed"
                progress.platformsState = .failed(label: label, reason: reason)
                progress.failureReason = "install_platform_dep_failed:\(label)"
            default:
                break
            }

        case "install_platform_deps_summary":
            // Got the configured-platforms list; populate the in-progress detail string.
            if let csv = pairs["PLATFORMS"], !csv.isEmpty {
                let names = csv.split(separator: "、").map(String.init)
                progress.platformsList = names
            }

        case "verify_platforms":
            // Track B: only `mismatch_persistent` produces a UI banner; ok/running are silent.
            if status == "mismatch_persistent" {
                let actual = Int(pairs["ACTUAL"] ?? "0") ?? 0
                let configured = Int(pairs["CONFIGURED"] ?? "0") ?? 0
                // ACTUAL includes api_server (1); subtract it so connected = real messaging count.
                let connected = max(0, actual - 1)
                snapshot.platformMismatch = PlatformMismatch(
                    connected: connected,
                    configured: configured,
                    missingNames: []
                )
            }
            // No row-status updates needed — verify happens after launch completes.

        case "gateway_allow_all_users":
            // Cosmetic event; nothing to render.
            break

        default: break
        }

        snapshot.launchProgress = progress
    }

    private func recomputePlatformsRunning(into progress: inout LaunchProgress) {
        // Skip recompute if bash already declared the final aggregate (skipped / ok / failed).
        switch progress.platformsState {
        case .skipped, .ok, .failed: return
        default: break
        }
        if progress.platformStatuses.isEmpty {
            progress.platformsState = .notStarted
            return
        }
        let runningNames = progress.platformStatuses
            .filter { $0.state == .verifying || $0.state == .installing }
            .map(\.label)
        let allDone = progress.platformStatuses.allSatisfy {
            $0.state == .ok || $0.state == .zeroDep
        }
        if let firstFailed = progress.platformStatuses.first(where: { $0.state == .failed }) {
            progress.platformsState = .failed(label: firstFailed.label,
                                              reason: firstFailed.detail)
        } else if !runningNames.isEmpty {
            progress.platformsState = .running(currentNames: runningNames)
        } else if allDone {
            progress.platformsState = .ok(count: progress.platformStatuses.count)
        } else {
            // Mixed pending state — show the discovered names so the user sees progress.
            progress.platformsState = .running(currentNames: progress.platformStatuses.map(\.label))
        }
    }

    private func displayDetail(for phase: LaunchProgress.Phase, raw: String) -> String {
        switch phase {
        case .checkNode:
            if raw == "missing" { return "未找到，准备下载便携版本" }
            if raw.hasPrefix("system_") { return "系统 Node \(raw.dropFirst("system_".count)) 已找到" }
            return raw
        case .downloadNode:
            if raw.hasPrefix("cached_") { return "已下载缓存（\(raw.dropFirst("cached_".count))）" }
            return raw
        case .installWebUI:
            return "正在通过 npm 安装 \(raw)"
        default:
            return raw
        }
    }

    /// Schedule the 5-minute keep-alive event. After webui_started, if `/health` still responds
    /// 5 minutes later, fire `webui_session_kept_5min` once. This is the "did the user actually
    /// use the WebUI" proxy event — the launcher can't observe browser activity.
    private func schedule5MinKeepAliveTelemetry() {
        sessionKept5MinTimer?.invalidate()
        sessionKept5MinTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Only fire if WebUI is still actually running (defensive).
                if self.snapshot.heroState == .running {
                    TelemetryClient.shared.sendOnce(.webuiSessionKept5Min)
                }
            }
        }
    }

    private func finishLaunch(exitCode: Int32) {
        stdoutBuffer = ""
        launchProcess = nil
        stopElapsedTimer()

        var progress = snapshot.launchProgress
        if exitCode != 0 {
            // Convert any still-running rows to failed and keep the recorded reason.
            if var p = progress {
                for idx in 0..<p.rowStatus.count where p.rowStatus[idx] == .running {
                    p.rowStatus[idx] = .failed
                    if p.failureReason == nil { p.failureReason = "exit_\(exitCode)" }
                }
                progress = p
            }
            snapshot.launchProgress = progress
            let reason = progress?.failureReason ?? "exit_\(exitCode)"
            snapshot.heroState = .error(reason: reason, message: humanMessage(forReason: reason))
            // Telemetry: catch-all fail event when we don't have a more specific webui_failed.
            // (Specific phase failures already reported in applyStageEvent.)
            if !["health_timeout", "bin_exit_1", "bin_missing"].contains(where: reason.contains) {
                TelemetryClient.shared.send(.unexpectedError,
                                            properties: ["context": "finish_launch"],
                                            failureReason: reason)
            }
            return
        }

        // Successful launch: refresh from --state-test so we transition to the running hero.
        snapshot.launchProgress = nil
        refresh()
    }

    // MARK: - Stop / restart / install-only

    func stopWebUI() {
        runLauncher(arguments: ["--stop-webui"], updateBusy: false) { [weak self] _ in
            self?.refresh()
        }
    }

    func restartWebUI() {
        runLauncher(arguments: ["--stop-webui"], updateBusy: false) { [weak self] _ in
            self?.launch()
        }
    }

    private func installWebUIOnly() {
        runLauncher(arguments: ["--install-webui"], updateBusy: false) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Browser open

    /// Open the running WebUI in the user's default browser.
    /// Composes the token-bearing URL directly: `http://localhost:8648/#/?token=<sha>`.
    /// Falls back to plain URL if the token file is missing.
    /// If the daemon is NOT running, we trigger a launch instead (no point opening a dead URL).
    func openWebUIBrowser() {
        guard snapshot.heroState == .running else {
            // Daemon isn't up yet — kick off the launch flow instead. The simplified
            // 3-row checklist will animate; on success the running hero re-appears and the
            // user can click again.
            launch()
            return
        }
        let base = snapshot.webuiURL.isEmpty ? "http://localhost:8648" : snapshot.webuiURL
        let tokenPath = NSHomeDirectory() + "/.hermes-web-ui/.token"
        let composed: String
        if let raw = try? String(contentsOfFile: tokenPath, encoding: .utf8) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                composed = base
            } else {
                composed = "\(base)/#/?token=\(token)"
            }
        } else {
            composed = base
        }
        guard let url = URL(string: composed) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Open a log file (or any path) using the user's default handler.
    /// If the path doesn't exist, opens the parent directory in Finder so the user can browse,
    /// and surfaces a non-fatal warning. Both branches handle tilde expansion.
    func openLog(path: String) {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let fm = FileManager.default

        if fm.fileExists(atPath: expanded) {
            if NSWorkspace.shared.open(url) { return }
            lastError = "无法打开 \(expanded)。已尝试用默认应用打开但失败。"
            return
        }

        // Fall back to parent directory.
        let parent = (expanded as NSString).deletingLastPathComponent
        if fm.fileExists(atPath: parent) {
            NSWorkspace.shared.open(URL(fileURLWithPath: parent))
            lastError = "日志文件还不存在：\n\(expanded)\n\n已经打开它的父目录。"
        } else {
            lastError = "日志文件还不存在：\n\(expanded)"
        }
    }

    // MARK: - Doctor (unchanged shape from prior version, light-weight)

    private func runDoctorCheck() {
        runLauncher(arguments: ["--doctor-test"], updateBusy: true) { [weak self] output in
            self?.applyDoctorResult(output: output)
        }
    }

    private func applyDoctorResult(output: String) {
        let fields = parseKeyValueLines(output)
        let status = fields["status"] ?? "failed"
        let logPath = fields["log_path"] ?? ""

        switch status {
        case "ok":
            resultCard = LauncherResultCard(
                tone: .success,
                title: "现在可以正常使用",
                message: "Hermes 的基础检查已经通过。\(logPath.isEmpty ? "" : "\n\n详细记录已保存到：\(logPath)")",
                primaryActionTitle: "在浏览器中打开 WebUI",
                primaryActionID: "open-webui",
                secondaryActionTitle: nil,
                secondaryActionID: nil
            )
        case "missing":
            resultCard = LauncherResultCard(
                tone: .warning,
                title: "还没有检测到 Hermes",
                message: "这台 Mac 上还没有检测到可用的 Hermes。请先完成安装。",
                primaryActionTitle: "继续安装",
                primaryActionID: "install",
                secondaryActionTitle: nil,
                secondaryActionID: nil
            )
        default:
            resultCard = LauncherResultCard(
                tone: .warning,
                title: "现在还不能正常使用",
                message: "这次检查没有通过。\(logPath.isEmpty ? "" : "\n\n详细记录已保存到：\(logPath)")",
                primaryActionTitle: "重新走一遍设置",
                primaryActionID: "setup",
                secondaryActionTitle: "打开问题记录",
                secondaryActionID: "open_logs"
            )
        }

        isBusy = false
        refresh()
    }

    // MARK: - Reason → human message (proposal §4.3)

    func humanMessage(forReason reason: String) -> String {
        // Track A: per-platform install failure. Format: install_platform_dep_failed:<label>
        if reason.hasPrefix("install_platform_dep_failed:") {
            let label = reason.dropFirst("install_platform_dep_failed:".count)
            return "\(label) 配置失败，可重试或查看日志"
        }
        if reason == "install_platform_dep_failed" {
            return "聊天平台配置失败，可重试或查看日志"
        }
        // Track B: post-launch verify mismatch (banner, not a hero error).
        if reason == "verify_platforms_mismatch_persistent" {
            return "部分聊天工具未连接，可查看安装日志"
        }
        if reason.hasPrefix("npm_install_failed_") {
            let exit = reason.dropFirst("npm_install_failed_".count)
            return "没法连上下载源，请检查网络后重试（npm 退出码 \(exit)）"
        }
        if reason.hasPrefix("version_mismatch_") {
            let got = reason.dropFirst("version_mismatch_".count)
            return "WebUI 版本不匹配（实际 \(got)），请重试"
        }
        if reason.hasPrefix("curl_") {
            return "网络不通畅，刚才试了 3 次都没成功"
        }
        if reason.hasPrefix("tar_") {
            return "运行环境解压失败，已清理临时文件，请重试"
        }
        if reason.hasPrefix("unsupported_arch_") {
            return "当前 CPU 架构暂不支持便携运行环境"
        }
        switch reason {
        case "node_not_found":
            return "运行环境缺失，准备下载…"
        case "node_download_failed":
            return "网络不通畅，刚才试了 3 次都没成功"
        case "node_extract_failed":
            return "运行环境解压失败，已清理临时文件，请重试"
        case "sha256_mismatch":
            return "运行环境下载校验失败，已删除文件，请重试"
        case "bin_missing":
            return "安装完成但找不到启动入口，请重试"
        case "node_not_resolved":
            return "运行环境未就绪，无法继续"
        case "system_node_broken", "portable_node_broken":
            return "运行环境无法运行，请重试或查看日志"
        case "gateway_failed":
            return "Hermes 这次没启动起来，请重试"
        case "webui_failed":
            return "Hermes 这次没启动起来，请重试"
        case "health_timeout":
            return "已启动但 30 秒内还没准备好，可重试或查看日志"
        case "missing_binaries":
            return "运行环境缺少必要文件，可重试"
        default:
            return "出现未知错误：\(reason)"
        }
    }

    // MARK: - Process plumbing

    private func runLauncher(arguments: [String], updateBusy: Bool, completion: @escaping (String) -> Void) {
        if updateBusy {
            isBusy = true
        }

        let process = Process()
        process.currentDirectoryURL = projectRoot
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcherScript.path] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        process.terminationHandler = { [weak self] proc in
            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData + errorData, encoding: .utf8) ?? ""

            Task { @MainActor in
                if proc.terminationStatus != 0 && !arguments.contains("--dispatch-action") {
                    self?.lastError = output.isEmpty ? "执行失败（退出码 \(proc.terminationStatus)）。" : output
                }
                completion(output)
            }
        }

        do {
            try process.run()
        } catch {
            self.lastError = error.localizedDescription
            self.isBusy = false
        }
    }

    private func parseKeyValueLines(_ output: String) -> [String: String] {
        var fields: [String: String] = [:]
        output.split(separator: "\n").forEach { line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                fields[parts[0]] = parts[1]
            }
        }
        return fields
    }

    private func updateRefreshTimer(isRunningExternalFlow: Bool) {
        if isRunningExternalFlow {
            guard refreshTimer == nil else { return }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isBusy else { return }
                    self.refresh()
                }
            }
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func startElapsedTimer() {
        elapsedSeconds = 0
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}
