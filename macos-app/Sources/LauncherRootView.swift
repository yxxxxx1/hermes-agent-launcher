import SwiftUI

private enum LauncherPalette {
    static let bgApp = Color(red: 0.95, green: 0.94, blue: 0.91)
    static let bgAppSecondary = Color(red: 0.92, green: 0.91, blue: 0.88)
    static let bgGlow = Color(red: 0.96, green: 0.79, blue: 0.54)

    static let surfacePrimary = Color(red: 0.98, green: 0.97, blue: 0.95)
    static let surfaceSecondary = Color(red: 0.96, green: 0.94, blue: 0.91)
    static let surfaceTertiary = Color(red: 0.94, green: 0.91, blue: 0.87)
    static let surfaceHover = Color(red: 0.95, green: 0.90, blue: 0.84)

    static let textPrimary = Color(red: 0.15, green: 0.15, blue: 0.13)
    static let textSecondary = Color(red: 0.37, green: 0.35, blue: 0.31)
    static let textTertiary = Color(red: 0.54, green: 0.50, blue: 0.46)
    static let textOnAccent = Color(red: 0.99, green: 0.99, blue: 0.97)

    static let accentPrimary = Color(red: 0.85, green: 0.47, blue: 0.17)
    static let accentSoft = Color(red: 0.95, green: 0.71, blue: 0.42)
    static let accentDeep = Color(red: 0.66, green: 0.33, blue: 0.12)

    static let success = Color(red: 0.31, green: 0.56, blue: 0.48)
    static let successSoft = Color(red: 0.86, green: 0.93, blue: 0.90)
    static let warning = Color(red: 0.78, green: 0.54, blue: 0.23)
    static let warningSoft = Color(red: 0.96, green: 0.91, blue: 0.82)
    static let danger = Color(red: 0.76, green: 0.37, blue: 0.32)
    static let dangerSoft = Color(red: 0.97, green: 0.88, blue: 0.85)

    static let lineSoft = Color.black.opacity(0.06)
    static let lineSofter = Color.black.opacity(0.04)
}

struct LauncherRootView: View {
    @ObservedObject var store: LauncherStore
    @State private var showsAdvancedTools = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeStage: StageCardModel {
        store.snapshot.stages.first(where: { $0.status == .active }) ?? store.snapshot.stages[0]
    }

    private var completedCount: Int {
        store.snapshot.stages.filter { $0.status == .complete }.count
    }

    private var isSetupFinished: Bool {
        store.snapshot.stages.dropLast().allSatisfy { $0.status == .complete }
    }

    private var targetWindowSize: CGSize {
        isSetupFinished ? CGSize(width: 820, height: 660) : CGSize(width: 920, height: 760)
    }

    var body: some View {
        ZStack {
            LauncherBackdrop()
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 22) {
                    TopBanner(snapshot: store.snapshot, isSetupFinished: isSetupFinished)

                    if isSetupFinished {
                        ManagementHome(store: store)
                            .transition(screenTransition)
                    } else {
                        SetupHome(
                            store: store,
                            activeStage: activeStage,
                            completedCount: completedCount,
                            showsAdvancedTools: $showsAdvancedTools
                        )
                        .transition(screenTransition)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88), value: store.snapshot.primaryAction)
            }
        }
        .background(WindowSizeAdaptor(targetSize: targetWindowSize))
        .overlay(alignment: .center) {
            if store.showsBusyOverlay {
                BusyOverlay(
                    message: store.busyMessage,
                    dismissible: store.busyOverlayDismissible,
                    onClose: {
                        store.dismissBusyOverlay()
                    }
                )
            }
        }
        .overlay(alignment: .center) {
            if let resultCard = store.resultCard {
                ResultOverlay(result: resultCard, store: store)
            }
        }
        .disabled(store.isBusy && store.showsBusyOverlay)
        .alert("操作信息", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("知道了", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !store.isBusy {
                store.refresh()
            }
        }
    }

    private var screenTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity)
    }
}

