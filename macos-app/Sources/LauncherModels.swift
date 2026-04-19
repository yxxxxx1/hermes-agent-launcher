import Foundation
import SwiftUI

enum LauncherStage: Int, CaseIterable, Identifiable {
    case install = 1
    case model = 2
    case chat = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .install: return "安装 Hermes"
        case .model: return "配置模型"
        case .chat: return "开始第一次对话"
        }
    }

    var detail: String {
        switch self {
        case .install:
            return "把 Hermes 装到这台 Mac 上，装好后才能继续下一步。"
        case .model:
            return "把 AI 服务接好。填完后，Hermes 才能开始回答你。"
        case .chat:
            return "打开浏览器对话窗口，确认 Hermes 现在已经能用了。"
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
        case .model: return "模型"
        case .chat: return "对话"
        }
    }

    var symbolName: String {
        switch stage {
        case .install: return "shippingbox.fill"
        case .model: return "slider.horizontal.3"
        case .chat: return "safari.fill"
        }
    }

    var accentColor: Color {
        switch status {
        case .complete:
            return Color(red: 0.15, green: 0.68, blue: 0.56)
        case .active:
            return Color(red: 0.82, green: 0.60, blue: 0.25)
        case .muted:
            return Color.white.opacity(0.42)
        }
    }
}

struct LauncherSnapshot {
    var version = "macOS v2026.04.19.1"
    var currentStep = "继续安装"
    var primaryButtonTitle = "继续安装"
    var primaryAction = "install"
    var aiProvider = "未配置"
    var aiModel = "未配置"
    var chatAvailability = "暂不可用"
    var webuiStatus = "未准备"
    var webuiURL = "http://localhost:8787"
    var gatewayStatus = "暂未配置"
    var gatewayChannel = "未配置"
    var supportSummary = "日常使用暂不需要"
    var dataDirectory = "~/.hermes"
    var installDirectory = "~/.hermes/hermes-agent"
    var lastAction = "启动器已就绪"
    var stages: [StageCardModel] = [
        StageCardModel(stage: .install, status: .active, stateText: "未开始"),
        StageCardModel(stage: .model, status: .muted, stateText: "等待安装完成"),
        StageCardModel(stage: .chat, status: .muted, stateText: "尚不可用")
    ]
}

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
