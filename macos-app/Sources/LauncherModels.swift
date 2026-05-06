import Foundation
import SwiftUI

// MARK: - Stage

enum LauncherStage: Int, CaseIterable, Identifiable {
    case install = 1
    case launch = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .install: return "安装 Hermes"
        case .launch: return "启动浏览器对话"
        }
    }

    var detail: String {
        switch self {
        case .install: return "把 Hermes 装到这台 Mac 上，装好后才能继续。"
        case .launch: return "启动浏览器对话界面，并在浏览器里完成模型配置。"
        }
    }
}

enum StageStatus: String {
    case complete
    case active
    case muted

    var label: String {
        switch self {
        case .complete: return "已完成"
        case .active: return "当前步骤"
        case .muted: return "稍后进行"
        }
    }
}

struct StageCardModel: Identifiable {
    let stage: LauncherStage
    let status: StageStatus
    let stateText: String

    var id: LauncherStage { stage }

    var shortTitle: String {
        switch stage {
        case .install: return "安装"
        case .launch: return "对话"
        }
    }

    var symbolName: String {
        switch stage {
        case .install: return "shippingbox.fill"
        case .launch: return "safari.fill"
        }
    }
}

// MARK: - Launch progress (state-2 in-progress checklist)

struct LaunchProgress: Equatable {
    enum Phase: String, CaseIterable {
        case checkNode = "check_node"
        case downloadNode = "download_node"
        case extractNode = "extract_node"
        case installWebUI = "install_webui"
        case startGateway = "start_gateway"
        case waitGatewayHealthy = "wait_gateway_healthy"
        case startWebUI = "start_webui"
        case waitHealthy = "wait_healthy"

        /// Map an 8-phase pipeline onto the 7-row design checklist.
        /// `startWebUI` and `waitHealthy` share the last row.
        var displayRow: Int {
            switch self {
            case .checkNode: return 0
            case .downloadNode: return 1
            case .extractNode: return 2
            case .installWebUI: return 3
            case .startGateway: return 4
            case .waitGatewayHealthy: return 5
            case .startWebUI, .waitHealthy: return 6
            }
        }

        var rowTitle: String {
            switch self {
            case .checkNode: return "检查 Node.js 运行时"
            case .downloadNode: return "下载 Node.js"
            case .extractNode: return "解压 Node.js 运行时"
            case .installWebUI: return "安装 hermes-web-ui"
            case .startGateway: return "启动 Hermes 网关"
            case .waitGatewayHealthy: return "等待网关健康"
            case .startWebUI, .waitHealthy: return "启动 WebUI 并健康检查"
            }
        }
    }

    enum Status: String, Equatable {
        case pending
        case running
        case ok
        case skipped
        case failed
    }

    /// One status per display row (7 rows).
    var rowStatus: [Status]
    var rowDetail: [String]
    var currentPhase: Phase?
    var failureReason: String?
    var startedAt: Date

    /// Stage 2 (configure chat platforms) state for the simplified 3-row checklist.
    /// Driven by `STAGE:install_platform_deps` + `STAGE:platform_dep` + `STAGE:install_platform_deps_summary` events.
    var platformsState: PlatformDepsState = .notStarted
    /// Per-platform install status, ordered by .env-discovery order. Used for the in-progress detail string
    /// "正在配置：飞书、Telegram" and for failed-platform name extraction.
    var platformStatuses: [PlatformDepStatus] = []
    /// Comma-list of configured platform pretty names from the summary STAGE event (empty before summary).
    var platformsList: [String] = []

    static func initial() -> LaunchProgress {
        LaunchProgress(
            rowStatus: Array(repeating: .pending, count: 7),
            rowDetail: Array(repeating: "", count: 7),
            currentPhase: nil,
            failureReason: nil,
            startedAt: Date()
        )
    }

    var isFinished: Bool {
        rowStatus.allSatisfy { $0 == .ok || $0 == .skipped }
    }

    var hasFailure: Bool {
        rowStatus.contains(.failed)
    }

    // MARK: Simplified 3-row aggregator (per v2 final design §2d)

    /// Aggregate-status of a simplified row.
    enum AggregateStatus: Equatable {
        case pending
        case running
        case skipped
        case done
        case failed(reason: String)
    }

    struct SimplifiedRow: Identifiable, Equatable {
        enum Kind: String { case prepareEnv, configureChats, startService }
        let id: String
        let kind: Kind
        let title: String
        let status: AggregateStatus
        let detail: String
    }