private struct BusyOverlay: View {
    let message: String
    let dismissible: Bool
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.10)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    Spacer(minLength: 0)

                    if dismissible {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(LauncherPalette.textSecondary)
                                .frame(width: 28, height: 28)
                                .background(LauncherPalette.surfaceSecondary)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                ZStack {
                    Circle()
                        .fill(LauncherPalette.surfacePrimary)
                        .frame(width: 72, height: 72)

                    ProgressView()
                        .controlSize(.regular)
                        .tint(LauncherPalette.accentPrimary)
                }

                VStack(spacing: 8) {
                    Text("正在帮你检查")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(LauncherPalette.textPrimary)

                    Text(message)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(LauncherPalette.textSecondary)
                        .multilineTextAlignment(.center)

                    Text("不用打开命令行，检查完成后会直接告诉你结果。")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(LauncherPalette.textTertiary)
                        .multilineTextAlignment(.center)

                    if dismissible {
                        Text("关闭后检查会继续，完成时仍会告诉你结果。")
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(LauncherPalette.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(width: 360)
            .background(LauncherPalette.surfacePrimary.opacity(0.98))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(LauncherPalette.lineSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 30, y: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .zIndex(20)
        .transition(.opacity)
    }
}

private struct ResultOverlay: View {
    let result: LauncherResultCard
    @ObservedObject var store: LauncherStore

    private var toneColor: Color {
        switch result.tone {
        case .success: return LauncherPalette.success
        case .warning: return LauncherPalette.warning
        case .info: return LauncherPalette.accentPrimary
        }
    }

    private var toneBackground: Color {
        switch result.tone {
        case .success: return LauncherPalette.successSoft
        case .warning: return LauncherPalette.warningSoft
        case .info: return LauncherPalette.surfaceTertiary
        }
    }

    private var symbol: String {
        switch result.tone {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture {
                    store.resultCard = nil
                }

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(toneColor)
                        .frame(width: 44, height: 44)
                        .background(toneBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(result.title)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(LauncherPalette.textPrimary)

                        Text(result.message)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(LauncherPalette.textSecondary)
                            .lineSpacing(3)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 12) {
                    if let primaryTitle = result.primaryActionTitle,
                       let primaryID = result.primaryActionID {
                        Button(primaryTitle) {
                            store.resultCard = nil
                            store.perform(action: primaryID)
                        }
                        .buttonStyle(PrimaryLauncherButtonStyle())
                    }

                    if let secondaryTitle = result.secondaryActionTitle,
                       let secondaryID = result.secondaryActionID {
                        Button(secondaryTitle) {
                            store.resultCard = nil
                            store.perform(action: secondaryID)
                        }
                        .buttonStyle(SecondaryLauncherButtonStyle())
                    }

                    Button("知道了") {
                        store.resultCard = nil
                    }
                    .buttonStyle(SecondaryLauncherButtonStyle())
                }
            }
            .padding(24)
            .frame(width: 460)
            .background(LauncherPalette.surfacePrimary.opacity(0.98))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(LauncherPalette.lineSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 30, y: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .zIndex(21)
        .transition(.opacity)
    }
}

private struct LauncherBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    LauncherPalette.bgApp,
                    LauncherPalette.bgAppSecondary,
                    LauncherPalette.surfaceSecondary
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    LauncherPalette.bgGlow.opacity(0.22),
                    LauncherPalette.bgGlow.opacity(0.0)
                ],
                center: .top,
                startRadius: 18,
                endRadius: 360
            )
            .offset(x: 0, y: -220)
        }
    }
}

private struct GridPattern: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let width = proxy.size.width
                let height = proxy.size.height
                stride(from: 0.0, through: width, by: 48).forEach { x in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))
                }
                stride(from: 0.0, through: height, by: 48).forEach { y in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        }
    }
}

private struct TopBanner: View {
    let snapshot: LauncherSnapshot
    let isSetupFinished: Bool

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LauncherPalette.accentPrimary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(isSetupFinished ? "Hermes 管理中心" : "Hermes 安装助手")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(LauncherPalette.textPrimary)
                    Text(snapshot.version)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LauncherPalette.textTertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(LauncherPalette.surfacePrimary.opacity(0.76))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(LauncherPalette.lineSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
    }
}

