import Foundation
import AppKit

@MainActor
final class LauncherStore: ObservableObject {
    @Published var snapshot = LauncherSnapshot()
    @Published var isBusy = false
    @Published var showsBusyOverlay = false
    @Published var busyOverlayDismissible = false
    @Published var busyMessage = "正在准备"
    @Published var lastError: String?
    @Published var resultCard: LauncherResultCard?

    private let projectRoot: URL
    private let launcherScript: URL
    private var refreshTimer: Timer?

    init(projectRoot: URL = LauncherStore.resolveProjectRoot()) {
        self.projectRoot = projectRoot
        self.launcherScript = projectRoot.appendingPathComponent("HermesMacGuiLauncher.command")
        refresh()
    }

    deinit {
        refreshTimer?.invalidate()
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

    func refresh() {
        busyMessage = "正在刷新状态"
        runLauncher(arguments: ["--state-test"], updateBusy: false) { [weak self] output in
            self?.apply(stateTestOutput: output)
        }
    }

    func performPrimaryAction() {
        perform(action: snapshot.primaryAction)
    }

    func perform(action: String) {
        if action == "doctor" {
            runDoctorCheck()
            return
        }

        busyMessage = "正在执行 \(action)"
        runLauncher(arguments: ["--dispatch-action", action], updateBusy: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func runDoctorCheck() {
        busyMessage = "正在检查现在能不能正常用"
        showsBusyOverlay = true
        busyOverlayDismissible = true
        runLauncher(arguments: ["--doctor-test"], updateBusy: true) { [weak self] output in
            self?.applyDoctorResult(output: output)
        }
    }

    private func apply(stateTestOutput output: String) {
        var fields: [String: String] = [:]
        output
            .split(separator: "\n")
            .forEach { line in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    fields[parts[0]] = parts[1]
                }
            }

        let installed = fields["installed"] == "true"
        let modelReady = fields["model_ready"] == "true"
        let gatewayConfigured = fields["gateway_configured"] == "true"
        let gatewayRunning = fields["gateway_running"] == "true"
        let lastResult = fields["last_result"] ?? "idle"

        var snapshot = LauncherSnapshot()
        snapshot.dataDirectory = NSHomeDirectory() + "/.hermes"
        snapshot.installDirectory = snapshot.dataDirectory + "/hermes-agent"
        snapshot.lastAction = fields["last_log_path"].flatMap { $0.isEmpty ? nil : "最近日志：\($0)" } ?? "启动器已就绪"
        snapshot.aiProvider = detectProvider()
        snapshot.aiModel = detectModel()
        snapshot.gatewayChannel = detectGatewayChannel()
        snapshot.chatAvailability = modelReady ? "可以开始" : "暂不可用"

        if !installed {
            snapshot.currentStep = "继续安装"
            snapshot.primaryButtonTitle = "继续安装"
            snapshot.primaryAction = "install"
            snapshot.chatAvailability = "安装后可用"
            snapshot.stages = [
                StageCardModel(stage: .install, status: .active, stateText: "现在要先完成这一步"),
                StageCardModel(stage: .model, status: .muted, stateText: "装好后再继续"),
                StageCardModel(stage: .chat, status: .muted, stateText: "前两步完成后再试")
            ]
        } else if !modelReady {
            snapshot.currentStep = "继续配置模型"
            snapshot.primaryButtonTitle = "继续配置模型"
            snapshot.primaryAction = "model"
            snapshot.chatAvailability = "配置 AI 后可用"
            snapshot.stages = [
                StageCardModel(stage: .install, status: .complete, stateText: "这一步已经完成了"),
                StageCardModel(stage: .model, status: .active, stateText: "现在要填好 AI 设置"),
                StageCardModel(stage: .chat, status: .muted, stateText: "设置好后再试")
            ]
        } else {
            snapshot.currentStep = "开始第一次对话"
            snapshot.primaryButtonTitle = "开始第一次对话"
            snapshot.primaryAction = "chat"
            snapshot.supportSummary = "可选，用于维护与消息渠道"
            snapshot.stages = [
                StageCardModel(stage: .install, status: .complete, stateText: "这一步已经完成了"),
                StageCardModel(stage: .model, status: .complete, stateText: "这一步已经完成了"),
                StageCardModel(stage: .chat, status: .active, stateText: "现在可以直接开始")
            ]
        }

        if gatewayConfigured {
            snapshot.gatewayStatus = gatewayRunning ? "已配置，当前在线" : "已配置"
        } else {
            snapshot.gatewayStatus = "未配置"
        }

        self.snapshot = snapshot
        self.isBusy = false
        self.showsBusyOverlay = false
        self.busyOverlayDismissible = false
        updateRefreshTimer(isRunningExternalFlow: lastResult == "running")
    }

    private func detectProvider() -> String {
        let configPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/config.yaml").path
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return "未配置"
        }

        if let provider = firstMatch(in: content, pattern: #"(?m)^[ \t]+provider:[ \t]*([^\n#]+)"#) {
            return sanitizeConfigValue(provider)
        }

        return "未配置"
    }

    private func detectModel() -> String {
        let configPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/config.yaml").path
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return "未配置"
        }

        if let model = firstMatch(in: content, pattern: #"(?m)^[ \t]+default:[ \t]*([^\n#]+)"#) {
            return sanitizeConfigValue(model)
        }

        if let model = firstMatch(in: content, pattern: #"(?m)^[ \t]+model:[ \t]*([^\n#]+)"#) {
            return sanitizeConfigValue(model)
        }

        return "未配置"
    }