    /// Stage 1 — 准备运行环境. Aggregates check_node + download_node + extract_node + install_webui.
    private func aggregatePrepareEnv() -> SimplifiedRow {
        let indices = [0, 1, 2, 3]                       // rowStatus indices for those four phases
        let states = indices.map { rowStatus[$0] }
        let allDone = states.allSatisfy { $0 == .ok || $0 == .skipped }
        let anyFailed = states.contains(.failed)
        let anyRunning = states.contains(.running)
        let anyOk = states.contains(.ok)
        let detail: String
        if anyFailed {
            // Find the failing row's detail.
            let i = indices.first(where: { rowStatus[$0] == .failed }) ?? 0
            detail = rowDetail[i].isEmpty ? "准备失败" : rowDetail[i]
            return SimplifiedRow(id: "prepare", kind: .prepareEnv, title: "准备运行环境",
                                 status: .failed(reason: detail), detail: detail)
        }
        if anyRunning {
            // Pick the running row's detail; fall back to a generic phrase.
            let i = indices.first(where: { rowStatus[$0] == .running }) ?? 3
            detail = rowDetail[i].isEmpty ? "第一次会需要联网下载，请稍候" : rowDetail[i]
            return SimplifiedRow(id: "prepare", kind: .prepareEnv, title: "准备运行环境",
                                 status: .running, detail: detail)
        }
        if allDone && anyOk {
            return SimplifiedRow(id: "prepare", kind: .prepareEnv, title: "准备运行环境",
                                 status: .done, detail: "已就绪")
        }
        return SimplifiedRow(id: "prepare", kind: .prepareEnv, title: "准备运行环境",
                             status: .pending, detail: "")
    }

    /// Stage 2 — 配置聊天工具. Driven by .env-scan results + per-platform pip events.
    private func aggregateConfigureChats() -> SimplifiedRow {
        switch platformsState {
        case .notStarted:
            return SimplifiedRow(id: "chats", kind: .configureChats, title: "配置聊天工具",
                                 status: .pending, detail: "")
        case .skipped(let detail):
            let copy = detail.isEmpty ? "未启用任何聊天平台" : detail
            return SimplifiedRow(id: "chats", kind: .configureChats, title: "配置聊天工具",
                                 status: .skipped, detail: copy)
        case .running(let names):
            let copy = names.isEmpty ? "正在配置聊天工具" : "正在配置：\(names.joined(separator: "、"))"
            return SimplifiedRow(id: "chats", kind: .configureChats, title: "配置聊天工具",
                                 status: .running, detail: copy)
        case .ok(let count):
            return SimplifiedRow(id: "chats", kind: .configureChats, title: "配置聊天工具",
                                 status: .done, detail: "已配置 \(count) 个聊天平台")
        case .failed(let label, _):
            let copy = "\(label) 配置失败"
            return SimplifiedRow(id: "chats", kind: .configureChats, title: "配置聊天工具",
                                 status: .failed(reason: copy), detail: copy)
        }
    }

    /// Stage 3 — 启动 Hermes 服务. Aggregates start_webui + wait_healthy + verify_platforms (the bash side
    /// no longer emits start_gateway / wait_gateway_healthy as separate events; those are inside `start_webui`).
    /// Verify-platforms mismatch is a *non-fatal* warning surfaced via the running hero banner — not on this row.
    private func aggregateStartService() -> SimplifiedRow {
        let indices = [6]                                // rowStatus[6] is start_webui+wait_healthy aggregate
        let states = indices.map { rowStatus[$0] }
        let anyFailed = states.contains(.failed)
        let anyRunning = states.contains(.running)
        let anyOk = states.contains(.ok)
        if anyFailed {
            let i = indices.first(where: { rowStatus[$0] == .failed }) ?? 6
            let detail = rowDetail[i].isEmpty ? "启动失败" : rowDetail[i]
            return SimplifiedRow(id: "start", kind: .startService, title: "启动 Hermes 服务",
                                 status: .failed(reason: detail), detail: detail)
        }
        if anyRunning {
            let detail = "正在拉起后台进程"
            return SimplifiedRow(id: "start", kind: .startService, title: "启动 Hermes 服务",
                                 status: .running, detail: detail)
        }
        if anyOk {
            return SimplifiedRow(id: "start", kind: .startService, title: "启动 Hermes 服务",
                                 status: .done, detail: "已启动")
        }
        return SimplifiedRow(id: "start", kind: .startService, title: "启动 Hermes 服务",
                             status: .pending, detail: "")
    }

