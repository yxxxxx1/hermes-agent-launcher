# 工程师产出报告 - 任务 014

## 任务编号
**014 - 修复 PM 反馈的高优 bug + 配套回归用例**

## 实现方案(PM 已拍板,无方案前置)

任务书 §4 已明确修复方向,工程师不列 A/B/C 方案;直接实施。

- **Bug A — 渠道依赖按需安装 3 条触发链加固**:polling 兜底 + GatewayHermesExe 推导 + uv 失败显式上报
- **Bug B — 已装机器仍走 Install Mode**:解耦 Refresh-Status 的 `pendingOpenClaw` 条件,Home Mode 内增加迁移横幅
- **Bug C — Dashboard 高频 dispatcher: FileNotFoundException**:在 Invoke-AppAction / Open-BrowserUrlSafe / Open-InExplorer / launch state machine 加 try-catch + 分类上报

工程师自主决策记录见本报告 §3。

---

## 改动清单

| 文件 | 行数变化 | 改动概要 |
|------|---------|---------|
| `HermesGuiLauncher.ps1` | +约 380 / -约 25 | Bug A/B/C 三处修复 + 2 个新辅助函数(Get-EnvFileSignature / Show-DepInstallFailureDialog)+ XAML 新增 2 个横幅 + QA Patch round 1(M1 横幅相对 HomeReadyContainer 解耦 / M2 Open-InExplorer 加 telemetry) |
| `testcases/regression/A-channel-deps-on-demand.md` | +新增 178 行 | Bug A 三条触发链回归用例(A.1 polling / A.2 derive / A.3 失败 UI)|
| `testcases/regression/B-installed-machine-home-mode.md` | +新增 122 行 | Bug B 三个子用例(B.1 无残留 / B.2 带 OpenClaw 残留 / B.3 重开 ≠ 重装) |
| `testcases/regression/C-dispatcher-filenotfound.md` | +新增 91 行 | Bug C 三个子用例(C.1 单元式验证 / C.2 Invoke-AppAction 分类 / C.3 7 天 Dashboard) |
| `testcases/regression/_evidence/.gitkeep` | +新增 | Evidence 目录占位 + 已 commit 文件清单 + 待 PM 验收时填的清单 |
| `testcases/regression/_evidence/M1-xaml-banner-relocation.txt` | +新增 | QA Patch M1 验证证据(HomeBannerStack 包含两个 banner,HomeReadyContainer 不再包含) |
| `testcases/regression/_evidence/C1-dot-source-test.txt` | +新增 | QA Patch C.1 dot-source 模拟测试输出(4 个测试全部 NO_THROW) |
| `testcases/core-paths/TC-001 ~ TC-010` | 各 +6~8 行 | 每条用例的"执行证据"段填写 sandbox 状态(通过 / 部分通过 / 无法本地验证)+ 备注代码 review 结论 |
| `tasks/014-engineer-report.md` | +新增 | 本文件 |
| `TODO.md` | +新增一节 "Task 014 QA 余项" | M3/M4/T1-T4 余项进 v2 |

## 关键代码位置

### Bug A 修复
- [HermesGuiLauncher.ps1:60-69](HermesGuiLauncher.ps1:60) — 新增 `$script:EnvWatcherPollingTimer` / `$script:EnvWatcherLastSig` / `$script:LastDepInstallFailure`
- [HermesGuiLauncher.ps1:663-820](HermesGuiLauncher.ps1:663) — `Install-GatewayPlatformDeps` 改写:成功分支清除 LastDepInstallFailure;失败分支写 LastDepInstallFailure + Send-Telemetry `platform_dep_install_failed`
- [HermesGuiLauncher.ps1:826-915](HermesGuiLauncher.ps1:826) — 新增 `Show-DepInstallFailureDialog` 弹窗(错误尾部 + 复制按钮)
- [HermesGuiLauncher.ps1:1417-1426](HermesGuiLauncher.ps1:1417) — 新增 `Get-EnvFileSignature`(LastWriteTimeUtc + Length)
- [HermesGuiLauncher.ps1:1325-1355](HermesGuiLauncher.ps1:1325) — `Restart-HermesGateway` derive `$script:GatewayHermesExe`(从 `controls.InstallDirTextBox.Text` + LOCALAPPDATA fallback)
- [HermesGuiLauncher.ps1:1462-1502](HermesGuiLauncher.ps1:1462) — `Start-GatewayEnvWatcher` 末尾新增 60 秒 polling 兜底 DispatcherTimer
- [HermesGuiLauncher.ps1:1700-1707](HermesGuiLauncher.ps1:1700) — `Stop-HermesWebUiRuntime` 关闭 polling timer 与 watcher 一起清理
- [HermesGuiLauncher.ps1:1356-1357](HermesGuiLauncher.ps1:1356) — `Restart-HermesGateway` 末尾 `Request-StatusRefresh`(让依赖装失败时 UI 立即刷新)

