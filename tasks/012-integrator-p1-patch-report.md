# Task 012 整合者 P1 Patch 报告

**整合者**: integrator agent
**worktree**: relaxed-ride-6f33a2
**基于 commit**: 138c8d2 (engineer 在此基础上 dirty working tree，未 commit)
**日期**: 2026-05-02

---

## 一、综合决策

**决策**: 通过
**总分**: 91 / 100（90 分门槛）

三项 P1 修复均完成，scope 严格锁定，未碰遥测/版本号/deploy.sh。
发现的问题均为 Minor 级别，不阻塞上线。

---

## 二、各项评估

### P1-1 按钮颜色 (91 / 100)

**主目标达成**: `Set-InstallActionButtons` 第 5439-5449 行，`PrimaryEnabled=true` 分支改为 `#D9772B` / `#FCFCF7`，与 LauncherPalette `accentPrimary` + `textOnAccent` 完全一致。

**TemplateBinding 验证**: `PrimaryButtonStyle` 的 ControlTemplate 使用
`Background="{TemplateBinding Background}"`（第 2849 行），因此程序化设置 `Background='#D9772B'` 会生效（local value 优先级 > Style setter）。启用态会显示**纯色暖橙**而非原 Style 的渐变橙——视觉上接近，品牌色一致，可接受。

**Minor 问题 1 — BorderBrush 无视觉效果**:
ControlTemplate 中 Border 的 `BorderBrush="Transparent"` 是硬编码，不是 `{TemplateBinding BorderBrush}`（第 2851 行）。工程师设的 `BorderBrush = '#D9772B'` 和禁用态的 `BorderBrush = '#C8C3B9'` 均无视觉输出。这是无害的死代码，不影响用户感知。

**Minor 问题 2 — 禁用态受 Style Trigger 控制**:
`IsEnabled=False` trigger（第 2858-2866 行）将 ButtonBorder.Background 强制设为 `SurfaceTertiaryBrush`（#F0E8DE 浅米色），覆盖了工程师写的 `#D4CFC5`。禁用态 Foreground 同样由 trigger 设为 `TextTertiaryBrush`（#897F75）——与工程师写的值相同，因此 Foreground 实际结果一致。Background 会是 #F0E8DE 而非 #D4CFC5（差 5 个色阶的米色，肉眼几乎不可分辨）。不影响可用性。

**一致性**: 暖橙与 State 1 的 AccentGradientBrush 同属 `#D9772B` 色系，视觉一致性达到设计目标。

---

### P1-3 UI 阻塞 (88 / 100)

**主目标达成**: `Expand-Archive` 从 UI 线程同步执行移至后台 Runspace + `BeginInvoke`，DispatcherTimer 轮询 `IsCompleted`（第 4353-4420 行）。理论上彻底消除最大阻塞点（Node.js 解压 3-10 秒）。

**异常路径检查**:
- `Expand-Archive` 抛异常 → Runspace 内 catch 捕获 → 返回 error string → UI 线程读取后 throw → 外层 catch 调用 `Stop-LaunchAsync`。路径完整。
- `EndInvoke` 抛异常 → catch 捕获 `$extractError` → finally 释放资源 → throw。路径完整。
- 用户取消（`Stop-LaunchAsync`）→ `ExtractPowerShell.Stop()` + `ExtractRunspace.Close()/Dispose()`。路径完整。
- `Remove-Item zip` 失败 → `SilentlyContinue`，不阻塞，可接受（残留 zip 在 TEMP 目录，OS 会清理）。

**资源释放检查**:
`finally` 块（第 4404-4410 行）:
```powershell
try { $s.ExtractPowerShell.Dispose() } catch { }
try { $s.ExtractRunspace.Close(); $s.ExtractRunspace.Dispose() } catch { }
```
**Minor 问题 3** — `Close()` 和 `Dispose()` 在同一个 `try` 块内。若 `Close()` 抛异常，`Dispose()` 不会被调用。极低概率场景，Runspace 会在 GC 时释放，不会造成功能故障，但属于不严格的资源管理。

