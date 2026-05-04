# TC-005: launcher 关闭再开 ≠ 重新装

**优先级**:P0
**关联陷阱**:CLAUDE.md #10(找得到≠信息存在)、#27(快速路径)、Bug B(Task 014 修复中)
**适用版本**:v2026.05.02.2 及以上(Bug B 修复后才能稳定通过)

## 前置条件
- 操作系统:Win10 / Win11 任意版本
- hermes 状态:**已装且第一次运行成功过**(用户已经至少打开过一次 webui,渠道配置可能为空也可能已配置)
- .env 内容:任意(包括空白 / 已配 Telegram / 已配微信等)
- 网络环境:任意
- 其他:启动器**第一次会话已正常关闭**(点关闭按钮或任务栏关闭,不是任务管理器强杀)

## 测试步骤
1. 确认启动器和 webui 都已关闭(任务管理器查 `pwsh.exe` / `powershell.exe` / `node.exe` / `hermes.exe` 含相关命令行的进程,均不存在或已退出)
2. 等待 5 秒,确保所有后台进程清理完成
3. 双击 `Start-HermesGuiLauncher.cmd` 重新启动启动器
4. 主面板加载完成
5. 观察主按钮文案 + 主面板状态
6. 点主按钮"开始使用",观察是否需要重新装东西

## 预期结果
- 步骤 4 后:**直接进入 Home Mode**,主按钮"开始使用"
- 步骤 4 后:**不出现**任何"安装/更新" / "正在检测环境" / "Install Mode" 元素
- 步骤 6 后:**直接打开 webui**(不需要等 30+ 秒,不需要装 Node.js,不需要装 web-ui)
- 第二次开启的体验**与第一次开启完全一致**(除了首次的 EULA 确认 / 安装位置确认)

## 执行证据(发版前由 agent / PM 填)
- [ ] 步骤 4 截图(Home Mode):`testcases/core-paths/_evidence/TC-005-step4.png`(待 PM 真机验收时填)
- [ ] 步骤 6 启动到 webui 打开的耗时:______ 秒(预期 < 30 秒,待 PM 真机验收时填)
- [ ] 启动器日志(确认无 install 路径调用):`testcases/core-paths/_evidence/TC-005-launcher.log`(待 PM 真机验收时填)
- [x] Bug B 修复点同 TC-002:`Refresh-Status` 条件已解耦 `pendingOpenClaw`,无残留情况下直接 Home Mode
- [x] Fast path 代码 review:`Start-LaunchAsync` L3917 起的 `if ($health.Healthy)` 块仍走 fast path,**没**重新装 Node.js / web-ui
- **状态**:**通过(代码 review)/ 真机视觉行为无法本地验证**
- 备注:任务 014 的修改不触及 fast path 主逻辑;只在 fast path 内增加了 `$script:LastDepInstallFailure` 检查与 banner 显示。需 PM 真机抽查。

## 失败处理
- 出现 Install Mode → Bug B 复发,直接关联 `regression/B-installed-machine-home-mode.md`
- 启动到 webui > 60 秒 → 检查 fast path 是否生效,陷阱 #27 复发
- 重新装了 Node.js / web-ui → InstallDir 检测失败,陷阱 #16 残留目录或 settings.json 丢失
- 是否需要新建陷阱条目:**是**(如果是新场景)