    private func detectGatewayChannel() -> String {
        let envPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/.env").path
        guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else {
            return "未配置"
        }

        let mappings: [(String, String)] = [
            ("TELEGRAM_BOT_TOKEN", "Telegram"),
            ("DISCORD_BOT_TOKEN", "Discord"),
            ("SLACK_BOT_TOKEN", "Slack"),
            ("WEIXIN_ACCOUNT_ID", "微信"),
            ("WHATSAPP_ENABLED", "WhatsApp"),
            ("MATRIX_HOMESERVER_URL", "Matrix"),
            ("DINGTALK_CLIENT_ID", "钉钉"),
            ("FEISHU_APP_ID", "飞书"),
            ("WECOM_BOT_ID", "企业微信"),
            ("BLUEBUBBLES_SERVER_URL", "BlueBubbles")
        ]

        let configured = mappings.compactMap { key, label in
            content.contains("\(key)=") ? label : nil
        }

        return configured.isEmpty ? "未配置" : configured.joined(separator: " / ")
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let resultRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[resultRange])
    }

    private func sanitizeConfigValue(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private func applyDoctorResult(output: String) {
        var fields: [String: String] = [:]
        output
            .split(separator: "\n")
            .forEach { line in
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    fields[parts[0]] = parts[1]
                }
            }

        let status = fields["status"] ?? "failed"
        let logPath = fields["log_path"] ?? ""
        let modelName = snapshot.aiModel == "未配置" ? "当前模型" : snapshot.aiModel

        switch status {
        case "ok":
            resultCard = LauncherResultCard(
                tone: .success,
                title: "现在可以正常使用",
                message: """
                Hermes 的基础检查已经通过。你现在可以直接开始和它对话。

                当前会使用 \(modelName)。
                \(logPath.isEmpty ? "" : "\n详细记录已保存到：\(logPath)")
                """,
                primaryActionTitle: "开始对话",
                primaryActionID: "chat",
                secondaryActionTitle: nil,
                secondaryActionID: nil
            )
        case "missing":
            resultCard = LauncherResultCard(
                tone: .warning,
                title: "还没有检测到 Hermes",
                message: "这台 Mac 上还没有检测到可用的 Hermes。请先完成安装，再回来检查是否正常。",
                primaryActionTitle: "继续安装",
                primaryActionID: "install",
                secondaryActionTitle: nil,
                secondaryActionID: nil
            )
        default:
            resultCard = LauncherResultCard(
                tone: .warning,
                title: "现在还不能正常使用",
                message: """
                这次检查没有通过。通常先重新走一遍设置，就能补齐缺失的配置。
                \(logPath.isEmpty ? "" : "\n详细记录已保存到：\(logPath)")
                """,
                primaryActionTitle: "重新走一遍设置",
                primaryActionID: "setup",
                secondaryActionTitle: "打开问题记录",
                secondaryActionID: "open_logs",
            )
        }

        isBusy = false
        showsBusyOverlay = false
        busyOverlayDismissible = false
        refresh()
    }

    private func runLauncher(arguments: [String], updateBusy: Bool, completion: @escaping (String) -> Void) {
        if updateBusy {
            isBusy = true
            showsBusyOverlay = true
            busyOverlayDismissible = false
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
            self.showsBusyOverlay = false
            self.busyOverlayDismissible = false
        }
    }

    func dismissBusyOverlay() {
        guard busyOverlayDismissible else { return }
        showsBusyOverlay = false
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
}