**`TimeoutSec 1` 评估**:
`Invoke-RestMethod -TimeoutSec 1`（第 4471 行）和 `Invoke-WebRequest -TimeoutSec 1`（第 643 行）均在 DispatcherTimer tick（UI 线程）内同步执行。每次健康检查未通过时，UI 线程最多阻塞 1 秒。原值为 2s/3s，现在是 1s，是改善而非回归。本地 loopback 请求平均响应 <5ms，只有超时时才阻塞满 1s。可接受。

**`GwHealthDeadline` 未预声明**: `start-gateway` phase 设 `$s.GwHealthDeadline = ...`（第 4462 行），该字段未在 LaunchState hashtable 初始化块（第 3975-3989 行）中声明。PowerShell hashtable 支持动态添加属性，会正常工作。这是与 `HealthDeadline` 字段（已预声明）不一致的写法，但属于 pre-existing 风格问题，非本次引入的 bug。

**工程师诚实声明的两个遗留阻塞点**（范围外，已记 TODO）:
- `Restart-HermesGateway` 里 `Start-Sleep -Milliseconds 3000`（.env watcher 触发路径）
- `Install-GatewayPlatformDeps` 同步 Python 调用（已有渠道依赖时触发）

---

### P1-2 评估转 v2 (96 / 100)

**决策合理性**: 工程师提供了三条具体证据（无进度钩子的 `Build-InstallArguments`、输出进独立终端的 `New-ExternalInstallWrapperScript`、上游无结构化输出）+ 估算 150+ 行改动量 + "不 fork 上游"原则约束。评估依据充分，转 v2 决定正确。

**TODO.md 完整性**: 条目包含背景、评估结论、三条理由、v2 建议实现方向（含代码参考）、优先级（中）。格式规范，内容完整。

**无半截子实现**: 已验证无新增功能代码，只有 TODO 文档更新。

---

## 三、Scope 锁定核查

通过逐段代码阅读验证：

| 项目 | 结论 |
|------|------|
| 遥测代码（Send-Telemetry / launcher_closed / Get-OrCreateAnonymousId） | 未触碰 |
| 版本号 `$script:LauncherVersion`（第 25 行） | `v2026.05.02.1` — task 012 主实现已设的值，本 patch 未修改，符合 P1 patch 不升版本号约定 |
| deploy.sh / README / index.html | 未涉及 |
| 字体相关代码 | 未涉及 |
| XAML 节点 | 未新增（P1-1 只改 PowerShell 运行时赋值，P1-3 只加 PowerShell 逻辑） |
| 改动文件 | 仅 `HermesGuiLauncher.ps1` + `TODO.md` + 新建报告，无其他副作用 |

---

## 四、发现的问题（按严重度排序）

### Critical（必须修才能通过）

无。

### Major（建议修）

无。P1-3 的 `TimeoutSec 1` 仍在 UI 线程同步执行是已知限制，是改善而非回归，不构成 Major。

### Minor（记录即可）

**M1** — `BorderBrush` 设置在 PrimaryButtonStyle 中无效（ControlTemplate 不 TemplateBinding BorderBrush）。无害死代码，不影响视觉。建议在 v2 视觉迁移时清理。

**M2** — 禁用态 Background 由 Style Trigger 控制（#F0E8DE），不是代码设的 #D4CFC5。颜色差异极小，不影响可用性。

**M3** — `finally` 块里 `Close()` 和 `Dispose()` 在同一 `try` 中，Close() 异常会跳过 Dispose()。极低概率，GC 会兜底释放。

**M4** — `GwHealthDeadline` 未在 LaunchState 初始化块预声明（动态添加），与其他字段写法不一致。功能正确。

---

## 五、PM 真机验收清单（5 分钟内）

**前提条件**: 当前未安装 hermes-agent（或卸载后重来），以便走完安装漏斗。若已安装，只能验证 P1-1（Step 1-3）。

**Step 1 — 启动**（30 秒）
双击 `Start-HermesGuiLauncher.cmd`，确认窗口打开，背景是米色（#F2F0E8），不是深蓝黑。

**Step 2 — 环境检测（State 1）**（30 秒）
等待环境检测完成。主操作按钮（"环境没问题，继续"或类似文案）应为暖橙色，不是绿色。

