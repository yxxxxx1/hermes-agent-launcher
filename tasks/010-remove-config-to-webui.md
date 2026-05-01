# 任务 010：启动器瘦身 — 统一迁移至 hermes-web-ui

## 背景

当前 Windows 启动器（HermesGuiLauncher.ps1）内嵌了：
- 模型配置对话框（~1740 行）
- 消息渠道配置面板（~652 行）
- 旧版对话 WebUI 管理（nesquena/hermes-webui，Python，~500 行）

新的 hermes-web-ui（https://github.com/EKKOLearnAI/hermes-web-ui）已具备对话 + 模型配置 + 渠道配置的完整功能。

## PM 决策

**用户只需要一个界面。** 新的 hermes-web-ui 统一承载对话、模型配置、渠道配置。启动器瘦身为"轻量安装器 + 进程管理器"。

核心原则：**让用户减少选择，减少误解。快速装好，能用，好用。**

## 已确认的设计

### 安装方式
- 启动器检测本地是否已有 hermes-web-ui
- 没有 → 自动下载预打包的 zip（GitHub Releases，含 portable Node.js + node_modules）
- 解压到 `%LOCALAPPDATA%\hermes\hermes-web-ui\`
- 用户全程只看到进度条："正在准备…"
- 不暴露 Node.js / npm 概念

### 过渡策略
- 直接切，不保留旧功能
- 旧版对话 WebUI（nesquena/hermes-webui）一并移除

### 启动行为
- 用户点按钮 → 后台启动 hermes-web-ui → 等端口就绪 → 打开浏览器
- 启动器关闭时自动停止进程
- 已在运行则直接打开浏览器

### 首页简化
启动器首页从 4 个按钮简化为 2 个：
- **开始使用**（安装/启动 hermes-web-ui + 打开浏览器）
- **更多设置**（更新、日志、命令行对话等）

## 删除范围

### 1. 模型配置相关（~1740 行）
- Provider 目录定义（`Get-ModelProviderCatalog` 等）
- 模型配置 IO 函数（`Get-HermesModelSnapshot`、`Save-HermesModelDialogConfig` 等）
- 模型配置对话框 UI + 逻辑（`Show-ModelConfigDialog`）
- 连通性校验（`Test-ModelProviderConnectivity`）
- 辅助函数（`Set-YamlTopLevelBlock`、`Set-EnvAssignmentValue` — 仅被删除的函数调用）

### 2. 消息渠道配置相关（~652 行）
- Gateway 检测逻辑（`Test-HermesGatewayReadiness`）
- 渠道运行时管理（`Get-GatewayRuntimeStatus`、锁管理、清理函数等）
- 渠道面板 UI（`Show-GatewayPanel`）
- 消息依赖安装（`Start-MessagingDependencyInstall`）
- Gateway 启动/监视（`New-HiddenGatewayWrapper`、`Start-GatewayRuntimeLaunch` 等）

### 3. 旧版对话 WebUI 相关（~500 行）
- WebUI 默认配置（`Get-HermesWebUiDefaults`）
- WebUI 安装/检测（`Test-HermesWebUiInstalled`、`Install-HermesWebUi`）
- Python 依赖管理（`Test-HermesWebUiPythonReady`、`Ensure-HermesWebUiPythonDependency`）
- 运行时管理（`Start-HermesWebUiRuntime`、`Stop-HermesWebUiRuntime`）
- 健康检查/状态（`Test-HermesWebUiHealth`、`Get-HermesWebUiStatus`）
- 状态持久化（`Load-HermesWebUiRuntimeState`、`Save-HermesWebUiRuntimeState`）
- 端口/设置（`Resolve-HermesWebUiPort`、`Set-HermesWebUiDefaults`）
- 一键就绪（`Ensure-HermesWebUiReady`）

### 4. 相关 Invoke-AppAction 分支
- `'model'`、`'gateway-setup'`、`'gateway'`、`'install-messaging'`、`'confirm-local-chat'`
- `'launch-webui'` 分支需要重写（改为启动新 hermes-web-ui）

### 5. 相关 XAML 和事件绑定
- `StageGatewayButton` — 删除
- `StageModelButton` — 改为"开始使用"
- 旧 WebUI 相关 XAML 元素

### 6. 孤立变量清理
- Gateway 相关：`$script:GatewayRuntimeState`、`GatewayRuntimeMessage`、`GatewayTerminalPid`、`GatewayMonitorTimer` 等
- 旧 WebUI 相关：相关 script 变量
- Model 外部监视：`$script:ExternalModelProcess`、`ExternalModelTimer` 等

## 需要修改的代码

1. **`Get-UiState`**：移除 `GatewayStatus`、`GatewayRuntime` 字段；移除旧 WebUI 状态
2. **`Refresh-Status`**：简化，移除所有 Gateway 和旧 WebUI 相关条件
3. **`Get-Recommendation`**：移除 Gateway 相关推荐路径
4. **`Invoke-AppAction`**：重写 `'launch'`/`'launch-webui'` 分支 → 统一启动新 hermes-web-ui
5. **`Get-UseModeActions`**：移除 gateway 相关 action
6. **窗口关闭处理**：finally 块添加新 hermes-web-ui 进程清理

## 新增代码（预估 ~300 行）

### hermes-web-ui 管理函数
- `Get-HermesWebUiDefaults` — 路径/端口/版本配置（复用函数名，内容全换）
- `Test-HermesWebUiInstalled` — 检测安装状态
- `Install-HermesWebUi` — 下载预打包 zip 并解压（含 portable Node.js）
- `Start-HermesWebUiRuntime` — 后台启动 node server
- `Stop-HermesWebUiRuntime` — 停止进程
- `Test-HermesWebUiHealth` — 端口健康检查

### 新增 Invoke-AppAction 分支
- `'launch'` → 检测安装 → 启动 → 打开浏览器（一个按钮搞定）

## 运行时路径

- 安装目录：`%LOCALAPPDATA%\hermes\hermes-web-ui\`
- 日志：`%USERPROFILE%\.hermes\logs\webui\`
- 端口：`127.0.0.1:3210`（仅本机可访问）

## 预打包 zip 方案

- 在 EKKOLearnAI/hermes-web-ui 仓库 GitHub Releases 发布
- zip 包含：portable node.exe + node_modules + 构建产物
- 本次启动器代码先用 placeholder URL，zip 就绪后改 URL

## 验收标准

1. **启动器打开**：不再出现模型配置对话框、消息渠道面板、旧 WebUI 相关 UI
2. **首页只有 2 个主按钮**："开始使用" + "更多设置"
3. **点"开始使用"（首次）**：进度条 → 下载安装 → 启动 → 浏览器打开
4. **点"开始使用"（非首次）**：启动 → 浏览器打开
5. **已运行时点击**：直接打开浏览器，不重复启动
6. **关闭启动器**：hermes-web-ui 进程被正确终止
7. **无网络时**：已安装则正常使用；未安装则提示需要网络
8. **SelfTest 通过**：不崩溃
9. **代码净减少**：删除 ~2900 行，新增 ~300 行，净减少 ~2600 行

## 风险点

1. **Node.js 依赖** → 预打包 portable Node.js 进 zip
2. **端口冲突** → 检测端口，被占用时尝试下一个
3. **进程残留** → 启动器启动时检测并清理遗留进程
4. **Refresh-Status 改错** → 核心状态机，逐步删除，每步跑 SelfTest
5. **Get-UiState 返回结构变化** → 所有引用点都需清理

## 不在本次范围

- hermes-web-ui 本身的功能开发（EKKOLearnAI/hermes-web-ui 仓库负责）
- 预打包 zip 的构建流程（webui 仓库配置）
- macOS 端的配置迁移（Mac 端有独立 Swift 实现）
- 启动器视觉风格迁移（另一个任务）

## 实施顺序

1. 删除模型配置代码（~1740 行）
2. 删除消息渠道代码（~652 行）
3. 删除旧版对话 WebUI 代码（~500 行）
4. 修改状态机代码（Get-UiState、Refresh-Status、Get-Recommendation）
5. 修改 XAML 和事件绑定（首页按钮简化）
6. 新增 hermes-web-ui 管理代码（~300 行）
7. 添加窗口关闭时进程清理
8. 每步完成后跑 SelfTest 验证
