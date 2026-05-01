# 任务 010 质检报告

## 评分
| 维度 | 满分 | 得分 | 说明 |
|------|------|------|------|
| 可用性 | 40 | 37 | 删除彻底无残留；核心状态机改写正确；新增代码质量高；2 个扣分项见下 |
| UX | 30 | 25 | 首页按钮简化合理；错误信息中文友好且有降级方案；2 个 UX 问题见下 |
| 产品姿态 | 20 | 20 | 严格遵守"不重构"、"不顺手优化"、"面向小白"原则 |
| 长期质量 | 10 | 9 | 代码结构清晰；1 个潜在维护风险 |
| **总分** | **100** | **91** | |

## 结论
**通过**

总分 91，超过 90 分门槛。存在 0 个 Critical 问题，2 个 Medium 问题建议后续处理。

---

## 问题清单

### Critical（必须修复）
无。

### High（强烈建议修复）
无。

### Medium（建议修复）

**M1. 首页出现两个内容相同的"开始使用"按钮**

XAML 第 1691-1692 行，`PrimaryActionButton` 和 `StageModelButton` 的 Content 都是"开始使用"，且都绑定到 `Invoke-AppAction 'launch'`。用户在首页会看到：

```
[开始使用(绿色)]  [开始使用(深色)]  [更多设置]
```

两个"开始使用"按钮功能完全相同，会让用户困惑"这两个有什么区别"。建议：
- 方案 A：隐藏 `StageModelButton`（设为 Collapsed），只保留绿色主按钮
- 方案 B：把 `StageModelButton` 改为"快速检测"或其他有区分度的功能

这不阻塞交付，但会影响用户第一印象。PM 可决定是否本次修复。

**M2. Install-HermesWebUi 下载期间 UI 线程阻塞**

`Install-HermesWebUi` 中的 `Invoke-WebRequest`（第 174 行）是同步调用，TimeoutSec=120。对于预打包 zip（预计 50-80MB），在网络较慢时下载可能耗时 30-60 秒，期间 WPF 窗口会卡死无响应（"未响应"状态）。

同样，`Start-HermesWebUiRuntime` 中的端口等待循环（第 278-289 行）会阻塞 UI 线程最多 15 秒。

这不是 bug，但体验不佳。建议记入 TODO.md，后续用 RunspacePool 或 Background Job 做异步下载。

### Low（可选修复）

**L1. `$script:WebUiProcessRef` 未被 `Stop-HermesWebUiRuntime` 使用**

`Start-HermesWebUiRuntime` 将进程引用保存到 `$script:WebUiProcessRef`（第 3354 行），但 `Stop-HermesWebUiRuntime` 完全不读取这个变量，而是通过 PID 文件 + 进程名扫描来停止进程。这不是 bug（PID 文件方案更可靠），但 `$script:WebUiProcessRef` 变成了一个从未被读取的孤立变量。

**L2. `LocalChatVerified` 状态在 launch 成功时设为 true（第 3359 行）**

这是旧逻辑的延续。现在 launch 动作实际是启动 hermes-web-ui 而非本地对话，语义上 `LocalChatVerified` 不太准确。不影响功能，但命名有点误导。

---

## 亮点

1. **删除极其彻底**：Grep 搜索 `GatewayReadiness`、`GatewayRuntime`、`GatewayLock`、`ModelProviderCatalog`、`ModelConfigDialog`、`Show-ModelConfigDialog`、`nesquena`、`hermes-webui`（旧）、`8787`、`server.py`、`Set-EnvAssignmentValue`、`Set-YamlTopLevelBlock`、`MessagingConfigured`、`confirm-local-chat`、`gateway-setup`、`install-messaging`、`restart-webui`、`update-webui` 全部零命中。没有任何残留引用。

2. **净减 3223 行**（6782 → 3559），超出任务预估的 2600 行。删除比预估多约 600 行，说明工程师清理了更多孤立代码。

3. **`Stop-HermesWebUiRuntime` 的双重清理策略**：先读 PID 文件精确停止，再扫描进程名兜底。这种防御性设计很好地应对了进程残留风险。

4. **launch 失败的降级方案**：WebUI 启动失败时弹出对话框，提供"改用命令行对话"的选择，符合"面向小白"原则。

5. **SelfTest 正确更新**：输出 JSON 包含新的 WebUi 字段，旧字段已清理。

6. **已知陷阱规避到位**：
   - 陷阱 #1（Dispatcher 异常）：唯一的 `Dispatcher.BeginInvoke`（第 794 行）在 try-catch 内
   - 陷阱 #3（中文错误匹配）：新代码无错误文本匹配
   - 陷阱 #4（UI 信息位置）：错误/进度信息通过 `Add-ActionLog` 写入日志区和 Footer，在用户视线内

---

## 详细评审

### 1. 删除完整性（10/10）

逐项 Grep 验证：

| 关键词 | 命中数 | 状态 |
|--------|--------|------|
| `GatewayReadiness` | 0 | 已清理 |
| `GatewayRuntime` | 0 | 已清理 |
| `GatewayLock` | 0 | 已清理 |
| `ModelProviderCatalog` | 0 | 已清理 |
| `ModelConfigDialog` | 0 | 已清理 |
| `Show-ModelConfigDialog` | 0 | 已清理 |
| `nesquena` | 0 | 已清理 |
| `8787` | 0 | 已清理 |
| `server.py` | 0 | 已清理 |
| `GatewayStatus` | 0 | 已清理 |
| `GatewayTerminalPid` | 0 | 已清理 |
| `GatewayMonitorTimer` | 0 | 已清理 |
| `ExternalModelProcess` | 0 | 已清理 |
| `ExternalGatewaySetup` | 0 | 已清理 |
| `ExternalMessaging` | 0 | 已清理 |
| `PendingGateway` | 0 | 已清理 |