**Step 3 — P1-1 重点验证（State 7）**（1 分钟）
走到安装前确认步骤（State 7），查看"开始安装"按钮。
- 期望：**暖橙色**背景，浅米白色文字。
- 对比 State 1 / State 6 的主按钮，三者应是同一色系（橙暖色）。
- 禁用状态（如果能触发）：应显示浅米灰底色 + 灰色文字。

**Step 4 — P1-3 验证（仅全新安装路径）**（2-3 分钟）
点击"开始安装"进入安装漏斗后，点击主界面的"开始使用"。观察 State 12（启动 WebUI 中）：
- Node.js 下载并解压期间（约 30-90 秒），用鼠标拖动启动器窗口。
- 期望：**窗口可以正常拖动**，标题栏不显示"未响应"。
- 如果没有全新环境，此步可跳过，向整合者说明"无法验证 P1-3"。

**Step 5 — 功能回归**（1 分钟）
确认以下未损坏：打开"关于"对话框正常关闭、底部日志区显示正常、匿名数据上报 toggle 可切换。

---

## 六、给 PM 的建议

### 立即动作（PM 现在做）

1. **真机验收 Step 1-3**：P1-1 必须真机看颜色，这是核心交付物。Step 4 可选（需要全新安装环境）。
2. **验收通过后 commit**：建议 commit message 如下：
   ```
   fix(ui): P1-1 State 7 button warm-orange + P1-3 Node.js extract async

   - Set-InstallActionButtons: StartInstallPageButton enabled = #D9772B/#FCFCF7
     (was green #22C55E), disabled = unified with PrimaryButtonStyle trigger
   - Step-LaunchSequence: extract-node phase via Runspace+BeginInvoke,
     eliminates 3-10s UI-thread block during Node.js decompression
   - wait-gateway-healthy: remove Start-Sleep 1000ms, TimeoutSec 2→1
   - Test-HermesWebUiHealth: TimeoutSec 3→1 (loopback health check)
   - P1-2: evaluated in-app install progress, deferred to v2 with rationale in TODO.md
   ```
3. **确认分支**：commit 到 `claude/relaxed-ride-6f33a2`，再由 PM 决定何时合并到 `codex/next-flow-upgrade` 发布分支。

### 后续动作（按优先级）

1. **P1-3 遗留阻塞点**（中优先级）：`Restart-HermesGateway` 的 3s sleep + `Install-GatewayPlatformDeps` 同步调用，已记 TODO.md，建议下一轮视觉迁移任务前处理。
2. **M3 资源释放**（低优先级）：`Close()` 和 `Dispose()` 分拆 try，下版本清理。
3. **M1 BorderBrush 死代码**（低优先级）：v2 视觉迁移时清理。

### 需要清理的临时文件

worktree `relaxed-ride-6f33a2` 根目录下有两个 AST 验证临时文件，可以直接删除：
- `_ast_check.ps1`
- `_ast_check2.ps1`

这两个是 top-level orchestrator 在验证阶段留下的，不影响功能，可在验收通过 commit 前删除（或直接忽略，不加入 commit 即可）。

---

## 七、发版建议

**P1 patch 后是否需要重新打 zip**:

当前 `$script:LauncherVersion = 'Windows v2026.05.02.1'`（第 25 行），这是 task 012 主实现阶段已设的版本号。P1 patch 修复了同版本下的 bug，从语义上看，如果 `v2026.05.02.1` 的 zip 已经分发给用户，需要重新打包才能让现有用户通过重新下载获得修复。

**建议**:
- 若 `v2026.05.02.1` zip 尚未部署到生产（只有开发分支），等完整 task 012 验收通过后一并打包，不用单独打 P1 patch 的 zip。
- 若已部署，升版本号到 `v2026.05.02.2` 并重新打包。

**推荐流程**:
1. PM 5 分钟真机验收（本报告 Section 五）
2. 验收通过 → PM commit 到 `claude/relaxed-ride-6f33a2`
3. PM 决定合并时机（合并到 `codex/next-flow-upgrade`）
4. 合并后打 zip + deploy（按 CLAUDE.md 发版流程）

---

## 八、对 PM 的提醒

