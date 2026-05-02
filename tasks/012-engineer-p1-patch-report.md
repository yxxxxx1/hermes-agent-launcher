# Task 012 工程师 P1 Patch 报告

**工程师**: engineer agent
**worktree**: relaxed-ride-6f33a2
**基于 commit**: 138c8d2
**日期**: 2026-05-02

---

## 一、改动清单

| 文件 | 行数变化 | 改动概要 |
|------|---------|---------|
| `HermesGuiLauncher.ps1` | +107 / -21 | P1-1 按钮色修复 + P1-3 解压异步化 + 健康检查超时优化 |
| `TODO.md` | +22 / 0 | P1-2 评估结论追加 v2 待办条目 |

**函数级改动**：
- `Set-InstallActionButtons`（行 ~5437）：PrimaryEnabled 分支颜色从绿色 `#22C55E` 改为暖橙 `#D9772B`；disabled 态从深蓝色改为米色系
- `Start-LaunchAsync`（行 ~3974）：`$script:LaunchState` 初始化追加 `ExtractRunspace / ExtractPowerShell / ExtractAsyncResult` 三个字段
- `Stop-LaunchAsync`（行 ~4005）：新增 Runspace 安全释放块（`ExtractPowerShell.Stop()` + `ExtractRunspace.Close()`）
- `Step-LaunchSequence - download-node phase`（行 ~4347）：下载完成后不再直接 `Expand-Archive`，而是 `$s.Phase = 'extract-node'`
- `Step-LaunchSequence - extract-node phase`（新增 case，行 ~4356）：后台 Runspace 执行 `Expand-Archive`，DispatcherTimer 轮询 `IsCompleted`
- `Step-LaunchSequence - wait-gateway-healthy phase`（行 ~4455）：移除 `Start-Sleep -Milliseconds 1000`；`Invoke-RestMethod TimeoutSec 2 → 1`
- `Test-HermesWebUiHealth`（行 ~639）：`Invoke-WebRequest TimeoutSec 3 → 1`

---

## 二、P1-1 修复证据

### 修改前（grep 输出）

```powershell
# Set-InstallActionButtons 函数内，PrimaryEnabled = true 分支
$controls.StartInstallPageButton.Background = '#22C55E'   # 绿色
$controls.StartInstallPageButton.BorderBrush = '#22C55E'
$controls.StartInstallPageButton.Foreground = '#04110A'

# disabled 态
$controls.StartInstallPageButton.Background = '#1E293B'   # 深蓝黑
$controls.StartInstallPageButton.BorderBrush = '#334155'
$controls.StartInstallPageButton.Foreground = '#94A3B8'
```

### 修改后

```powershell
if ($PrimaryEnabled) {
    # 任务 012 P1-1：统一使用 LauncherPalette 主色暖橙，与 State 1/6 主按钮一致
    $controls.StartInstallPageButton.Background = '#D9772B'
    $controls.StartInstallPageButton.BorderBrush = '#D9772B'
    $controls.StartInstallPageButton.Foreground = '#FCFCF7'
} else {
    # 禁用态：使用浅色系暗哑色（米色系）
    $controls.StartInstallPageButton.Background = '#D4CFC5'
    $controls.StartInstallPageButton.BorderBrush = '#C8C3B9'
    $controls.StartInstallPageButton.Foreground = '#897F75'
}
```

### 一致性参考（State 1 / State 6 主按钮）

**State 1 主按钮**（XAML 静态，行 ~3127）：
```xml
<Button x:Name="StartInstallPageButton"
        Style="{StaticResource PrimaryButtonStyle}" Content="开始安装"/>
```
`PrimaryButtonStyle` 定义：
```xml
<Setter Property="Background" Value="{StaticResource AccentGradientBrush}"/>
<!-- AccentGradientBrush: #E58236 → #D9772B → #A85420，暖橙渐变 -->
<Setter Property="Foreground" Value="{StaticResource TextOnAccentBrush}"/>
<!-- TextOnAccentBrush = #FCFCF7 -->
```

**State 6 主按钮**（XAML 静态，行 ~3173）：
```xml
<Button x:Name="ConfirmInstallLocationButton"
        Style="{StaticResource PrimaryButtonStyle}" Content="位置已确认，继续"/>
```
同样使用 `PrimaryButtonStyle`（暖橙渐变 + `#FCFCF7` 文字）。

