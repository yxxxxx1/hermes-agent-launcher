import SwiftUI
import AppKit

// MARK: - Visual tokens (v2 design)

enum LauncherPalette {
    static let bgApp = Color(red: 0.949, green: 0.941, blue: 0.910)            // #f2f0e8
    static let surfacePrimary = Color(red: 0.976, green: 0.965, blue: 0.937)   // window panel
    static let surfaceSecondary = Color(red: 0.949, green: 0.929, blue: 0.886) // chip / pill
    static let surfaceTertiary = Color(red: 0.929, green: 0.910, blue: 0.875)  // hover

    static let textPrimary = Color(red: 0.118, green: 0.106, blue: 0.090)      // ink
    static let textSecondary = Color(red: 0.376, green: 0.349, blue: 0.314)
    static let textTertiary = Color(red: 0.580, green: 0.541, blue: 0.490)
    static let textOnAccent = Color(red: 0.996, green: 0.984, blue: 0.965)

    static let accentPrimary = Color(red: 0.851, green: 0.471, blue: 0.169)    // #d9782b
    static let accentDeep = Color(red: 0.659, green: 0.329, blue: 0.122)       // #a8541f
    static let accentSoft = Color(red: 0.953, green: 0.788, blue: 0.553)

    static let success = Color(red: 0.310, green: 0.561, blue: 0.478)          // #4f8f7a
    static let successSoft = Color(red: 0.847, green: 0.918, blue: 0.882)
    static let warning = Color(red: 0.780, green: 0.541, blue: 0.227)          // #c78a3a
    static let warningSoft = Color(red: 0.961, green: 0.910, blue: 0.820)
    static let danger = Color(red: 0.761, green: 0.369, blue: 0.322)           // #c25e52
    static let dangerSoft = Color(red: 0.965, green: 0.882, blue: 0.851)

    static let lineSoft = Color.black.opacity(0.06)
    static let lineSofter = Color.black.opacity(0.04)
}

// MARK: - Root

struct LauncherRootView: View {
    @ObservedObject var store: LauncherStore
    @State private var showsAbout = false

    var body: some View {
        ZStack {
            LauncherPalette.bgApp
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TitleBarView()
                HeroContainer(store: store, showsAbout: $showsAbout)
                FooterView(store: store, showsAbout: $showsAbout)
            }
        }
        .frame(width: 720, height: 560)
        .sheet(isPresented: $showsAbout) {
            AboutSheet(store: store, isPresented: $showsAbout)
        }
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
}

// MARK: - Title bar

private struct TitleBarView: View {
    var body: some View {
        ZStack {
            Text("Hermes Launcher")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(LauncherPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LauncherPalette.lineSofter)
                .frame(height: 1)
        }
    }
}

// MARK: - Hero container

private struct HeroContainer: View {
    @ObservedObject var store: LauncherStore
    @Binding var showsAbout: Bool