private struct SetupHome: View {
    @ObservedObject var store: LauncherStore
    let activeStage: StageCardModel
    let completedCount: Int
    @Binding var showsAdvancedTools: Bool

    var body: some View {
        VStack(spacing: 14) {
            SetupHero(store: store, activeStage: activeStage, completedCount: completedCount)
            ProgressTrackCard(snapshot: store.snapshot, completedCount: completedCount)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SetupHero: View {
    @ObservedObject var store: LauncherStore
    let activeStage: StageCardModel
    let completedCount: Int

    private var helperTitle: String {
        switch activeStage.stage {
        case .install:
            return "现在先安装 Hermes"
        case .model:
            return "接下来连接 AI 服务"
        case .chat:
            return "最后做一次聊天测试"
        }
    }

    private var helperDescription: String {
        switch activeStage.stage {
        case .install:
            return "这一步会把 Hermes 安装到你的电脑上。大多数情况下只需要继续一次，然后等待完成。"
        case .model:
            return "这一步会帮你填好 AI 服务相关设置。完成后，Hermes 才能真正开始工作。"
        case .chat:
            return "这一步会做一次实际对话确认。完成后，这台 Mac 上的 Hermes 就可以直接用了。"
        }
    }

    private var durationText: String {
        switch activeStage.stage {
        case .install: return "预计 2 到 5 分钟"
        case .model: return "预计 1 到 3 分钟"
        case .chat: return "预计不到 1 分钟"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("第 \(completedCount + 1) / 3 步")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.accentPrimary)
                    .tracking(1.1)

                Text(helperTitle)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textPrimary)
                    .tracking(-0.7)
                    .fixedSize(horizontal: false, vertical: true)

                Text(helperDescription)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: 620, alignment: .leading)

                Text("不用打开命令行，也不用记步骤。先把这一项做完，启动器会自动带你到下一步。")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(LauncherPalette.textTertiary)
                    .lineSpacing(2)
                    .frame(maxWidth: 600, alignment: .leading)
            }

            HStack(spacing: 14) {
                Button(store.snapshot.primaryButtonTitle) {
                    store.performPrimaryAction()
                }
                .buttonStyle(PrimaryLauncherButtonStyle())

                Button("刷新状态") {
                    store.refresh()
                }
                .buttonStyle(SecondaryLauncherButtonStyle())
            }

            HStack(spacing: 10) {
                FriendlyPill(symbol: "clock", text: durationText)
                FriendlyPill(symbol: "checkmark.circle", text: "现在只做这一项")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(28)
        .heroPanelBackground()
    }
}

private struct ProgressTrackCard: View {
    let snapshot: LauncherSnapshot
    let completedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("安装进度")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textPrimary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    ForEach(snapshot.stages) { item in
                        CompactProgressStep(item: item)
                    }
                }