**结论**：State 7 的"开始安装"按钮现在使用 `#D9772B`（`accentPrimary` 暖橙 + `#FCFCF7` 文字），与 State 1 / 6 的 `PrimaryButtonStyle` 色系一致。

---

## 三、P1-3 修复证据

### 诊断：阻塞点定位

**主要阻塞点**：`Expand-Archive` 在 `download-node` phase 同步执行（Node.js zip 约 30MB，解压 3-10 秒）

```powershell
# 原代码（DispatcherTimer tick 里同步调用）：
Expand-Archive -Path $s.DownloadZipPath -DestinationPath $webUi.NodeRoot -Force
```

**次要阻塞点**：
1. `wait-gateway-healthy` 中 `Start-Sleep -Milliseconds 1000`（每 tick 多阻塞 1s）
2. `Invoke-RestMethod -TimeoutSec 2` 在 `wait-gateway-healthy`（每 tick 最多阻塞 2s）
3. `Test-HermesWebUiHealth` 的 `Invoke-WebRequest -TimeoutSec 3` 在 `wait-healthy`（每 tick 最多阻塞 3s）

### 异步化方案

**extract-node 独立阶段 + Runspace + BeginInvoke 轮询**：

```powershell
# download-node phase 末尾：下载完成后不再直接解压，转移到独立阶段
$s.Phase = 'extract-node'

# extract-node phase：
'extract-node' {
    if (-not $s.ExtractRunspace) {
        # 捕获变量（Runspace 不共享作用域）
        $zipPathCapture  = $s.DownloadZipPath
        $nodeRootCapture = $webUi.NodeRoot

        # 后台 Runspace
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($zipPath, $nodeRoot)
            try {
                Expand-Archive -Path $zipPath -DestinationPath $nodeRoot -Force
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                return $null   # null = success
            } catch {
                return $_.Exception.Message
            }
        }).AddArgument($zipPathCapture).AddArgument($nodeRootCapture)
        $s.ExtractRunspace    = $rs
        $s.ExtractPowerShell  = $ps
        $s.ExtractAsyncResult = $ps.BeginInvoke()
        return   # UI 线程立即返回，下一 tick 继续轮询
    }

    # 未完成则等下一 tick（UI 线程不阻塞）
    if (-not $s.ExtractAsyncResult.IsCompleted) { return }

    # 收集结果 + 释放 Runspace...
}
```

### Dispatcher 异常处理

Runspace 内部没有 WPF Dispatcher（纯后台线程），错误以**返回值**方式传回 UI 线程，不走 Dispatcher。UI 线程在收集结果时的 `try/catch/finally` 遵循陷阱 #1：

```powershell
# finally 块保证资源释放，不论是否有异常
} finally {
    try { $s.ExtractPowerShell.Dispose() } catch { }
    try { $s.ExtractRunspace.Close(); $s.ExtractRunspace.Dispose() } catch { }
    $s.ExtractRunspace    = $null
    $s.ExtractPowerShell  = $null
    $s.ExtractAsyncResult = $null
}
# throw 在 finally 之后，Dispatcher 路径正常继续（外层 catch 会调用 Stop-LaunchAsync）
```

`Stop-LaunchAsync` 中追加 Runspace 安全释放，防止用户取消时资源泄漏：

```powershell
function Stop-LaunchAsync {
    param([string]$ErrorMessage)
    if ($script:LaunchTimer) { $script:LaunchTimer.Stop() }
    # 任务 012 P1-3：如果解压 Runspace 还在跑，安全释放
    if ($script:LaunchState) {
        try {
            if ($script:LaunchState.ExtractPowerShell) {
                $script:LaunchState.ExtractPowerShell.Stop()
                $script:LaunchState.ExtractPowerShell.Dispose()
            }
        } catch { }
        try {
            if ($script:LaunchState.ExtractRunspace) {
                $script:LaunchState.ExtractRunspace.Close()
                $script:LaunchState.ExtractRunspace.Dispose()
            }
        } catch { }
    }
    $script:LaunchState = $null
    ...
}
```

### 状态过渡