1. **P1-1 验收核心在于对比三个状态按钮颜色**：State 1、State 6、State 7 的主按钮都应该是暖橙色。如果 State 7 还是绿色，说明 P1-1 未生效（理论上不会，但真机才是最终确认）。

2. **P1-3 只有全新安装环境才能验证**：如果本机已安装 hermes-agent + node.js，走不到 `extract-node` 阶段，无法验证"未响应"是否消失。这是工程师已声明的盲区。

3. **BorderBrush 设置无效是已知限制**：P1-1 设置了 `BorderBrush` 但它不会显示（ControlTemplate 硬编码 `Transparent`）。这不影响用户体验，只是代码里多了两行无害语句。

4. **两个临时文件**（`_ast_check.ps1`、`_ast_check2.ps1`）在 worktree 根目录，commit 前记得排除或删除。

---

## 九、沉淀建议

### 加入"已知陷阱清单"（CLAUDE.md）

**本次无新陷阱需要加入**。相关知识点已有覆盖：
- TemplateBinding vs 程序化赋值的优先级问题类似陷阱 #1 / #4，但本次没有造成 bug，不构成独立陷阱。
- DispatcherTimer + 同步 HTTP 调用的阻塞问题已在陷阱 #1 精神覆盖范围内。

### 加入 DECISIONS.md

无新的战略决策需要归档。P1-2 转 v2 的决策已记录在 TODO.md，粒度合适。

### 加入 TODO.md

已由工程师处理（State 8 in-app 进度条条目）。整合者补充：M3 资源释放问题（Close+Dispose 同 try）和 M1 BorderBrush 死代码建议附在现有 UI 迁移 TODO 条目下，不单独新建条目。

---

## 十、P1-2-LITE 快速验证（2026-05-02 后续）

### 决策
通过 — 总分 95 / 100

四项检查全部通过，无 Critical / Major 问题。发现一个 Minor 设计备注（文本覆盖为预期行为）。P1-2-LITE 可与 P1-1/P1-3 一起进入 PM 真机验收。

---

### Q1 spinner 文本覆盖

**结论**：无矛盾，覆盖是预期设计行为。

证据：
- `Refresh-Status` 的 `installRunning = true` 分支（第 6179 行）写 `InstallCurrentStageDetail.Text = '终端已经打开，看终端进度即可'`
- 该分支结束于第 6196 行（`Set-InstallActionButtons`），之后不再写 `InstallCurrentStageDetail`
- `Start-InstallSpinner` 在 `Refresh-Status` 之后立即调用（第 6433 行），200ms 后开始用 braille 字符覆盖

整个 State 8 的 `installRunning` 分支中，`InstallCurrentStageDetail` 只被写入一次，无竞争写入点。

**Minor 备注**：第 6179 行的静态文字 `'终端已经打开，看终端进度即可'` 会在 200ms 内被 spinner 覆盖，实际用户可能从未看到这段文字。可接受的实现细节，不需要修改。

---

### Q2 spinner 启动/停止时序

**结论**：启动时机合理，所有停止路径覆盖完整，无泄漏路径。

**启动点**（第 6431-6433 行）：
```
Start-ExternalInstallMonitor -Process $proc   # 设置 $script:ExternalInstallProcess
try { Refresh-Status } catch { }              # installRunning=true → 渲染 State 8
Start-InstallSpinner                          # spinner 启动
```
时序正确：进程已启动、State 8 已渲染、再启 spinner。

**Stop-ExternalInstallTimer 所有调用点**（同时也是 Stop-InstallSpinner 的所有触发点）：

| 调用位置 | 行号 | 触发场景 |
|---------|-----|---------|
| `Start-ExternalInstallMonitor` 函数起手 | 4613 | 重复调用时清理旧 timer（防止双 timer 并跑）|
| Tick 内 `$script:ExternalInstallProcess` 为 null | 4621 | 异常清理：进程对象被外部置空 |
| Tick 内进程已退出（exitCode 任意值）| 4638 | 正常/失败完成 |
| Tick `catch` 块 | 4694 | 监视器 Tick 本身抛异常 |