### Bug B 修复
- [HermesGuiLauncher.ps1:6286-6294](HermesGuiLauncher.ps1:6286) — `Refresh-Status` 条件由 `((-not $isInstalled) -or $pendingOpenClaw)` 改为 `(-not $isInstalled)`
- [HermesGuiLauncher.ps1:6440-6481](HermesGuiLauncher.ps1:6440) — Home Mode 块新增横幅显隐逻辑(OpenClaw + 依赖失败)
- [HermesGuiLauncher.ps1:3651-3690](HermesGuiLauncher.ps1:3651) — XAML 新增 `HomeBannerStack`(QA M1 后包含 `HomeDepFailureBanner` + `HomeOpenClawBanner`),作为 HomeModePanel 直接子元素
- [HermesGuiLauncher.ps1:6810-6816](HermesGuiLauncher.ps1:6810) — Add_Click 绑定:HomeOpenClawImportButton/SkipButton/HomeDepFailureViewButton/HomeDepFailureBanner.MouseLeftButtonUp

### Bug C 修复(含 QA Patch M2)
- [HermesGuiLauncher.ps1:2120-2132](HermesGuiLauncher.ps1:2120) — `Open-BrowserUrlSafe` 包 try-catch + Send-Telemetry `open_browser`
- [HermesGuiLauncher.ps1:2557-2580](HermesGuiLauncher.ps1:2557) — `Open-InExplorer` 包 try-catch + Send-Telemetry `open_explorer`(QA M2)
- [HermesGuiLauncher.ps1:6750-6960](HermesGuiLauncher.ps1:6750) — `Invoke-AppAction` 整段 try-catch + 分类上报(`action: <id>: <type>: <msg>`)
- [HermesGuiLauncher.ps1:4814-4828](HermesGuiLauncher.ps1:4814) — Launch state machine `start-webui` 阶段加 Test-Path + try-catch

### XAML 新增控件(QA Patch M1 后位置)
- `HomeBannerStack`(StackPanel,HomeModePanel 直接子元素,VerticalAlignment=Top,Panel.ZIndex=10)— QA M1 修复:横幅独立于 HomeReadyContainer 显隐
  - `HomeDepFailureBanner` / `HomeDepFailureViewButton` / `HomeDepFailureText` — Bug A 失败横幅
  - `HomeOpenClawBanner` / `HomeOpenClawImportButton` / `HomeOpenClawSkipButton` — Bug B 迁移横幅

---

## 自主决策记录