```
check-install → (如果需要下载) → download-node → extract-node → npm-install
                                                  ↑ 本次新增独立阶段，Runspace 解压
check-install → (已安装) → start-gateway → wait-gateway-healthy → start-webui → wait-healthy
                                            ↑ 移除 Sleep, 减少 TimeoutSec
```

每个 phase 对应 `$script:LaunchPhaseMap` 中的视觉配置，`extract-node` 已预先定义在 Phase Map（Step 3，进度 38-45%）。

### 修改前后对比

| 场景 | 修改前 | 修改后 |
|------|-------|-------|
| Node.js 解压（30MB zip） | UI 线程同步阻塞 3-10 秒 → 窗口"未响应" | Runspace 后台解压，UI 线程持续响应 |
| gateway 健康等待 | 每 tick = 2s HTTP + 1s Sleep = 最长 3.8s | 每 tick = 1s HTTP + 0s Sleep = 最长 1.8s |
| webui 健康检查 | 每 tick 最长阻塞 3s | 每 tick 最长阻塞 1s |

### 诚实声明

此项是否真的消除"未响应"：**需 PM 真机验证**。原因：
- "未响应"是 Windows 对 UI 线程 > ~5s 无响应的判断，Runspace 方案理论上消除了最大的阻塞点
- 但 `Start-HermesGateway` 中的 `Install-GatewayPlatformDeps` 仍有同步 Python 调用（范围外，当前未修）
- 本地没有新安装环境（Node.js 已存在），无法真实走到 `extract-node` 阶段验证

---

## 四、P1-2 评估结论

**判定：转 v2**

### 评估证据

**`Build-InstallArguments` 函数**（行 ~2472）：
```powershell
function Build-InstallArguments {
    # 仅返回脚本级参数 (-InstallDir, -HermesHome, -Branch, -NoVenv, -SkipSetup)
    $scriptArgs = @('-InstallDir', $InstallDir, '-HermesHome', $HermesHome, '-Branch', $Branch)
    ...
    return $scriptArgs
}
```
只负责参数构建，无进度接入点。

**`New-ExternalInstallWrapperScript` 函数**（行 ~4759）：
封装了 `powershell.exe -File $InstallScriptPath @installArgs`，输出全进独立终端，无法在 launcher 内截获。

**上游 `install.ps1` 进度输出格式**：
无结构化格式（仅 `Write-Host` 状态文字，无阶段标记符如 `[STAGE X/Y]`）。要解析须依赖文本启发式匹配，会随上游版本变动而失效，违反"不 fork 上游"原则。

**估算改动行数**：> 150 行（stdout 重定向 + Runspace tail + 正则匹配 + 4 阶段 UI 更新 + 错误处理）

### 决定

已追加到 `TODO.md`（"待办：State 8 安装中 in-app 进度条"条目，包含 v2 建议实现方向）。

---

## 五、自检结果

| 层 | 项目 | 结果 |
|----|------|------|
| 1 | AST 解析 | **0 错误**（`[Parser]::ParseFile` 输出 `Error count: 0`）|
| 2 | SelfTest | **通过**（输出 `"SelfTest":true`，所有字段正常）|
| 3 | XAML Load | **盲区声明**：没有 GUI 环境可运行 WPF 窗口；P1-1 只改了 PowerShell 运行时颜色赋值，未改 XAML 节点；P1-3 新增 PowerShell 逻辑，无新 XAML |
| 4 | 用户场景 | P1-1 按钮色正确 → **盲区（PM 真机）**；P1-3 "未响应"消失 → **盲区（PM 真机）**；P1-2 评估正确、无新代码引入 bug → 已自测 |
| 5 | 陷阱核对 | 见下表 |

**陷阱核对**：

| 陷阱 | 是否遵守 | 说明 |
|------|---------|------|
| #1 WPF Dispatcher 异常处理 | **遵守** | Runspace 内无 Dispatcher；结果收集在 UI 线程，try/catch/finally 包裹；Stop-LaunchAsync 有兜底释放 |
| #2 不 fork 上游 | **遵守** | P1-2 评估结论转 v2 的核心理由即此 |
| #4 UI 信息位置正确 | **遵守** | P1-1 只改颜色，按钮位置不变 |
| #5 跨框架 API 替换需 UI 测试 | **已声明盲区** | Runspace 是跨线程，理论正确，实际效果需 PM 真机 |
| #28 临死前 fire-and-forget | **遵守** | 未碰任何 Send-Telemetry / launcher_closed 代码（git diff 已验证）|