                VStack(spacing: 10) {
                    ForEach(snapshot.stages) { item in
                        ProgressStepRow(item: item)
                    }
                }
            }
        }
        .padding(18)
        .background(LauncherPalette.surfacePrimary.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(LauncherPalette.lineSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct CompactProgressStep: View {
    let item: StageCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(item.status == .complete ? LauncherPalette.success : item.status == .active ? LauncherPalette.warning : LauncherPalette.surfaceTertiary)
                        .frame(width: 30, height: 30)

                    Image(systemName: item.status == .complete ? "checkmark" : item.symbolName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }

                Spacer(minLength: 0)
            }

            Text(item.shortTitle)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(LauncherPalette.textPrimary)

            Text(item.status.label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(item.accentColor)

            Text(item.stage.detail)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(LauncherPalette.textSecondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(14)
        .background(item.status == .complete ? LauncherPalette.successSoft : item.status == .active ? LauncherPalette.warningSoft : LauncherPalette.surfacePrimary)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(item.status == .complete ? LauncherPalette.success.opacity(0.35) : item.status == .active ? LauncherPalette.warning.opacity(0.35) : LauncherPalette.lineSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ProgressStepRow: View {
    let item: StageCardModel

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(item.status == .complete ? LauncherPalette.success : item.status == .active ? LauncherPalette.warning : LauncherPalette.surfaceTertiary)
                    .frame(width: 36, height: 36)

                Image(systemName: item.status == .complete ? "checkmark" : item.symbolName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.stage.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(LauncherPalette.textPrimary)

                    Text(item.status.label)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(item.accentColor)
                }

                Text(item.stage.detail)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .lineSpacing(2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(item.status == .complete ? LauncherPalette.successSoft : item.status == .active ? LauncherPalette.warningSoft : LauncherPalette.surfacePrimary)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(item.status == .complete ? LauncherPalette.success.opacity(0.35) : item.status == .active ? LauncherPalette.warning.opacity(0.35) : LauncherPalette.lineSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ManagementHome: View {
    @ObservedObject var store: LauncherStore
    @State private var showsAdvancedTools = false

    var body: some View {
        VStack(spacing: 18) {
            ManagementHero(store: store)
            ManagementSimpleActionsSection(store: store, showsAdvancedTools: $showsAdvancedTools)
            ManagementMaintenanceSection(store: store, showsAdvancedTools: $showsAdvancedTools)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ManagementHero: View {
    @ObservedObject var store: LauncherStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Hermes 已经可以用了")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(LauncherPalette.textPrimary)
                .tracking(-0.8)

            Text("它已经安装好，也已经连上 AI。你现在最需要做的，通常就是直接开始和它说话。")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(LauncherPalette.textSecondary)
                .lineSpacing(4)
                .frame(maxWidth: 640, alignment: .leading)

            HStack(spacing: 12) {
                Button("开始和 Hermes 对话") {
                    store.perform(action: "chat")
                }
                .buttonStyle(PrimaryLauncherButtonStyle())

                if store.snapshot.aiModel != "未配置" {
                    FriendlyPill(symbol: "cpu", text: "当前模型：\(store.snapshot.aiModel)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(26)
        .managementHeroBackground()
    }
}

private struct ManagementSimpleActionsSection: View {
    @ObservedObject var store: LauncherStore
    @Binding var showsAdvancedTools: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("接下来你可能会做的事")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textPrimary)

                Text("只保留最常用的几个入口，其余放到下面。")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(LauncherPalette.textSecondary)
            }

            VStack(spacing: 10) {
                SimpleActionRow(
                    title: "换一个 AI 模型",
                    subtitle: "如果你想切换到别的模型，从这里改就可以。",
                    symbol: "slider.horizontal.3"
                ) {
                    store.perform(action: "model")
                }

                SimpleActionRow(
                    title: "检查现在能不能正常用",
                    subtitle: "如果你担心没有配好，可以先做一次自动检查。",
                    symbol: "stethoscope"
                ) {
                    store.perform(action: "doctor")
                }

                if store.snapshot.gatewayStatus == "未配置" {
                    SimpleActionRow(
                        title: "接收微信、飞书、QQ等消息通知",
                        subtitle: "需要时再接入。不设置也不影响平时直接使用。",
                        symbol: "message.badge.waveform"
                    ) {
                        store.perform(action: "gateway_setup")
                    }
                }

                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        showsAdvancedTools = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(LauncherPalette.textTertiary)
                            .frame(width: 36, height: 36)
                            .background(LauncherPalette.surfaceTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 5) {
                            Text("更多设置和维护")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(LauncherPalette.textPrimary)

                            Text("更新、查看记录、打开文件夹或卸载，都在这里。")
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                                .foregroundStyle(LauncherPalette.textSecondary)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(LauncherPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(LauncherPalette.surfaceTertiary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(LauncherPalette.lineSoft, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(CardPressButtonStyle(scale: 0.992))
            }
        }
        .padding(22)
        .darkPanelBackground(radius: 26)
    }
}

private struct SimpleActionRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let trigger: () -> Void

    var body: some View {
        Button(action: trigger) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LauncherPalette.accentPrimary)
                    .frame(width: 36, height: 36)
                    .background(LauncherPalette.surfaceTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(LauncherPalette.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(LauncherPalette.textSecondary)
                        .lineSpacing(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LauncherPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(LauncherPalette.surfacePrimary)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(LauncherPalette.lineSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(CardPressButtonStyle(scale: 0.992))
    }
}

private struct ManagementMaintenanceSection: View {
    @ObservedObject var store: LauncherStore
    @Binding var showsAdvancedTools: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("更多设置和维护")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(LauncherPalette.textPrimary)

                    Text("平时可以先不用看，遇到问题或想调整时再展开。")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(LauncherPalette.textSecondary)
                }

                Spacer(minLength: 0)
            }

            DisclosureGroup(isExpanded: $showsAdvancedTools) {
                VStack(alignment: .leading, spacing: 16) {
                    ManagementSettingsGroup(title: "维护相关", actions: managementMaintenanceActions, store: store)
                }
                .padding(.top, 14)
            } label: {
                HStack {
                    Text(showsAdvancedTools ? "收起这些内容" : "展开这些内容")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(LauncherPalette.textPrimary)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding(22)
        .darkPanelBackground(radius: 26)
        .onReceive(NotificationCenter.default.publisher(for: .toggleManagementSettings)) { _ in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                showsAdvancedTools.toggle()
            }
        }
    }
}

private struct ManagementSettingsGroup: View {
    let title: String
    let actions: [ManagementAction]
    @ObservedObject var store: LauncherStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(LauncherPalette.textTertiary)
                .tracking(0.6)

            VStack(spacing: 8) {
                ForEach(actions) { action in
                    ManagementListActionButton(action: action) {
                        store.perform(action: action.id)
                    }
                }
            }
        }
    }
}

private struct ManagementListActionButton: View {
    let action: ManagementAction
    let trigger: () -> Void

    var body: some View {
        Button(action: trigger) {
            HStack(spacing: 12) {
                Image(systemName: action.symbolName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(action.id == "uninstall" ? LauncherPalette.danger : LauncherPalette.accentPrimary)
                    .frame(width: 28, height: 28)
                    .background(action.id == "uninstall" ? LauncherPalette.dangerSoft : LauncherPalette.surfaceTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(action.title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(LauncherPalette.textPrimary)

                    Text(action.subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(LauncherPalette.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(LauncherPalette.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(LauncherPalette.surfacePrimary)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LauncherPalette.lineSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(CardPressButtonStyle(scale: 0.992))
    }
}

private struct PrimaryLauncherButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(LauncherPalette.textOnAccent)
            .padding(.horizontal, 22)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        configuration.isPressed
                        ? LauncherPalette.accentDeep
                        : LauncherPalette.accentPrimary
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: LauncherPalette.accentPrimary.opacity(configuration.isPressed ? 0.18 : 0.28), radius: configuration.isPressed ? 10 : 16, y: configuration.isPressed ? 4 : 8)
            .scaleEffect(configuration.isPressed ? 0.988 : 1)
    }
}

private struct SecondaryLauncherButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(LauncherPalette.textPrimary)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(configuration.isPressed ? LauncherPalette.surfaceHover : LauncherPalette.surfaceTertiary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(LauncherPalette.lineSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.black.opacity(0.06), radius: configuration.isPressed ? 6 : 10, y: configuration.isPressed ? 3 : 5)
            .scaleEffect(configuration.isPressed ? 0.992 : 1)
    }
}

private struct CardPressButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.986

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.96 : 1)
    }
}

private struct FriendlyPill: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(LauncherPalette.accentPrimary)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LauncherPalette.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(LauncherPalette.surfaceTertiary)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LauncherPalette.lineSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct WindowSizeAdaptor: NSViewRepresentable {
    let targetSize: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            applySizeIfNeeded(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            applySizeIfNeeded(for: nsView)
        }
    }

    private func applySizeIfNeeded(for view: NSView) {
        guard let window = view.window else { return }
        let size = NSSize(width: targetSize.width, height: targetSize.height)
        let current = window.frame.size

        guard abs(current.width - size.width) > 1 || abs(current.height - size.height) > 1 else {
            return
        }

        window.minSize = NSSize(width: 760, height: 620)
        window.setContentSize(size)
    }
}

private struct ManagementAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
}

private extension Notification.Name {
    static let toggleManagementSettings = Notification.Name("toggleManagementSettings")
}

private let managementUsageActions: [ManagementAction] = [
    ManagementAction(id: "doctor", title: "检查现在能不能正常用", subtitle: "自动检查 Hermes 当前是不是已经能正常工作", symbolName: "stethoscope"),
    ManagementAction(id: "model", title: "更换 AI 模型", subtitle: "重新选择你想使用的 AI 服务和默认模型", symbolName: "slider.horizontal.3"),
    ManagementAction(id: "gateway_setup", title: "连接消息通知", subtitle: "把 Hermes 接到微信、飞书、QQ等消息入口", symbolName: "message.badge.waveform"),
    ManagementAction(id: "setup", title: "重新走一遍设置", subtitle: "从头再做一遍常用设置，适合换账号或重配环境", symbolName: "wand.and.stars")
]

private let managementMaintenanceActions: [ManagementAction] = [
    ManagementAction(id: "update", title: "检查更新", subtitle: "安装最新 Hermes 版本", symbolName: "arrow.triangle.2.circlepath"),
    ManagementAction(id: "open_config", title: "打开主设置", subtitle: "查看 Hermes 的主要设置", symbolName: "doc.text"),
    ManagementAction(id: "open_env", title: "查看密钥设置", subtitle: "检查 API Key 和环境变量", symbolName: "key"),
    ManagementAction(id: "open_logs", title: "打开问题记录", subtitle: "查看最近运行时留下的记录", symbolName: "doc.text.magnifyingglass"),
    ManagementAction(id: "open_home", title: "打开数据文件夹", subtitle: "查看 Hermes 保存的数据", symbolName: "house"),
    ManagementAction(id: "open_install", title: "打开安装位置", subtitle: "查看 Hermes 的程序文件", symbolName: "folder"),
    ManagementAction(id: "tools", title: "调整工具权限", subtitle: "处理工具权限或可用范围", symbolName: "shippingbox.and.arrow.backward"),
    ManagementAction(id: "docs", title: "查看帮助文档", subtitle: "打开官方说明", symbolName: "book.closed"),
    ManagementAction(id: "repo", title: "打开项目主页", subtitle: "查看 Hermes 项目页面", symbolName: "link"),
    ManagementAction(id: "uninstall", title: "卸载 Hermes", subtitle: "从这台 Mac 移除 Hermes", symbolName: "trash")
]

private struct RecoveryActionButton: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(LauncherPalette.accentPrimary)
                    .frame(width: 34, height: 34)
                    .background(LauncherPalette.surfaceTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(LauncherPalette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(LauncherPalette.textSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(LauncherPalette.surfacePrimary)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(LauncherPalette.lineSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(CardPressButtonStyle(scale: 0.992))
    }
}

private struct StatusChip: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LauncherPalette.textTertiary)
                .tracking(1.1)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LauncherPalette.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(LauncherPalette.surfaceTertiary)
        .overlay(
            Capsule()
                .stroke(LauncherPalette.lineSoft, lineWidth: 1)
        )
        .clipShape(Capsule())
    }
}

private extension View {
    func heroPanelBackground(radius: CGFloat = 34) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                LauncherPalette.surfacePrimary,
                                LauncherPalette.surfaceSecondary
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        LauncherPalette.bgGlow.opacity(0.16),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(LauncherPalette.lineSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }

    func managementHeroBackground() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                LauncherPalette.surfacePrimary,
                                LauncherPalette.surfaceSecondary
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        LauncherPalette.bgGlow.opacity(0.20),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(LauncherPalette.lineSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 7)
    }

    func darkPanelBackground(radius: CGFloat = 30) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LauncherPalette.surfaceSecondary.opacity(0.88))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Color.white.opacity(0.22))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(LauncherPalette.lineSofter, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
    }
}