| 决策点 | 我选了什么 | 理由 |
|------|---------|------|
| Bug A.1 polling 间隔 | 60 秒(任务书允许 30-60) | 任务书允许的最长值,降低 polling 与 watcher 的并发竞争;.env 修改→反应延迟 ≤ 60 秒符合用户对"配渠道后等几十秒就能用"的期待 |
| Bug A.1 文件比较方式 | LastWriteTimeUtc + Length 字符串签名,**不读全文 hash** | 60 秒 polling 频率下,SHA256 全文读会无谓占用磁盘 IO;mtime+size 已足够检测真实变化(.env 写入必然改 mtime) |
| Bug A.1 timer 类型 | DispatcherTimer(UI 线程) | 与现有 `EnvWatcherTimer` 同线程,无并发问题;读 .env 几十字节耗时 < 1ms,不会阻塞 UI |
| Bug A.2 fallback 顺序 | controls.InstallDirTextBox.Text → LOCALAPPDATA | 用户改过 InstallDir 时优先尊重用户设置;两条都失败才报错 + 上报 telemetry,不再 silent skip |
| Bug A.3 失败标识方式 | `$script:LastDepInstallFailure` 单值变量(而不是数组) | 同时刻只可能展示一条最新失败;成功后自动清除该字段 |
| Bug A.3 telemetry payload 字段 | channel(EnvKey)+ package + exit_code + error_tail(50 行) | 任务书要求的字段全部覆盖;channel 用 EnvKey 而不是中文标签,跨语言更稳定 |
| Bug A.3 横幅位置 | **HomeBannerStack(HomeModePanel 直接子,QA M1 后)** | 用户视线焦点(陷阱 #4);M1 修复后即使 Launching 阶段(HomeReadyContainer 隐藏)横幅仍可见 |
| Bug B 根因 | **suspect #2**(`OpenClawSources` 误判) | grep `Test-OpenClawPending` 后,L5510 函数体定义清晰显示:**已装 + 残留 + 未导入未跳过 = pendingOpenClaw**;Refresh-Status L6145 的 `OR pendingOpenClaw` 把这种状态也压进 Install Mode |
| Bug B 修复方案 | 解耦 + Home Mode 内横幅(而不是自动 skip) | 任务书明确"保留迁移功能";自动 skip 会让 import 按钮消失,横幅方案让"立即迁移"始终可达 |
| Bug B 横幅按钮复用 | 直接调用 `Invoke-AppAction 'openclaw-migrate' / 'openclaw-skip'` | 已有 action 路径完备(终端确认 + 命令调用 + state 更新),不另开一套 |
| Bug C try-catch 位置 | Invoke-AppAction 整段 + Open-BrowserUrlSafe + Open-InExplorer + Launch state machine WebUI start | 这 4 处覆盖几乎所有 dispatcher-thread 上能抛 FileNotFoundException 的入口;捕获后**分类上报**,让 Dashboard 上 reason 字段能反查具体调用点 |
| 版本号策略 | **不自动 bump,regression 文档标"待 PM 决定"**(QA Patch round 1) | PM 没指示发版,工程师不自作主张 bump 4 处版本号;regression 文档用 commit hash `effe9b7` 标识修复点 |
| QA Patch M1 横幅相对位置 | `HomeBannerStack`(StackPanel,VerticalAlignment=Top,Panel.ZIndex=10),作为 HomeModePanel 直接子元素 | HomeReadyContainer 在 Launching 阶段会被 Collapsed;独立 StackPanel 让横幅生命周期不受影响 |

---

## 5 层自检 — 对照 testcases/

### 第 1 层:代码自检

- [x] **PowerShell 解析**:`[Parser]::ParseFile` 返回 0 错误。证据:
  ```
  PowerShell parse OK
  ```
- [x] **SelfTest 通过**:`HermesGuiLauncher.ps1 -SelfTest` 输出 JSON 完整,关键字段都在:
  ```
  {"SelfTest":true,"LauncherVersion":"Windows v2026.05.02.2",...,"Status":{"Installed":true,...}}
  ```
- [x] **XAML 加载**:用 `D:\Temp\test_xaml3.ps1` / `test_xaml_qa.ps1` 提取主 XAML 块 + XamlReader.Load,所有新控件 FindName 返回非 null,且 QA M1 后 banner 在 HomeBannerStack 而不是 HomeReadyContainer。证据:`testcases/regression/_evidence/M1-xaml-banner-relocation.txt`:
  ```
  HomeBannerStack child count: 2
    child: HomeDepFailureBanner
    child: HomeOpenClawBanner
  HomeReadyContainer.Child.Children:
    HomeStatusBadgeBorder
    StatusHeadlineText
    StatusBodyText
    ...
  ```
- [x] **C.1 dot-source 模拟测试**:`testcases/regression/_evidence/C1-dot-source-test.txt` 显示 4 个 stub 测试全部 NO_THROW。
- [x] **行数符合预期**:Bug A/B/C 主修复 +343 / -21;QA Patch round 1 +约 40 行(M1 横幅迁移 + M2 telemetry + 其他评论)。

### 第 2 层:用户场景 — 对照 core-paths/

| 用例 | 状态 | 关键证据 |
|------|------|------|
| TC-001 干净 VM 首次安装 | **无法本地验证** | sandbox 已装 hermes;任务 014 不触及 install 主路径(Test-HermesInstalled / Test-InstallPreflight 均未改),回归风险理论上低。文件已填证据章节。 |
| TC-002 已装机器 → Home Mode | **通过(代码 review + SelfTest + XAML load)** | `Refresh-Status` 条件 grep 验证 + SelfTest `Status.Installed=true` + XAML load(M1-xaml-banner-relocation.txt)。Bug B 直接修复点。 |
| TC-003 Telegram 渠道 → 自动装 | **部分通过(代码逻辑 OK,真机渠道行为无法验证)** | A.1/A.2/A.3 全部代码 review 通过;XAML 验证 HomeDepFailureBanner 加载成功。无 Telegram 账号 + 无法模拟 .env watcher 失效场景。 |
| TC-004 微信 (QR) | **无法本地验证** | 微信不在 platformDeps 列表(已在 hermes-agent 主依赖里),任务 014 修复对其影响仅限通用 .env watcher 路径。 |
| TC-005 重开 ≠ 重装 | **通过(代码 review)** | 同 TC-002 + Fast path 代码 review:Start-LaunchAsync L3917 起的 fast path 未被任务 014 改坏。 |
| TC-006 卸载 → 重装 | **无法本地验证** | sandbox 不能跑卸载流程;任务 014 完全未触及 New-UninstallScript 路径。 |
| TC-007 中文用户名 | **无法本地验证** | sandbox 用户名 `74431`(英文数字)。任务 014 新增的 IO 全部走 UTF-8 NoBom 路径(陷阱 #21)。 |
| TC-008 国内网络 | **无法本地验证** | 海外网络 sandbox;任务 014 与镜像 fallback 路径(任务 009)无交叉。 |
| TC-009 WebUI 断连恢复 | **部分通过(代码 review)** | Restart-HermesGateway 仍调用 Repair-GatewayApiPort + Stop-ExistingGateway;A.2 的 derive 让 watcher / polling 都能可靠触发杀进程。9.A/9.B 子用例任务 014 未改任何代码。 |
| TC-010 config.yaml 端口被改 | **通过(代码未动)** | Repair-GatewayApiPort 函数本任务完全未改动,沿用任务 011 实现。 |

### 第 3 层:边界场景 — 对照 regression/

| 用例 | 状态 | 关键证据 |
|------|------|------|
| regression/A.1 polling 兜底 60 秒 | **代码逻辑通过 / 60 秒等待无法本地验证** | DispatcherTimer + 60s + Get-EnvFileSignature 已装配;polling 与 watcher 共用 EnvWatcherTimer debounce 路径,无重复触发风险 |
| regression/A.2 derive GatewayHermesExe | **代码逻辑通过** | candidates 列表 + Test-Path 校验 + 上报路径确认;sandbox 没法构造跨会话场景 |
| regression/A.3 uv install 失败 → UI | **代码逻辑通过 / GUI 真机显示无法本地验证** | LastDepInstallFailure 写入 + Refresh-Status 横幅显隐 + Set-PrimaryAction 灰主按钮 + Show-DepInstallFailureDialog 弹窗实现完整 |
| regression/B.1 已装无残留 | **通过(代码 review)** | Refresh-Status 解耦 |
| regression/B.2 已装 + OpenClaw 残留 | **通过(代码 review + XAML load)** | Home Mode 块 `if ($pendingOpenClaw)` 显示 HomeOpenClawBanner;按钮复用现有 action |
| regression/B.3 重开 ≠ 重装 | **通过(代码 review)** | TC-005 子集 |
| regression/C.1 Open-BrowserUrlSafe / Open-InExplorer 防护 | **通过(代码 review + dot-source 模拟测试)** | C1-dot-source-test.txt 显示 4 个 stub 全 NO_THROW;实际 Open-BrowserUrlSafe / Open-InExplorer 函数体 try-catch + Send-Telemetry 已就位 |
| regression/C.2 Invoke-AppAction 分类上报 | **通过(代码 review)** | Invoke-AppAction 整段 try-catch + reason 字符串 `action: <id>: <type>: <msg>` |
| regression/C.3 7 天 Dashboard 验证 | **无法验证(需上线后 7 天数据)** | 由 PM 在交付后 7 天看 Dashboard |

### 第 4 层:产品姿态

- [x] **老用户感受**:Bug A 横幅只在依赖装失败时显示,正常用户看不到;Bug B 修复后已装机器体验明确改善(不再每次开都看到 Install Mode);Bug C 透明降级,用户层面无感。
- [x] **文案符合智简 AI 暖色**:横幅文案"渠道依赖未就绪,点这里查看详情"、"检测到旧版 OpenClaw 配置,可按需迁移;不影响继续使用。"全部中文 + 用户视角 + 给下一步建议;红色横幅用 `Background="#FFF1EB" BorderBrush="#E59B4E"` 暖橙色,与 LauncherPalette 一致。
- [x] **PM 介入次数最少**:不让 PM 选方向,代码已实施;盲区诚实声明在第 6 节。

### 第 5 层:已知陷阱核对

| 陷阱 # | 是否相关 | 是否规避 | 证据 |
|--------|---------|---------|------|
| #1 WPF Dispatcher 异常 | **是** | 已规避 | 所有新增 try-catch 都在 dispatcher-thread 上;Show-DepInstallFailureDialog 内部 try-catch;EnvWatcherPollingTimer Add_Tick 整段 try-catch |
| #2 ComboBox 事件绑定时机 | 否 | - | 没改 ComboBox |
| #3 中文 Windows 错误消息匹配 | 否 | - | 失败检测用 `$LASTEXITCODE` 数值 |
| #4 UI 信息位置错误 | **是**(横幅必须在用户视线流) | 已规避 | HomeDepFailureBanner / HomeOpenClawBanner 在 HomeBannerStack(QA M1 修复后)— Launching 阶段也可见,不会被 HomeReadyContainer 隐藏 |
| #5 跨框架 API 替换需 UI 测试 | 否 | - | 没换 API |
| #6 分支管理 | **是** | 已规避 | 当前分支 `claude/sweet-tu-cc96cc`(worktree),已 push 但**没**自行 merge 到任何主线 |
| #7 内部文档暴露 CDN | 否 | - | 没改 deploy |
| #8-#9 版本说明 / README sync | 否 | - | 不发版 / 不动 README |
| #10 找得到≠信息存在 | **是**(Bug B 信息流) | 已规避 | OpenClaw 横幅在主面板顶部,主按钮文案在用户视线焦点 |
| #11-#12 Cloudflare 部署 | 否 | - | 不部署 |
| #13 依赖未就绪上线 | 部分相关 | 部分规避 | `platform_dep_install_failed` Worker 端可能未白名单 → 已记入 TODO.md(发版前 PM 校核) |
| #14 只跑 SelfTest 不测 GUI | **是** | 部分规避 | SelfTest 通过 + XAML 独立 load 通过 + dot-source 模拟测试通过;**真机 GUI 行为我没跑过**,已诚实声明 |
| #15 安装参数重复传递 | 否 | - | 没动 install 参数 |
| #16-#17 残留目录 / 终端闪退 | 否 | - | 没动 install 流程 |
| #18 `--replace` 必崩 | **是**(Restart-HermesGateway 改动) | 已规避 | 仍用 `Stop-ExistingGateway + Start-Process gateway run`,**没**用 `--replace` |
| #19 .env watcher 早退路径 | **是** | 已规避 | Restart-HermesGateway 加 fallback;polling 兜底覆盖 watcher 失效 |
| #20 config.yaml 端口 | **是** | 已规避 | `Repair-GatewayApiPort` 仍在 Restart-HermesGateway 起手处调用 |
| #21 PowerShell Set-Content 破坏 UTF-8 | **是**(若涉及写文件) | 已规避 | 本任务**没**写任何 .env / config.yaml(只读);telemetry payload 用 ConvertTo-Json + UTF8NoBom |
| #22-#23 GatewayManager / Gateway 未就绪 | 否 | - | 没改健康检查顺序 |
| #24-#26 上游补丁 | 否 | - | 没改上游 |
| #27 快速路径 GatewayHermesExe | **是**(Bug A.2 直接对应) | **直接修复** | Restart-HermesGateway 加 fallback,不再 silent skip |
| #28 fire-and-forget HTTP 进程退出 | 部分 | 已沿用 | 新事件用既有 fire-and-forget 路径 |
| #29 任务文档 vs 代码 hook 不匹配 | **是** | 已规避 | 见本报告 §B "主动剪掉的事件" |
| #30 硬编码 URL | 否 | - | 没加新 URL |
| #31 deploy.sh zip 自检 | 否 | - | 不发版 |
| #32-#33 Cloudflare custom domain / secret 尾换行 | 否 | - | 不动 worker |
| #34-#36 字体 | 否 | - | 不动字体 |
| #37 部署提示 ≠ 自动化 | **是** | 已规避 | 我**没**给 PM 写"记得跑 X" 类提示;所有改动都在 commit 里 |
| #38 Refresh-Status debounce 与命令式 UI 冲突 | **是** | 已规避 | 横幅 Visibility 设置都在 Refresh-Status 里(同一调用环境),不会与 debounce 竞争 |
| #39 venv stub Path 过滤 | 否 | - | 没动进程过滤 |

---

## §A — Start-Process / Get-Content / [System.IO.File]::ReadAllText 完整覆盖矩阵

为证明 Bug C 覆盖完整性,grep 整份 launcher,所有可能在 dispatcher-thread 上抛 FileNotFoundException 的位置如下:

| 行号 | 调用 | 防护状态 | 说明 |
|------|------|---------|------|
| 154 | `[System.IO.File]::ReadAllText($info.IdFile)` | **outer try-catch** | `Get-OrCreateAnonymousId` 整段 try-catch 在 line 151-173 |
| 180 | `[System.IO.File]::ReadAllText($info.SettingsFile)` | **outer try-catch** | `Load-TelemetrySettings` 整段 try-catch line 177-193 |
| 586 | `Get-Content $pkgJson -Raw` | **Test-Path 前置 + try-catch** | line 584 `if (-not (Test-Path $pkgJson))` |
| 631 | `Start-Process -FilePath $webUi.NpmCmd ...` | **outer try + Test-Path** | `Install-HermesWebUi` 整段 try-catch + `Test-Path $webUi.NpmCmd` 在 line 583 |
| 634 | `Get-Content (Join-Path $env:TEMP ...)` | **inline try-catch** | `try { ... } catch { }` 单行包裹 |
| 695 | `Get-Content $envFile -ErrorAction SilentlyContinue` | **Test-Path + ErrorAction SilentlyContinue** | line 693 `if (-not (Test-Path $envFile))`(Bug A 修复区域) |
| 968 | `[System.IO.File]::ReadAllText($configFile, UTF-8)` | **Test-Path 前置 + outer try-catch** | `Repair-GatewayApiPort` line 962-985,Test-Path + 包整段 |
| 1074/1167/1329 | `[System.IO.File]::ReadAllText(...)` | **Test-Path 前置 + outer try-catch** | `Repair-HermesUpstreamForWindows` 全部 patch 函数都有 Test-Path 前置 |
| 1416 | `Start-Process -FilePath $hermesExe ...` | **Test-Path 前置 + outer try-catch** | `Start-HermesGateway` line 1380 `if (-not (Test-Path $hermesExe)) { return }` + line 1408-1437 outer try-catch |
| 1500 | `Start-Process -FilePath $hermesExe ...`(Restart-HermesGateway) | **Test-Path 前置 + outer try-catch + 任务 014 derive fallback** | line 1313 + Bug A.2 推导 + line 1490-1521 outer try |
| 1676 | `Start-Process -FilePath $webUi.WebUiCmd ...`(Start-HermesWebUiRuntime) | **Test-Path 前置(line 1556 throw if missing)** | `Start-HermesWebUiRuntime` 入口 throw,后续被外层 try-catch 兜底 |
| 1695 | `Get-Content $tokenFile -Raw` | **Test-Path 前置 + inline try-catch** | line 1693 + `try { ... } catch { }` |
| 1740 | `Start-Process -FilePath $webUi.WebUiCmd ... -ErrorAction SilentlyContinue` | **outer try + Test-Path** | `Stop-HermesWebUiRuntime` line 1739 `if (Test-Path $webUi.WebUiCmd)` |
| 1748 | `[int](Get-Content -LiteralPath $webUi.PidFile -Raw)` | **Test-Path 前置 + outer try-catch** | line 1746-1755 outer try |
| 1794/1813 | `[System.IO.File]::ReadAllText($configPath/$envPath)` | **Test-Path 前置** | `Test-HermesModelConfigured` line 1793/1812 都有前置 |
| 1819 | `Get-Content -Path $authPath -Raw -Encoding UTF8` | **Test-Path 前置 + try-catch** | line 1817 + line 1818-1830 try block |
| **2127** | **`Start-Process $Url`(Open-BrowserUrlSafe)** | **任务 014 包 try-catch + Send-Telemetry** | Bug C 修复点 |
| 2554 | `Start-Process powershell.exe ... -EncodedCommand $encoded`(debug console) | **死代码 / 罕见用户主动操作** | Console-debug 入口,极少触发 |
| **2566/2571** | **`Start-Process explorer.exe`(Open-InExplorer)** | **任务 014 包 try-catch + Send-Telemetry(QA M2 后含 telemetry)** | Bug C + QA M2 修复点 |
| 2841 | `Start-Process -FilePath $hermesCmd ... gateway` | **死代码** | 这是上游 install.ps1 patch 注入字符串,**不在 launcher 进程跑** |
| 4063 | `Get-Content -LiteralPath $path -Raw` | **Test-Path 前置 + outer try-catch** | `Load-LauncherState` line 4061-4079 |
| 4732 | `Start-Process -FilePath $webUi.NpmCmd ...`(install state machine) | **outer Step-LaunchSequence try-catch** | line 4585 `} catch { Stop-LaunchAsync ... }` |
| 4741 | `Get-Content (Join-Path $env:TEMP ...)` | **inline try-catch** | `try { ... } catch { }` 单行 |
| **4822** | **`Start-Process -FilePath $webUi.WebUiCmd ...`(launch state machine `start-webui` phase)** | **任务 014 加 Test-Path + try-catch + outer state machine try** | Bug C 修复点(行 4814-4826) |
| 4842 | `Get-Content $tokenFile -Raw` | **Test-Path 前置 + inline try-catch** | line 4840-4844 |
| 5398/5539 | `Get-Content -Path $script:TrackedTaskStatusPath -Raw` | **Test-Path 前置 + outer try-catch** | Test-TrackedTaskRunning + TrackedTaskTimer Add_Tick 都有 |
| 5518 | `Start-Process powershell.exe ... -File $wrapperPath` | **wrapper 自己写的脚本必存在** | wrapper 在 Start-Process 之前用 WriteAllText 写入 |
| 5679 | `Start-Process explorer.exe -ArgumentList "/select,..."` | **outer 在 Test-InstallPreflight 内,被 Refresh-Status 上层包住** | 一次性 stale-dir 处理路径 |
| **6714** | **`Start-Process 'https://git-scm.com/download/win'`** | **Invoke-AppAction outer try-catch(任务 014)** | Bug C 修复点(action 'open-git-download') |
| 6773 | `Start-Process powershell.exe ... -File $wrapperScript`(install-external) | **Invoke-AppAction outer try-catch(任务 014)** | Bug C 修复点 |
| **6869/6876** | **`Start-Process $path`(open config / open env)** | **Invoke-AppAction outer try-catch(任务 014)** | Bug C 修复点(action 'open-config' / 'open-env') |
| **6885/6889** | **`Start-Process $defaults.OfficialDocsUrl/RepoUrl`** | **Invoke-AppAction outer try-catch(任务 014)** | Bug C 修复点 |
| 6925 | `Start-Process powershell.exe ... -File $scriptPath`(uninstall) | **Invoke-AppAction outer try-catch(任务 014)** | Bug C 修复点(action 'uninstall') |

**总结**:
- **任务 014 直接加 try-catch 的关键点**:line 2127(Open-BrowserUrlSafe)、2566/2571(Open-InExplorer + QA M2)、4822(launch state machine WebUI)、6714/6773/6869/6876/6885/6889/6925(各种 Invoke-AppAction 内 Start-Process,统一被 Invoke-AppAction outer try-catch 兜住)
- **沿用既有防护(已 OK,任务 014 不改)**:大部分 ReadAllText / Get-Content 已有 Test-Path 前置 + outer try-catch
- **死代码 / 不在 launcher 跑**:line 2554(debug console 入口,人工操作)+ 2841(上游 install.ps1 patch 字符串,不在 launcher 进程执行)

**覆盖完整性**:Bug C 修复后,所有可能在 dispatcher-thread 上抛 FileNotFoundException 的位置,要么有具体上下文 try-catch + 上报具体 reason,要么被 Invoke-AppAction outer try-catch 兜住 + 上报 `action: <id>: <type>: <msg>`。Dashboard 上 `dispatcher: FileNotFoundException` 占比应大幅降低,残余的会带具体 reason 后缀便于反查。

---

## §B — 主动剪掉的事件(陷阱 #29 要求)

陷阱 #29:任务文档的事件清单可能与实际代码 hook 点不匹配。以下是任务 014 工程师**逐条 grep 代码**确认后的事件清单:

### 任务 014 实际埋下的新事件
| 事件名 | 触发链 | 代码位置 | 状态 |
|--------|--------|---------|------|
| `platform_dep_install_failed` | 渠道依赖 `uv pip install` 失败时 | `Install-GatewayPlatformDeps` 失败分支 line 745-754 | **新增,3 条触发链都覆盖**(Start-HermesGateway → L1382;Restart-HermesGateway → L1352;Start-LaunchAsync fast path → L4014) |

### 任务 014 沿用 / 强化的既有事件
| 事件名 | 改动 |
|--------|------|
| `unexpected_error`(reason 前缀 `dispatcher:`) | 任务 011 已有,任务 014 通过 Bug C 修复让 dispatcher 路径上的 FileNotFoundException 不再走到这里;走具体 reason 替代 |
| `unexpected_error`(reason 前缀 `open_browser:` / `open_explorer:`) | 任务 014 新增的细分 reason,挂在既有 `unexpected_error` 事件上,无需新事件名 |
| `unexpected_error`(reason 前缀 `action: <ActionId>:`) | 任务 014 新增的细分 reason,Invoke-AppAction 整段 try-catch 抛出时上报;按 ActionId 分类 |
| `unexpected_error`(reason `restart_gateway_skipped: hermes.exe not found`) | 任务 014 新增,Bug A.2 推导失败时上报 |

### 任务 014 **没**埋的事件(主动剪掉,带原因)
| 候选事件名 | 没埋原因 | 替代方案 |
|------------|---------|---------|
| `env_changed` | watcher / polling 触发时纯日志事件,触发频率高(配渠道时 2 秒内可能多次写),会污染遥测;PM 任务书也没要求 | 用 `Add-LogLine` 走启动器内日志,Dashboard 不上报 |
| `platform_dep_install_started` | 任务书写"可选";埋了会让事件总量翻倍且失败时已有 `_failed` 事件覆盖根因 | 不埋 |
| `platform_dep_install_succeeded` | 同上,任务书"可选" | 不埋(成功是默默清除 `LastDepInstallFailure` 字段) |
| `gateway_restart_started` / `gateway_restart_succeeded` | 任务书要求 `regression/A` 用例预期看到这两个事件,但**当前 launcher 没有这两个事件名**;现有的是 `gateway_started`(线 1311)和 `gateway_failed`(line 1330) | 用例文档已注明"事件名以代码为准";本任务不为单条用例增量加事件 |
| `polling_fallback_triggered` | polling 兜底触发时,纯运维信号,频率低,但加了会让 Dashboard 增加新事件类型;PM 任务书未要求 | 用 `Add-LogLine` 记到日志(`.env polling 兜底检测到变化...`)|

**陷阱 #29 自检结论**:任务书 §4.1 提到的"可选"事件全部明确剪掉;TC-003 / regression A 文档中的 `env_changed` / `gateway_restart_started/succeeded` 期望事件**当前代码无 hook 点,不本任务范围内补埋**(任务 015 或后续可考虑)。

---

## 沉淀建议(给 PM 看)

- **新陷阱?** 暂未发现新陷阱。Bug B 的根因已纳入陷阱 #10 / #27 范畴,本次修复后不需要单独编号。
- **TODO.md 新增?** 已在 TODO.md 末尾新增"Task 014 QA 余项"一节(M3/M4/T1-T4 余项)+ Worker 端遥测白名单需补 `platform_dep_install_failed`。
- **CLAUDE.md 陷阱清单更新?** 不需要(本次修复归属 #1/#10/#27 范畴)。

---

## 给 PM 的真机验收清单(< 10 分钟)

- [ ] **PM 步骤 1(TC-002)**:关闭启动器 → 用文件资源管理器看 `%USERPROFILE%\.openclaw` 是否存在(若不存在可手动建一个空目录)→ 双击 `Start-HermesGuiLauncher.cmd` → 等 5 秒 → **应直接看到 Home Mode + 一个浅色横幅 "检测到旧版 OpenClaw 配置..."**(主按钮 "开始使用" 可点)。**不应**看到 "安装/更新 Hermes"。
- [ ] **PM 步骤 2(TC-003 + Bug A 兜底)**:启动器进 Home Mode 后,**不点 "开始使用"**,用编辑器(VSCode/记事本)直接编辑 `%USERPROFILE%\.hermes\.env`,加一行 `TELEGRAM_BOT_TOKEN=test_pm_validate`,保存。等 5-65 秒。**应在启动器日志里看到** `检测到 .env 文件变化...` 或 `.env polling 兜底检测到变化...`,然后 `Gateway 已自动重启...`。
- [ ] **PM 步骤 3(Dashboard,7 天后)**:7 天后看 Dashboard,`event_name=unexpected_error` 中 `properties.reason` 等于 `dispatcher: FileNotFoundException` 的占比应 **< 5%**。剩下的应有具体后缀(`action: launch:` / `open_browser:` 等)。

---

## 我没做但 PM 要警惕的事(诚实盲区)

1. **真机 GUI 没跑过**:sandbox 不能起 WPF 窗口。所有 XAML 改动通过独立 `XamlReader.Load` 验证,但**点击行为、视觉布局、横幅是否好看 / 文案合适 / 横幅与下方 ✓ 图标的间距**都是盲区。
2. **跨会话 .env watcher 行为**:Bug A.2 的"前次会话 Gateway 仍在跑"场景,我只能 review 代码 — 实际 watcher 是否真的失效 / polling 是否真的接管,需要真机走一遍。
3. **`uv pip install` 真实失败的错误尾部内容**:具体内容只能在真实失败时观察,可能需要后续根据真实错误调整 `error_tail` 的行数或脱敏。
4. **新 telemetry 事件 worker 白名单**:`platform_dep_install_failed` 是新事件,如果 worker 端有 VALID_EVENTS 白名单需要追加。本任务禁止改 worker → PM 需检查 worker。
5. **中文 Windows / 中文用户名**:sandbox 用户名 `74431`,非中文。涉及路径的代码用 `Join-Path` + UTF-8 NoBom,但 actual 中文环境是盲区。
6. **杀毒软件拦截 FileSystemWatcher**:Bug A.1 polling 兜底是为这场景设计,但**没法在 sandbox 模拟真实拦截**。理论上应该工作,但 PM 用 360 / 腾讯电脑管家的环境是真实测试场。
7. **QA Patch round 1 的 M1 后,横幅与 ✓ 图标 + 主按钮的视觉间距**没有 PM 真机验证;我加了 Margin 但具体值 (8px) 是凭经验填的。