---

## 六、诚实盲区声明

1. **P1-1 按钮颜色真机效果**：`#D9772B` 暖橙在实际屏幕（不同色温、亮度、分辨率）下是否与 State 1/6 视觉一致，需 PM 对比看一遍。
2. **P1-3 "未响应"是否真正消失**：Runspace 异步化解决了最大阻塞点（Expand-Archive），但 `Start-HermesGateway` 中的 `Install-GatewayPlatformDeps` 仍有同步 Python 调用（如果用户配了渠道依赖）。是否还有其他阻塞点只有真机跑到那个分支才能确认。
3. **WPF XAML Load 验证**：本次改动无新 XAML，但无法验证 P1-1 颜色在 WPF 渲染树中是否被正确应用（`BorderBrush` 在 `ControlTemplate` 里可能被样式覆盖）。

---

## 七、对 PM 的测试提示

**预计 5 分钟内完成**：

1. 打开启动器（双击 `Start-HermesGuiLauncher.cmd`）
2. 进入安装模式（未安装状态），确认环境检测（State 1），通过后进入位置确认（State 6）
3. 确认安装位置后，检查 **State 7 "安装前确认"** 的"开始安装"按钮：应是**暖橙色**（#D9772B），不是绿色。对比 State 1 "环境没问题，继续"按钮颜色应视觉一致
4. （如为全新安装环境）点击"开始使用"后观察 **State 12**（启动 WebUI 中）：标题栏是否**不再显示"未响应"**；特别是 Node.js 解压阶段（约 3-5 秒）窗口是否可拖动

---

## 八、未做的事（主动声明）

以下事项在任务期间发现但按 scope 锁定不修：

1. **`Restart-HermesGateway` 中的 `Start-Sleep -Milliseconds 3000`**：此函数被 `.env` 文件 watcher 的 DispatcherTimer 调用，3 秒同步 sleep 会阻塞 UI 线程。属于用户在 webui 配置渠道后触发，不在 State 12 主路径上。未修，已知 issue。
2. **`Install-GatewayPlatformDeps` 在 `start-gateway` phase 同步执行 Python**：对配置了渠道依赖的用户有轻微 UI 阻塞风险。核心路径正确，未修。
3. **版本号未更新**：按任务指示 P1 patch 不升版本号。
4. **zip 未重新打包**：按任务指示 P1 patch 后由整合者决定。

---

## 九、P1-2-LITE 占位反馈实施(2026-05-02 后续)

### 改动概要

| 文件 | 行数变化 | 改动概要 |
|------|---------|---------|
| `HermesGuiLauncher.ps1` | +25 行(新增) | 新增 `Stop-InstallSpinner` / `Start-InstallSpinner` 函数;`Stop-ExternalInstallTimer` 末尾加调用;`install-external` action 中 `Start-ExternalInstallMonitor` 后立即调用 `Refresh-Status` + `Start-InstallSpinner` |

**函数级改动**:
- `Stop-InstallSpinner`(新增,行 ~4578):停止并清空 `$script:InstallSpinnerTimer`
- `Start-InstallSpinner`(新增,行 ~4584):创建 DispatcherTimer,每 200ms 切换 braille 字符更新 `InstallCurrentStageDetail.Text`
- `Stop-ExternalInstallTimer`(行 ~4604):末尾加 `Stop-InstallSpinner` 调用,确保安装结束时 spinner 一定停止
- `Invoke-AppAction 'install-external'`(行 ~6431):安装终端启动后立即 `Refresh-Status` 切到 State 8,再 `Start-InstallSpinner`

### 设计决策

- **spinner 方案**: 文本切换(braille 方案 A)。理由:5 行核心逻辑,零新 XAML,State 8 的 `InstallCurrentStageDetail` TextBlock 已有渲染位置且在 controls 字典中,直接复用最简
- **占位屏挂载点**: 直接利用已有 State 8(`$installRunning` 分支)的完整 UI(行 6141-6171),无需新增 XAML。修复的核心是"切换时机"——之前安装终端启动后没有立即调用 `Refresh-Status`,导致 State 8 UI 延迟最长 2 秒才显示
- **状态切换时机**: `Start-ExternalInstallMonitor` 设置 `$script:ExternalInstallProcess` 后,立即 `Refresh-Status` — `Refresh-Status` 检查 `$installRunning`(= `$script:ExternalInstallProcess` 进程存活),此时为 true,所以直接渲染 State 8