无残留引用，无孤立变量（除 L1 提到的 `WebUiProcessRef`，这是新增的）。

### 2. 核心功能完整性（13/15）

- **`Get-UiState`**（第 2887 行）：结构正确，返回 `InstallDir`、`HermesHome`、`Branch`、`Status`、`HermesCommand`、`ModelStatus`、`OpenClawSources`、`LauncherState`、`WebUiStatus`。无 Gateway 字段残留。所有 5 处调用点已验证。
- **`Refresh-Status`**（第 3019 行）：逻辑简化为 Install 模式 / Home 模式两分支，Home 模式直接显示"已就绪"和"开始使用"按钮。无 Gateway 条件分支。
- **`Test-HermesModelConfigured`**（第 358 行）：完整保留，未被误删。
- **SelfTest**（第 1539 行）：输出包含 `WebUi.Version/Installed/Healthy/Url`，结构正确。
- **安装流程**：Grep 确认 `Start-ExternalInstallMonitor`、`New-ExternalInstallWrapperScript` 等安装相关函数未被触及。

扣 2 分原因：M2（UI 线程阻塞问题影响安装/启动的可用体验）。

### 3. 新增代码质量（14/15）

- **`Get-HermesWebUiDefaults`**（第 123 行）：路径配置清晰，使用 `$env:LOCALAPPDATA` 和 `$env:USERPROFILE`，符合现有代码风格。
- **`Install-HermesWebUi`**（第 152 行）：有完整的 try-catch-finally，zip 清理在 finally 中，staging 目录处理了 zip 内单层嵌套的情况，安装后校验 node.exe 和 server.js 是否存在。错误信息中文。
- **`Start-HermesWebUiRuntime`**（第 248 行）：日志输出到带时间戳的文件，PID 写入文件便于清理，端口等待有 15 秒超时。
- **`Stop-HermesWebUiRuntime`**（第 305 行）：PID 文件 + 进程名扫描双重策略，防御性编程到位。

扣 1 分原因：`Install-HermesWebUi` 的错误处理中 catch 块 return 了 `Installed=$false` 的对象而非 throw，这意味着调用方必须检查返回值。`Invoke-AppAction 'launch'` 的第 3345-3346 行确实做了检查并 throw，所以实际不会出问题，但这种"错误用返回值而非异常"的模式与函数内部的 throw 风格不一致。

### 4. 用户体验（25/30）

- **首页简化**：从 4 按钮变为 3 按钮（PrimaryActionButton + StageModelButton + StageAdvancedButton），但两个"开始使用"按钮重复（M1），实际效果不如任务文档期望的"2 个主按钮"清晰。扣 3 分。
- **按钮文案**："开始使用" + "更多设置"，符合任务要求。
- **错误信息**：全中文，对小白友好。launch 失败时提供命令行降级，并用 MessageBox 确认。
- **进度提示**：有 `Add-ActionLog` 和 `Set-Footer` 在各步骤提供进度反馈。
- **模型未配置引导**：不再打开弹窗，改为在 WebUI 中配置。`Get-Recommendation` 始终返回"已就绪"（只要 hermes 已安装），不区分模型是否配置。这是正确的——因为模型配置现在在 WebUI 中完成。扣 2 分因为 M2（下载时 UI 卡死影响体验）。

### 5. 产品姿态（20/20）

- **不重构**：所有改动在现有文件基础上，未拆分文件。
- **不顺手优化**：没有做视觉风格迁移、没有改 XAML 布局、没有优化其他区域的代码。
- **面向小白**：所有新增文案都是中文，技术概念（node.exe、server.js、端口）不暴露给用户。
- **不 fork 上游**：未涉及上游代码。

### 6. 长期质量（9/10）

- 代码结构清晰，新增函数遵循现有命名规范（`Get-`/`Test-`/`Install-`/`Start-`/`Stop-` 前缀）。
- 下载 URL 硬编码为 `v0.1.0`，后续版本升级需要改这一行。这是已知的 placeholder 设计，可接受。
- 扣 1 分：`$script:WebUiProcessRef` 是无用变量（L1），增加维护成本。

### 陷阱清单核对

| 陷阱 | 是否规避 | 说明 |
|------|---------|------|
| #1 WPF Dispatcher 异常 | 是 | 唯一的 BeginInvoke 在 try-catch 内（第 794-799 行） |
| #2 ComboBox 事件绑定时机 | N/A | 本次无 ComboBox 相关改动 |
| #3 中文 Windows 错误匹配 | 是 | 新代码无错误文本匹配 |
| #4 UI 信息位置 | 是 | 错误/进度写入 ActionLog 和 Footer |
| #5 跨框架 API 替换 | 是 | 新 WebUI 是全新代码，不是替换旧 API |
| #6 分支管理 | 是 | 工程师声明在 `codex/next-flow-upgrade` 分支 |
| #7 内部文档暴露 | N/A | 本次无部署操作 |
| #10 自检 vs 用户可见 | 是 | 工程师诚实声明了 UI 渲染盲区 |