    var simplifiedRows: [SimplifiedRow] {
        [aggregatePrepareEnv(), aggregateConfigureChats(), aggregateStartService()]
    }

    /// Headline for the in-progress hero (top-of-checklist text). Picks the first running aggregated
    /// row, or a generic fallback.
    var headlineFromSimplified: String {
        for row in simplifiedRows {
            if case .running = row.status {
                switch row.kind {
                case .prepareEnv: return "正在准备运行环境…"
                case .configureChats: return "正在配置聊天工具…"
                case .startService: return "正在启动 Hermes 服务…"
                }
            }
        }
        return "启动浏览器对话…"
    }

    /// Currently-active simplified row index (1-based for "第 N 步" display), or nil if all idle/done.
    var simplifiedStepIndex: Int? {
        for (idx, row) in simplifiedRows.enumerated() {
            if case .running = row.status {
                return idx + 1
            }
        }
        return nil
    }
}

// MARK: Stage 2 (platform deps) state model

enum PlatformDepsState: Equatable {
    case notStarted
    /// `.env` had zero configured channels OR pre-checks ran and nothing required install.
    case skipped(detail: String)
    /// At least one channel is being verified/installed. `currentNames` is the discovered channel
    /// list so far (used for the in-progress detail string).
    case running(currentNames: [String])
    /// All discovered channels finished successfully.
    case ok(count: Int)
    /// At least one channel failed. `failedLabel` is the first failing channel's pretty name; `reason`
    /// is the bash REASON= field for diagnostics.
    case failed(label: String, reason: String)
}

struct PlatformDepStatus: Equatable, Identifiable {
    enum State: String, Equatable { case verifying, installing, ok, failed, zeroDep }
    let label: String
    var state: State
    var detail: String
    var id: String { label }
}

// MARK: Platform mismatch (state-3 banner)

struct PlatformMismatch: Equatable {
    let connected: Int
    let configured: Int
    let missingNames: [String]   // empty when bash didn't report names
}

// MARK: - Hero state routing

enum LauncherHeroState: Equatable {
    case notInstalled
    case readyToLaunch
    case inProgress
    case running
    case error(reason: String, message: String)
    case networkBlocked
}

// MARK: - Snapshot

struct LauncherSnapshot {
    var version = "macOS v2026.05.06.5"
    var primaryButtonTitle = "开始安装"
    var primaryAction = "install"
    var webuiStatus = "未准备"
    var webuiURL = "http://localhost:8648"
    var webuiVersion: String = ""
    var webuiPid: String = ""
    var nodeRuntimeKind: String = "missing"
    var nodeRuntimeVersion: String = ""
    var dataDirectory = "~/.hermes"
    var installDirectory = "~/.hermes/hermes-agent"
    var lastAction = "启动器已就绪"
    var heroState: LauncherHeroState = .notInstalled
    var launchProgress: LaunchProgress?
    /// Set when verify_platforms emits mismatch_persistent. Cleared on next clean launch.
    var platformMismatch: PlatformMismatch?
    var stages: [StageCardModel] = [
        StageCardModel(stage: .install, status: .active, stateText: "未开始"),
        StageCardModel(stage: .launch, status: .muted, stateText: "尚不可用")
    ]

    /// "WebUI 0.5.9 · Node v23.11.0 (system)" — footer left text.
    var runtimeBadge: String {
        var parts: [String] = []
        if !webuiVersion.isEmpty {
            parts.append("WebUI \(webuiVersion)")
        }
        if !nodeRuntimeVersion.isEmpty {
            let kind = nodeRuntimeKind == "missing" ? "" : " (\(nodeRuntimeKind))"
            parts.append("Node \(nodeRuntimeVersion)\(kind)")
        }
        if parts.isEmpty {
            parts.append("尚未检测运行时")
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Bottom-right footer status pill text — short.
    var heroStatusBadge: String {
        switch heroState {
        case .notInstalled: return "未安装"
        case .readyToLaunch: return "已就绪 待启动"
        case .inProgress: return "正在启动"
        case .running: return "运行中"
        case .error: return "启动遇到问题"
        case .networkBlocked: return "网络检查未通过"
        }
    }
}

// MARK: - Result card (kept for doctor + ad-hoc warnings)

enum LauncherResultTone {
    case success
    case warning
    case info
}

struct LauncherResultCard {
    let tone: LauncherResultTone
    let title: String
    let message: String
    let primaryActionTitle: String?
    let primaryActionID: String?
    let secondaryActionTitle: String?
    let secondaryActionID: String?
}