    var body: some View {
        Group {
            switch store.snapshot.heroState {
            case .notInstalled:
                HeroNotInstalled(store: store)
            case .readyToLaunch:
                HeroReadyToLaunch(store: store)
            case .inProgress:
                HeroInProgress(store: store)
            case .running:
                HeroRunning(store: store)
            case .error(let reason, let message):
                HeroError(store: store, reason: reason, message: message)
            case .networkBlocked:
                HeroNetworkBlocked(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Hero state 1: not installed

private struct HeroNotInstalled: View {
    @ObservedObject var store: LauncherStore

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            ZStack {
                Circle()
                    .fill(LauncherPalette.accentPrimary.opacity(0.16))
                    .frame(width: 68, height: 68)
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(LauncherPalette.accentPrimary)
            }

            VStack(spacing: 10) {
                Text("欢迎使用 Hermes Launcher")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textPrimary)
                Text("点开始安装，启动器会自动准备好运行环境，并在浏览器中打开 Hermes 对话界面。")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .lineSpacing(2)
            }
            .padding(.top, 18)

            PrimaryCTA(title: "开始安装") {
                store.performPrimaryAction()
            }
            .padding(.top, 22)

            HStack(spacing: 6) {
                Text("安装位置：")
                    .foregroundStyle(LauncherPalette.textTertiary)
                Text("~/.hermes")
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .fontWeight(.medium)
                Button("更换位置") {
                    // TODO(macos-webui-migration UI follow-up): expose install-dir picker.
                }
                .buttonStyle(.plain)
                .foregroundStyle(LauncherPalette.accentDeep)
                .underline()
            }
            .font(.system(size: 12, design: .rounded))
            .padding(.top, 12)

            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Hero "ready to launch" (installed, but WebUI not running)

private struct HeroReadyToLaunch: View {
    @ObservedObject var store: LauncherStore

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            ZStack {
                Circle()
                    .fill(LauncherPalette.successSoft)
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.success)
            }

            VStack(spacing: 10) {
                Text("Hermes 已安装，等待启动")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textPrimary)
                Text("启动后会在浏览器中打开对话界面。")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .lineSpacing(2)
            }
            .padding(.top, 18)

            PrimaryCTA(title: "启动浏览器对话", width: 220) {
                store.performPrimaryAction()
            }
            .padding(.top, 22)

            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Hero state 2: in progress (7-row checklist)

private struct HeroInProgress: View {
    @ObservedObject var store: LauncherStore

    private var progress: LaunchProgress {
        store.snapshot.launchProgress ?? .initial()
    }

    private var headline: String {
        progress.headlineFromSimplified
    }

    /// "第 N 步" — index of the currently-active simplified row, or fall back to the most recent.
    private var stepLabel: String {
        if let idx = progress.simplifiedStepIndex {
            return "第 \(idx) 步"
        }
        // No row is currently running — count completed/skipped rows.
        let done = progress.simplifiedRows.filter {
            if case .done = $0.status { return true }
            if case .skipped = $0.status { return true }
            return false
        }.count
        if done >= 3 { return "完成" }
        return "第 \(max(1, done + 1)) 步"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 14)

            VStack(spacing: 4) {
                Text(stepLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(LauncherPalette.textTertiary)
                Text(headline)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textPrimary)
                    .multilineTextAlignment(.center)
            }

            SimplifiedChecklist(rows: progress.simplifiedRows)
                .padding(.top, 18)
                .padding(.horizontal, 24)

            Text("已用时 \(formatElapsed(store.elapsedSeconds))")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(LauncherPalette.textTertiary)
                .padding(.top, 14)

            HStack(spacing: 12) {
                PrimaryCTA(title: "启动浏览器对话", isDisabled: true) {}
                Button("取消") {
                    store.cancelLaunch()
                }
                .buttonStyle(.plain)
                .foregroundStyle(LauncherPalette.textSecondary)
            }
            .padding(.top, 14)

            Spacer(minLength: 8)

            Button {
                store.openLog(path: NSHomeDirectory() + "/.hermes/launcher-runtime/install.log")
            } label: {
                Text("▸ 查看技术日志")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(LauncherPalette.textTertiary)
                    .underline(true, pattern: .dash)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
    }

    private func formatElapsed(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct SimplifiedChecklist: View {
    let rows: [LaunchProgress.SimplifiedRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                rowView(row)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: LaunchProgress.SimplifiedRow) -> some View {
        let isRunning: Bool = { if case .running = row.status { return true } else { return false } }()
        HStack(spacing: 10) {
            statusIcon(row.status)
                .frame(width: 18, height: 18)
            Text(row.title)
                .font(.system(size: 13, weight: isRunning ? .semibold : .regular, design: .rounded))
                .foregroundStyle(textColor(for: row.status))
            Spacer(minLength: 8)
            if !row.detail.isEmpty {
                Text(row.detail)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(LauncherPalette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isRunning ? LauncherPalette.accentPrimary.opacity(0.08) : Color.clear)
        )
    }

    @ViewBuilder
    private func statusIcon(_ status: LaunchProgress.AggregateStatus) -> some View {
        switch status {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(LauncherPalette.success)
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(LauncherPalette.accentPrimary)
        case .pending:
            Circle()
                .stroke(LauncherPalette.lineSoft, lineWidth: 1.2)
                .frame(width: 12, height: 12)
        case .skipped:
            Rectangle()
                .fill(LauncherPalette.textTertiary)
                .frame(width: 10, height: 1.4)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(LauncherPalette.danger)
        }
    }

    private func textColor(for status: LaunchProgress.AggregateStatus) -> Color {
        switch status {
        case .done, .running: return LauncherPalette.textPrimary
        case .pending, .skipped: return LauncherPalette.textTertiary
        case .failed: return LauncherPalette.danger
        }
    }
}

// MARK: - Hero state 3: running

private struct HeroRunning: View {
    @ObservedObject var store: LauncherStore

    var body: some View {
        VStack(spacing: 0) {
            // Mismatch warning banner — only when verify_platforms emitted mismatch_persistent.
            if let mm = store.snapshot.platformMismatch {
                MismatchBanner(mismatch: mm) {
                    store.perform(action: "open-install-log")
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }

            Spacer(minLength: 24)

            ZStack {
                Circle()
                    .fill(LauncherPalette.successSoft)
                    .frame(width: 68, height: 68)
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.success)
            }

            VStack(spacing: 10) {
                Text("Hermes 已就绪")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textPrimary)
                Text("浏览器对话已经准备好了，点下面打开。")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(.top, 18)

            PrimaryCTA(title: "在浏览器中打开") {
                store.openWebUIBrowser()
            }
            .padding(.top, 22)

            HStack(spacing: 6) {
                Circle()
                    .fill(LauncherPalette.success)
                    .frame(width: 6, height: 6)
                Text("运行中")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(LauncherPalette.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(LauncherPalette.successSoft)
            )
            .padding(.top, 14)

            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

private struct MismatchBanner: View {
    let mismatch: PlatformMismatch
    let onOpenLog: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LauncherPalette.warning)
                    .frame(width: 22, height: 22)
                Text("!")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textOnAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Hermes 网关只连接了 \(mismatch.connected) / \(mismatch.configured) 个已配置平台")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.29, blue: 0.09))
                Text("可能某个聊天工具配置失败")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color(red: 0.42, green: 0.29, blue: 0.09).opacity(0.78))
            }
            Spacer(minLength: 8)
            Button("查看安装日志") {
                onOpenLog()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(LauncherPalette.accentDeep)
            .underline()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LauncherPalette.warningSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color(red: 0.85, green: 0.69, blue: 0.42), lineWidth: 1)
                )
        )
    }
}

// MARK: - Hero state 4: error

private struct HeroError: View {
    @ObservedObject var store: LauncherStore
    let reason: String
    let message: String

    private var title: String {
        if reason.hasPrefix("install_platform_dep_failed:") {
            let label = reason.dropFirst("install_platform_dep_failed:".count)
            return "\(label) 配置失败"
        }
        if reason == "install_platform_dep_failed" { return "聊天工具配置失败" }
        if reason.hasPrefix("npm_install_failed") { return "安装失败" }
        if reason.hasPrefix("curl_") || reason == "node_download_failed" { return "运行环境下载失败" }
        if reason.hasPrefix("tar_") || reason == "node_extract_failed" { return "运行环境解压失败" }
        if reason == "health_timeout" { return "启动超时" }
        if reason == "webui_failed" { return "无法启动浏览器对话" }
        return "无法启动浏览器对话"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            ZStack {
                Circle()
                    .fill(LauncherPalette.dangerSoft)
                    .frame(width: 68, height: 68)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.danger)
            }

            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textPrimary)
                Text(message)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .lineSpacing(2)
            }
            .padding(.top, 18)

            PrimaryCTA(title: "重试") {
                store.snapshot.launchProgress = nil
                store.launch()
            }
            .padding(.top, 22)

            HStack(spacing: 16) {
                Button("查看 Hermes 日志") {
                    store.perform(action: "open-webui-log")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LauncherPalette.accentDeep)
                .underline()

                Button("查看安装日志") {
                    store.perform(action: "open-install-log")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LauncherPalette.accentDeep)
                .underline()
            }
            .font(.system(size: 12, design: .rounded))
            .padding(.top, 14)

            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Hero state 5: network blocked

private struct HeroNetworkBlocked: View {
    @ObservedObject var store: LauncherStore

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            ZStack {
                Circle()
                    .fill(LauncherPalette.dangerSoft)
                    .frame(width: 80, height: 80)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.danger)
            }

            VStack(spacing: 10) {
                Text("网络似乎不通")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textPrimary)
                Text("下载组件需要联网，请检查网络后重试。")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(.top, 18)

            PrimaryCTA(title: "重新检测") {
                store.refresh()
            }
            .padding(.top, 22)

            HStack(spacing: 18) {
                Button("使用国内镜像") {
                    // TODO: wire mirror toggle to launcher script when registry-pin UI lands.
                }
                .buttonStyle(.plain)
                .foregroundStyle(LauncherPalette.accentDeep)
                .underline()

                Button("打开诊断帮助") {
                    NSWorkspace.shared.open(URL(string: "https://hermes-agent.nousresearch.com/docs/getting-started/installation/")!)
                }
                .buttonStyle(.plain)
                .foregroundStyle(LauncherPalette.accentDeep)
                .underline()
            }
            .font(.system(size: 12, design: .rounded))
            .padding(.top, 14)

            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Footer

private struct FooterView: View {
    @ObservedObject var store: LauncherStore
    @Binding var showsAbout: Bool
    @State private var showsMenu = false

    private var footerText: String {
        // Mismatch overrides everything else with an orange-counted summary.
        if let mm = store.snapshot.platformMismatch {
            return "\(mm.connected)/\(mm.configured) 个聊天工具在线"
        }
        switch store.snapshot.heroState {
        case .notInstalled:
            return store.snapshot.primaryAction == "launch" ? "已安装，等待启动" : "未安装"
        case .readyToLaunch: return "已安装，等待启动"
        case .inProgress: return "准备中…"
        case .running: return "运行中"
        case .error: return "运行环境出错"
        case .networkBlocked: return "网络检查未通过"
        }
    }

    private var footerColor: Color {
        if store.snapshot.platformMismatch != nil { return LauncherPalette.warning }
        switch store.snapshot.heroState {
        case .networkBlocked: return LauncherPalette.warning
        case .error: return LauncherPalette.textSecondary
        default: return LauncherPalette.textTertiary
        }
    }

    var body: some View {
        HStack {
            Text(footerText)
                .font(.system(size: 11, weight: footerColor == LauncherPalette.warning ? .semibold : .regular, design: .rounded))
                .foregroundStyle(footerColor)
            Spacer()
            Button {
                showsMenu.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(LauncherPalette.surfaceSecondary)
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsMenu, arrowEdge: .top) {
                FooterMenu(store: store, showsAbout: $showsAbout, isPresented: $showsMenu)
                    .frame(width: 220)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LauncherPalette.lineSofter)
                .frame(height: 1)
        }
    }
}

private struct FooterMenu: View {
    @ObservedObject var store: LauncherStore
    @Binding var showsAbout: Bool
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow(icon: "arrow.clockwise", label: "重启 Hermes") {
                store.perform(action: "restart-webui")
            }
            menuRow(icon: "stop.circle", label: "停止 Hermes") {
                store.perform(action: "stop-webui")
            }
            divider
            menuRow(icon: "doc.text", label: "查看 Hermes 日志") {
                store.perform(action: "open-webui-log")
            }
            menuRow(icon: "doc.text.below.ecg", label: "查看安装日志") {
                store.perform(action: "open-install-log")
            }
            menuRow(icon: "folder", label: "打开 ~/.hermes") {
                store.perform(action: "open-home")
            }
            divider
            menuRow(icon: "stethoscope", label: "诊断（doctor）") {
                store.perform(action: "doctor")
            }
            menuRow(icon: "gearshape.2", label: "高级…") {
                store.perform(action: "setup")
            }
            divider
            menuRow(icon: "info.circle", label: "关于 Hermes Launcher") {
                showsAbout = true
            }
            menuRow(icon: "trash", label: "卸载", role: .destructive) {
                store.perform(action: "uninstall")
            }
        }
        .padding(.vertical, 6)
    }

    private var divider: some View {
        Rectangle()
            .fill(LauncherPalette.lineSofter)
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func menuRow(icon: String, label: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button {
            isPresented = false
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(role == .destructive ? LauncherPalette.danger : LauncherPalette.textSecondary)
                Text(label)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(role == .destructive ? LauncherPalette.danger : LauncherPalette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - About sheet

private struct AboutSheet: View {
    @ObservedObject var store: LauncherStore
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("关于 Hermes Launcher")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(LauncherPalette.textSecondary)
                .padding(.top, 16)
                .padding(.horizontal, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Text("OPEN SOURCE")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(LauncherPalette.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(LinearGradient(colors: [LauncherPalette.accentPrimary, LauncherPalette.accentDeep], startPoint: .leading, endPoint: .trailing))
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本启动器代码已开源")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(LauncherPalette.textPrimary)
                            Text("欢迎在 GitHub 上查看源代码、提 issue、参与共建")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(LauncherPalette.textSecondary)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LauncherPalette.surfaceSecondary)
                    )

                    Text(store.snapshot.version)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(LauncherPalette.textPrimary)

                    VStack(alignment: .leading, spacing: 6) {
                        aboutRow(label: "运行环境:", value: runtimeStack)
                        aboutRow(label: "数据目录:", value: "~/.hermes  ·  WebUI 状态：~/.hermes-web-ui")
                        aboutRow(label: "©", value: "2026 · MIT License")
                    }

                    PrivacySection()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }

            HStack {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/yxxxxx1/hermes-agent-launcher")!)
                } label: {
                    HStack(spacing: 4) {
                        Text("github.com/yxxxxx1/hermes-agent-launcher")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(LauncherPalette.accentDeep)
                .underline()

                Spacer()

                Button("关闭") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(LauncherPalette.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LauncherPalette.surfaceSecondary)
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .overlay(alignment: .top) {
                Rectangle().fill(LauncherPalette.lineSofter).frame(height: 1)
            }
        }
        .frame(width: 540, height: 620)
        .background(LauncherPalette.surfacePrimary)
    }

    private var runtimeStack: String {
        let webui = store.snapshot.webuiVersion.isEmpty ? "未安装" : store.snapshot.webuiVersion
        let node = store.snapshot.nodeRuntimeVersion.isEmpty
            ? "未检测"
            : "\(store.snapshot.nodeRuntimeVersion) (\(store.snapshot.nodeRuntimeKind))"
        return "WebUI \(webui)  ·  Node \(node)"
    }

    private func aboutRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(LauncherPalette.textTertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(LauncherPalette.textSecondary)
        }
    }
}

// MARK: - About: privacy & telemetry section

private struct PrivacySection: View {
    @State private var telemetryEnabled: Bool = TelemetryClient.shared.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("匿名使用数据上报")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(LauncherPalette.textPrimary)
                    Text(telemetryEnabled ? "已开启 — 帮助改进产品" : "已关闭 — 不上报任何数据")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(telemetryEnabled ? LauncherPalette.success : LauncherPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $telemetryEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: telemetryEnabled) { newValue in
                        TelemetryClient.shared.isEnabled = newValue
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("我们收集")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textSecondary)
                Text("匿名 ID（一台机一组随机字符）· 程序事件名（如 webui_started）· 错误原因（已脱敏：移除 sk-/Bearer/api_key/token/password、用户名、邮箱、IP、文件路径里的真实用户名）· 启动器版本 · macOS 大版本 · 内存档位")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(LauncherPalette.textTertiary)
                    .lineSpacing(2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("我们不收集")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(LauncherPalette.textSecondary)
                Text("对话内容 · 模型 API key · token / password / secret · 文件路径里的用户名 · 邮箱 · 原始 IP（边缘加盐 SHA256 截断后只存 ip_hash 用于按机去重，原始 IP 不入库）")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(LauncherPalette.textTertiary)
                    .lineSpacing(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LauncherPalette.surfaceSecondary.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LauncherPalette.lineSoft, lineWidth: 1)
        )
    }
}

// MARK: - Primary CTA button

private struct PrimaryCTA: View {
    let title: String
    var isDisabled: Bool = false
    var width: CGFloat = 300
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(LauncherPalette.textOnAccent)
                .frame(width: width, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isDisabled
                              ? AnyShapeStyle(LauncherPalette.accentPrimary.opacity(0.55))
                              : AnyShapeStyle(LinearGradient(
                                    colors: [LauncherPalette.accentPrimary, LauncherPalette.accentDeep],
                                    startPoint: .top,
                                    endPoint: .bottom)))
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}