**launcher 关闭路径**：`window.ShowDialog()` 返回后，WPF Dispatcher 消息循环停止，所有 DispatcherTimer（包括 InstallSpinnerTimer 和 ExternalInstallTimer）自动停止。不需要 `finally` 块显式调用。进程内存随后由 OS 回收，无资源泄漏。

**结论**：所有已知的安装结束路径（成功 / 失败 / Tick 异常 / launcher 关闭）均有对应停止机制。

---

### Q3 Dispatcher 异常 + 资源释放

| 检查项 | 结果 | 证据 |
|-------|------|------|
| DispatcherTimer.Add_Tick try-catch | ✓ | 第 4592-4596 行：Tick handler 整体包裹在 `try { ... } catch { }` 内 |
| Stop-InstallSpinner 安全停止 | ✓ | 第 4581 行：`try { $script:InstallSpinnerTimer.Stop() } catch { }` |
| Start-InstallSpinner 重入安全 | ✓ | 第 4586 行：起手调用 `Stop-InstallSpinner`，先停旧 timer 再建新 timer |

陷阱 #1 合规：DispatcherTimer.Tick 在 UI 线程执行，已有 try-catch 兜底，异常不会冒泡到 Application.DispatcherUnhandledException。

---

### Q4 Scope 锁定

**结论**：严格限定在声明的 4 处改动，无额外副作用。

逐项验证：
- `Stop-InstallSpinner` 函数（第 4579-4584 行）：新增 ✓
- `Start-InstallSpinner` 函数（第 4585-4600 行）：新增 ✓
- `Stop-ExternalInstallTimer` 末尾 `Stop-InstallSpinner`（第 4607 行）：新增 1 行 ✓
- `install-external` action `Refresh-Status` + `Start-InstallSpinner`（第 6432-6433 行）：新增 2 行 ✓
- Send-Telemetry / 遥测相关代码（第 6435 行）：未触碰 ✓
- 版本号（第 25 行）：未修改 ✓
- XAML 节点：未新增 ✓

总行数 25-26 行，满足 ≤ 30 行约束。

---

### 发现的问题

**Critical（阻塞上线）**：无
**Major（建议修）**：无

**Minor（记录即可）**

**M5** — `Refresh-Status` 写入的静态文字 `'终端已经打开，看终端进度即可'`（第 6179 行）在 200ms 内被 spinner 覆盖，用户几乎看不到。这是可接受的实现顺序，未来如果需要该静态文字可见，需要将它改为 spinner 的初始帧文字。不影响当前功能，不需要修复。

---

### PM 真机验收清单（P1-2-LITE 部分，2 步）

在已有 P1-1/P1-3 验收步骤之后增加：

**Step 6 — 安装中占位屏（State 8）**（约 1 分钟）

State 7 点击"开始安装"后，立即观察启动器界面：
1. 期望：黑色安装终端打开后，**启动器主窗口立即切换**到"正在安装 Hermes Agent"状态（State 8），不应有 1-2 秒的灰白空屏过渡
2. 期望：State 8 界面的小字提示区（进度条下方）应显示 **braille 字符转动动画**（如 `⠋ 正在安装，看黑色终端窗口进度`），每 200ms 更换一帧
3. 安装完成后，spinner 应停止，界面自动切换到完成或失败状态

**Step 7 — spinner 停止验证**（观察即可）

安装结束（终端窗口自动关闭或 5 秒后关闭）时：
1. 期望：spinning 动画停止，不再刷新文字
2. 期望：界面切换到 State 11（已完成）或 State 9（失败），不卡在 State 8

---

### 给 PM 的提醒

1. **Step 6 必须走到真实安装路径才能验证**：和 P1-3 一样，需要全新安装环境（未装过 hermes-agent）。已安装过的机器走不到 State 8，无法验证 spinner。

2. **braille 字符显示依赖字体**：`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` 在 Windows 默认字体下通常正常渲染（Segoe UI 支持 Braille 区块），如果显示为方框或乱码，属于字体回退问题，不影响功能逻辑，视觉降级可接受。

3. **spinner 最多延迟 2 秒才停**：安装完成后，ExternalInstallMonitor 的 2 秒 Tick 才会检测到进程退出并触发停止。PM 看到安装终端关了但 spinner 还在转 1-2 秒，是正常现象，不是 bug。