### 修改前后(关键 diff)

```powershell
# === Stop-InstallSpinner / Start-InstallSpinner(新增于 Stop-ExternalInstallTimer 之前) ===
function Stop-InstallSpinner {
    if ($script:InstallSpinnerTimer) {
        try { $script:InstallSpinnerTimer.Stop() } catch { }
        $script:InstallSpinnerTimer = $null
    }
}
function Start-InstallSpinner {
    Stop-InstallSpinner
    $script:InstallSpinnerFrames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $script:InstallSpinnerIdx = 0
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(200)
    $t.Add_Tick({
        try {
            $f = $script:InstallSpinnerFrames[$script:InstallSpinnerIdx % $script:InstallSpinnerFrames.Length]
            $script:InstallSpinnerIdx++
            if ($controls.InstallCurrentStageDetail) { $controls.InstallCurrentStageDetail.Text = "$f 正在安装,看黑色终端窗口进度" }
        } catch { }
    })
    $script:InstallSpinnerTimer = $t
    $t.Start()
}

# === Stop-ExternalInstallTimer — 末尾新增 Stop-InstallSpinner ===
function Stop-ExternalInstallTimer {
    if ($script:ExternalInstallTimer) {
        $script:ExternalInstallTimer.Stop()
        $script:ExternalInstallTimer = $null
    }
    Stop-InstallSpinner   # 新增:安装结束时停止 spinner
}

# === install-external action — 安装终端启动后立即切屏 + 启动 spinner ===
$proc = Start-Process powershell.exe -PassThru -WorkingDirectory $env:TEMP -ArgumentList @(...)
Start-ExternalInstallMonitor -Process $proc
try { Refresh-Status } catch { }   # P1-2-LITE: 立即切到 State 8 占位屏(新增)
Start-InstallSpinner               # P1-2-LITE: 启动 braille spinner(新增)
Add-ActionLog ...
```

### 行数核查

- PowerShell 函数体: 22 行(Stop-InstallSpinner 6 行 + Start-InstallSpinner 16 行)
- Stop-ExternalInstallTimer 调用: 1 行
- install-external action 调用: 2 行
- **总计: 25 行**(≤ 30 行约束 ✓)

### 触发流程

1. 用户点"开始安装" → `Invoke-AppAction 'install-external'` 通过 Confirm-TerminalAction 确认
2. PowerShell 启动 install 终端 → `$proc = Start-Process powershell.exe ...`
3. `Start-ExternalInstallMonitor -Process $proc` → `$script:ExternalInstallProcess` 设置为进程对象
4. `try { Refresh-Status } catch { }` → `Refresh-Status` 检测到 `$installRunning = true` → 渲染 State 8 UI(标题"正在安装 Hermes Agent"、进度条 65%、提示卡)
5. `Start-InstallSpinner` → DispatcherTimer 启动,每 200ms 更新 `InstallCurrentStageDetail.Text` 为 `"⠋/⠙/... 正在安装,看黑色终端窗口进度"`
6. install 跑完 → `Start-ExternalInstallMonitor` 的 2 秒 Tick 检测进程退出 → `Stop-ExternalInstallTimer` 调用 `Stop-InstallSpinner` → spinner 停止
7. `Refresh-Status` 被调用 → `$installRunning = false` → 切到 State 11(已完成)或 State 9(失败)

### 自检

| 项 | 结果 |
|----|------|
| AST 解析 | 0 错误(`[Parser]::ParseFile` 输出 `Error count: 0`) |
| SelfTest | 通过(`"SelfTest":true`) |
| 行数 ≤ 30 | ✓ (25 行) |
| Dispatcher try-catch | ✓ (Tick handler 整体 try-catch 包裹;Stop-InstallSpinner 的 Stop() 调用 try-catch 包裹) |

### 真机盲区

