# TC-002: 已装机器再次开启动器(应直接 Home Mode)

**优先级**:P0
**关联陷阱**:CLAUDE.md #10(找得到≠信息存在)、#27(快速路径)、Bug B(Task 014 修复中)
**适用版本**:v2026.05.02.2 及以上(Bug B 修复后才能稳定通过)

## 前置条件
- 操作系统:Win10 / Win11 任意版本
- hermes 状态:**已装**(`%LOCALAPPDATA%\hermes\hermes-agent\Scripts\hermes.exe` 存在)
- .env 内容:存在(任意有效配置或空白文件均可)
- 网络环境:任意(本用例不依赖网络)
- 其他:启动器**之前已成功运行过至少一次**(产生过 settings.json / 缓存等)

## 测试步骤
1. 确认 `%LOCALAPPDATA%\hermes\hermes-agent\Scripts\hermes.exe` 存在
2. 确认启动器**当前没在运行**(任务管理器查 `pwsh.exe` / `powershell.exe` 含 `HermesGuiLauncher.ps1` 命令行的进程)
3. 双击 `Start-HermesGuiLauncher.cmd` 启动启动器
4. 等启动器主窗口完全渲染(< 5 秒)
5. 观察主面板状态

## 预期结果
- 步骤 4 后:主面板**直接显示 Home Mode**
- 主按钮文案是 **"开始使用"**(不是"安装/更新 Hermes")
- 主面板**不出现**任何 Install Mode 元素:无"安装/更新"按钮、无 4 阶段步骤指示器、无 install 进度卡、无 LogSectionBorder
- 主面板**不出现**"正在检测环境..."的等待文案(超过 2 秒)
- 主按钮可点击(非 disabled 状态)

## 执行证据(发版前由 agent / PM 填)
- [ ] 步骤 5 截图(Home Mode 全图):`testcases/core-paths/_evidence/TC-002-home.png`(待 PM 真机验收时填)
- [ ] 启动后 5 秒内的 launcher 日志:`testcases/core-paths/_evidence/TC-002-launcher.log`(待 PM 真机验收时填)
- [x] `Test-HermesInstalled` 返回值(SelfTest JSON 字段):**`Status.Installed=true`、`Status.HermesExe=...\venv\Scripts\hermes.exe`**(运行 `HermesGuiLauncher.ps1 -SelfTest` 验证)
- [x] Bug B 修复点代码 review 通过:**`Refresh-Status` L6195 条件已从 `((-not $isInstalled) -or $pendingOpenClaw)` 改为 `(-not $isInstalled)`**(grep 验证只剩此一处条件)
- [x] XAML 加载验证:**`HomeModePanel`、`HomeReadyContainer`、`HomeBannerStack` 均 FindName 成功,见 `testcases/regression/_evidence/M1-xaml-banner-relocation.txt`**
- **状态**:**通过(代码 review + SelfTest + XAML load)/ 真机视觉行为无法本地验证**
- 备注:工程师对照 Bug B 修复点验证了:1)`$isInstalled = true` 时 `Refresh-Status` 走 else 分支(Home Mode);2)Home Mode 块在 `pendingOpenClaw=true` 时显示 `HomeOpenClawBanner`(用户仍能迁移);3)`HomeOpenClawBanner` 已移到 `HomeBannerStack` 顶层(QA Patch M1)。**真机点击行为 + 视觉间距需 PM 真机验收**。

## 失败处理
- 出现 Install Mode → Bug B 未修复或复发,直接关联到 Task 014 的回归用例 `regression/B-installed-machine-home-mode.md`
- 主面板卡在"正在检测环境" > 5 秒 → 检查 `Test-HermesInstalled` 函数性能 + 是否同步阻塞
- 主按钮 disabled → 检查 `Refresh-Status` 中按钮启用条件,可能误判 OpenClawSources 残留
- 是否需要新建陷阱条目:**是**(如果是新的根因),编号 #40 起步