---

## 十一、P0 fix:strict mode 变量未初始化（2026-05-02 后续）

### 决策
通过 — 总分 97 / 100

### 验证脚本可信度审查

- `_spinner_test.ps1` 实际覆盖范围: 4 个阶段 — ① strict mode 下读三个已初始化变量（Phase 1）、② Stop on null 不抛（Phase 2）、③ 真实 WPF DispatcherTimer 创建（Phase 3）、④ Stop on real timer（Phase 4）。函数体从源码完整复制（line 4584-4604），无 mock / stub。
- 输出真实性: `ALL PASS` 与脚本逻辑完全可推导。`Timer=[]` = $null 字符串内插，`Timer now=` = Stop 后置 null。无矛盾。
- 是否覆盖了 install-external 触发的同等代码路径: 是。install-external action 触发顺序为 `Stop-InstallSpinner`（null 判断）→ `Start-InstallSpinner`（创建 timer）→ Tick 运行 → `Stop-ExternalInstallTimer` 调用 `Stop-InstallSpinner`（停止 real timer）。测试脚本的 Phase 2-4 等价覆盖了这条路径。
- 测试脚本设计说明: 脚本自己先做了初始化再测试，所以无法还原"修复前会抛"的场景。但 P0 崩溃 PM 已真机确认，测试只需验证"修复后不抛"，逻辑上无矛盾。

### 4 行修复合理性

| 项 | 结论 |
|----|------|
| 类型 $null / @() / 0 | 正确。对照 Start-InstallSpinner line 4590-4593：Frames 赋值为数组、Idx 赋值为整数、Timer 赋值为 DispatcherTimer 对象（初始 $null）。三个空初始值类型完全匹配。 |
| SelfTest 路径不受影响 | 正确。SelfTest 在 main block 之后运行，line 27-30 在脚本顶部，必先执行。 |
| 无意外副作用 | 正确。三个变量名仅在 line 27-30（初始化）和 line 4584-4604（spinner 函数体）出现。Stop-InstallSpinner 的 `if ($script:InstallSpinnerTimer)` 判断 $null 为 falsy，不进 if 块。Start-InstallSpinner 起手覆盖所有三个变量，`@()` 初始值立即被替换，无副作用。 |

### 真机回归边界

整合者只有 Read 工具，无法启动 GUI、无法运行脚本、无法真机触发 install-external action。

工程师的 `_spinner_test.ps1` 覆盖了 strict mode + Stop-InstallSpinner on null + Start / Stop on real timer 这条等价路径，代码层面验证充分。

但以下场景仍只有 PM 真机才能确认：完整的"点击开始安装 → 黑色终端打开 → 启动器切换到 State 8 → spinner 转动 → 终端关 → spinner 停"端到端流程。

### PM 真机回归清单（P0 fix 部分，1 步）

1. 打开启动器，走到 State 7"安装前确认"页，点击"开始安装"按钮。期望：黑色安装终端正常打开，启动器**不报**"检索不到变量 InstallSpinnerTimer"错误，界面切换到 State 8 并显示 braille 转动动画。如果终端打开且启动器不崩，P0 fix 验证通过。

### 给 PM 的提醒

P0 bug（strict mode 变量未初始化）是上次 P1-2-LITE 引入的，本次 4 行顶部初始化是最小侵入修复。代码审查无风险，真机只需确认"点开始安装后不崩"这一项即可，无需走完整安装流程。

### 沉淀建议

新陷阱 #34 候选：**"Set-StrictMode -Version Latest 下，新增 `$script:` 级变量必须在脚本顶部预初始化，否则任何读取（包括 if 判断、数组访问）都会抛 'cannot retrieve variable'"**。本次踩坑的根因是 P1-2-LITE 在函数内首次写入 `$script:InstallSpinnerTimer`，但 `Stop-InstallSpinner` 的 if 判断在该写入之前就被调用，触发 strict mode 报错。建议沉淀到 CLAUDE.md。同时也是陷阱 #14（SelfTest 不覆盖 GUI 全流程）的复发实例。