1. **spinner 转动是否流畅**:braille 字符在不同字体下渲染效果未知;200ms 间隔在 DispatcherTimer 下是否真正均匀未知(测不了)
2. **Refresh-Status 触发时机是否合理**:`Start-ExternalInstallMonitor` 设置 `$script:ExternalInstallProcess` 后立即 `Refresh-Status` — 理论上进程已启动但可能还未真正运行;`HasExited` 是否立即为 false 需要真机确认
3. **占位屏视觉**:State 8 的完整 UI(进度条 65%、步骤指示器 3 of 3 active、提示卡)在实际窗口中是否符合预期(测不了渲染)
4. **spinner 停止时机**:`Stop-ExternalInstallTimer` 在进程退出后 2 秒 Tick 才触发 — 安装完成后 spinner 最多还转 2 秒才停。这是可接受的,但 PM 如果觉得 2 秒残留 spinner 体验不好,可缩短 `Start-ExternalInstallMonitor` Tick 间隔

---

## 十、P1-2-LITE-fix:strict mode 下变量未初始化(P0 真机阻断)

### 用户反馈

```
启动安装脚本失败:检索不到变量"$script:InstallSpinnerTimer",因为未设置该变量。
```

### 根因

`Set-StrictMode -Version Latest`(line 5)下,读任何未赋值的 `$script:` 变量都会立即抛出。P1-2-LITE 新增了 `$script:InstallSpinnerTimer` / `$script:InstallSpinnerFrames` / `$script:InstallSpinnerIdx` 三个变量,但没有在脚本顶部初始化。用户点击"开始安装"→ `Stop-InstallSpinner` 第一次被调用 → 读 `$script:InstallSpinnerTimer` → 抛。

### 修复

**文件**: `HermesGuiLauncher.ps1`
**位置**: line 27-30(紧跟 `$script:LauncherVersion` 之后,line 25)
**新增 4 行**(含注释):

```powershell
# P1-2-LITE fix: strict mode 下必须预初始化，否则 Stop-InstallSpinner 读未设置变量会抛
$script:InstallSpinnerTimer  = $null
$script:InstallSpinnerFrames = @()
$script:InstallSpinnerIdx    = 0
```

**安全性分析**:
- `Stop-InstallSpinner` 用 `if ($script:InstallSpinnerTimer)` 判定，`$null` 在 PowerShell 是 falsy，不进 if 块，不会对 `$null` 调 `.Stop()`。安全。
- `Start-InstallSpinner` 起手就覆盖三个变量，空数组初始值立刻被替换，无副作用。
- spinner Tick handler 用 `[]` 索引，空数组越界返回 `$null`，strict mode 不抛。但 Tick 路径不会触发，因为 Start 已覆盖 Frames。

### 验证 1:AST

```
powershell -ExecutionPolicy Bypass -File _p0_verify.ps1
AST errors: 0
```

### 验证 2:strict mode spinner 调用

```
powershell -ExecutionPolicy Bypass -File _spinner_test.ps1

Variable read test: OK Timer=[] Frames.Count=0 Idx=0
Stop on null: OK
Start: OK Timer type=DispatcherTimer
Stop on real timer: OK Timer now=
ALL PASS
```

说明:
- `Timer=[]` — `$null` 在字符串内插时输出空字符串,符合预期
- `Timer now=` — Stop 后 Timer 已置 `$null`,字符串插值为空,符合预期
- 四个阶段全部通过,包含 WPF DispatcherTimer 实际创建和停止

### 验证 3:SelfTest

```json
{"SelfTest":true,"LauncherVersion":"Windows v2026.05.02.1","DefaultsLoaded":true,...,"StatusChecked":true,"Status":{"Installed":true,...}}
```

SelfTest 通过,`"SelfTest":true`。

### 教训沉淀

- **陷阱 #14 复发**:SelfTest 只走 `-SelfTest` 代码路径,不触发 `install-external` action,所以不会经过 `Stop-InstallSpinner`。新增 `$script:` 变量后只跑 SelfTest 是不够的,必须验证实际 action 路径。
- **新陷阱建议 #34**:strict mode + 新增 `$script:` 变量必须在脚本顶部预初始化。任何新的 `$script:` 变量,必须在 line 25 附近的"顶部变量区"追加初始化,不能只在使用该变量的函数里初始化。
