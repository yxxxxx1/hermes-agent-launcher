# 任务 010 工程师分析报告

## 一、删除范围精确定位

### 1.1 模型配置相关代码（约 1740 行）

| 区块 | 行号范围 | 函数/内容 | 说明 |
|------|---------|-----------|------|
| Provider 目录 | 531-909 | `Get-ModelProviderCatalog` | 29 个 provider 的静态定义，约 378 行 |
| 模型配置 IO | 1071-1104 | `Get-HermesModelSnapshot` | 读取 config.yaml 中的 model 块快照 |
| 模型配置 IO | 1106-1136 | `Test-ModelDialogInput` | 校验对话框输入 |
| 模型配置 IO | 1138-1175 | `Save-HermesModelDialogConfig` | 写入 config.yaml + .env |
| 模型配置 IO | 1177-1208 | `Save-HermesProviderConfigOnly` | 仅写入 provider 配置 |
| 模型配置 IO | 1210-1299 | `Test-ModelProviderConnectivity` | API 连通性校验 |
| Provider 模型目录 | 1437-1549 | `Get-HermesProviderModelCatalog` | 通过 Python 获取 provider 支持的模型列表 |
| 模型配置对话框 UI | 3420-4439 | `Show-ModelConfigDialog` | 完整的模型配置弹窗（约 1019 行），含 XAML + 逻辑 |

**合计约 1740 行**

### 1.2 消息渠道配置相关代码（约 652 行）

| 区块 | 行号范围 | 函数/内容 | 说明 |
|------|---------|-----------|------|
| Gateway 检测 | 2404-2565 | `Test-HermesGatewayReadiness` | 通过 Python 探测已配置渠道，约 161 行 |
| 锁目录 | 2567-2572 | `Get-GatewayLockDirectory` | 6 行小函数 |
| 清理过期文件 | 2574-2601 | `Clear-StaleGatewayRuntimeFiles` | 清理 gateway.pid/state |
| 清理过期锁 | 2603-2631 | `Clear-StaleGatewayScopeLocks` | 清理 scope lock 文件 |
| 运行时状态 | 2633-2700 | `Get-GatewayRuntimeStatus` | 读取 gateway 进程状态 |
| 依赖安装 | 2702-2725 | `Start-MessagingDependencyInstall` | 启动消息渠道依赖安装终端 |
| Gateway wrapper | 4634-4665 | `New-HiddenGatewayWrapper` | 生成后台 gateway 启动脚本 |
| 模型监视器 | 4667-4714 | `Start-ExternalModelMonitor` | 监视模型配置终端进程 |
| Gateway 启动 | 4716-4742 | `Start-GatewayRuntimeLaunch` | 后台启动 gateway |
| Gateway setup 监视 | 4744-4806 | `Start-ExternalGatewaySetupMonitor` | 监视 gateway setup 终端 |
| 消息依赖监视 | 4808-4872 | `Start-ExternalMessagingMonitor` | 监视消息依赖安装终端 |
| Timer 停止 | 4466-4471 | `Stop-ExternalModelTimer` | |
| Timer 停止 | 4473-4478 | `Stop-ExternalGatewaySetupTimer` | |
| Timer 停止 | 4480-4485 | `Stop-ExternalMessagingTimer` | |
| Gateway 面板 | 5105-5157 | `Show-GatewayPanel` | 消息渠道子面板弹窗 |
| 首页 UI 按钮 | 2974 | XAML `StageGatewayButton` | "消息渠道" 按钮 |
| 事件绑定 | 6746 | `StageGatewayButton.Add_Click` | 按钮点击 → `Show-GatewayPanel` |

**合计约 652 行**

### 1.3 与删除区块无关但会受影响的辅助函数（需保留）

| 函数 | 行号 | 说明 |
|------|------|------|
| `Test-HermesModelConfigured` | 455-529 | **必须保留**。Refresh-Status 和 Get-UiState 依赖它判断模型状态 |
| `Get-EnvAssignmentValue` | 912-925 | 保留，被其他地方使用 |
| `Set-EnvAssignmentValue` | 927-967 | 仅被 `Save-HermesModelDialogConfig`（删）和 `Normalize-FriendlyMessagingDefaults`（删）使用，**可删** |
| `Get-YamlTopLevelBlockText` | 969-993 | 保留，`Test-HermesModelConfigured` 和 `Ensure-HermesConfigScaffold` 等使用 |
| `Set-YamlTopLevelBlock` | 1023-1069 | 仅被 `Save-HermesModelDialogConfig` 和 `Save-HermesProviderConfigOnly` 使用，可删 |
| `Get-YamlBlockFieldValue` | 994-1021 | 保留，`Test-HermesModelConfigured` 使用 |
| `Normalize-FriendlyMessagingDefaults` | 2004-2040 | 被 gateway 流程使用，可删 |

---

## 二、耦合分析

### 2.1 "开始对话" 按钮是否依赖模型配置？

**是，但只依赖 `Test-HermesModelConfigured`，不依赖 `Show-ModelConfigDialog`。**

- `Invoke-AppAction 'launch'` → 转发到 `'launch-webui'`（行 6447）
- `'launch-webui'` 检查 `$state.ModelStatus.ReadyLikely`（行 6454）
- 如果未配置，调用 `Invoke-AppAction 'model'`（行 6456）打开模型配置弹窗

**删除模型配置弹窗后**：需要改写这个分支——当模型未配置时，不再打开弹窗，而是引导用户打开 WebUI 配置页面。

### 2.2 Refresh-Status 是否依赖渠道检测？

**是。** `Get-UiState`（行 5753）调用了：
- `Test-HermesGatewayReadiness` → 获取 `GatewayStatus`
- `Get-GatewayRuntimeStatus` → 获取 `GatewayRuntime`

**`Refresh-Status`**（行 6094-6251）大量使用这两个状态：
- 行 6218-6247：首页状态文字和推荐语根据 `ModelStatus` + `GatewayRuntime` + `GatewayStatus` 展示不同内容

**删除后影响**：
- `Get-UiState` 的 `GatewayStatus` 和 `GatewayRuntime` 字段移除
- `Refresh-Status` 中所有 Gateway 相关的条件分支简化
- 首页状态文字只保留：模型已配置/未配置 + Hermes 正常

### 2.3 安装流程是否依赖 Provider 列表？

**否。** 安装流程（`Start-ExternalInstallMonitor`、`New-ExternalInstallWrapperScript`、preflight 检测等）完全独立于模型配置。安装只关心 Git、Python、uv 是否存在。

### 2.4 删除后会变成孤立的变量/函数

| 项目 | 原因 |
|------|------|
| `$script:ExternalModelProcess` | 仅被 `Start-ExternalModelMonitor` 和 `Stop-ExternalModelTimer` 使用 |
| `$script:ExternalModelTimer` | 同上 |
| `$script:ExternalGatewaySetupProcess` | 仅被 Gateway setup 监视器使用 |
| `$script:ExternalGatewaySetupTimer` | 同上 |
| `$script:ExternalMessagingProcess` | 仅被消息依赖监视器使用 |
| `$script:ExternalMessagingTimer` | 同上 |
| `$script:GatewayRuntimeState` | 仅被 Gateway 运行时管理使用 |
| `$script:GatewayRuntimeMessage` | 同上 |
| `$script:GatewayTerminalPid` | 同上 |
| `$script:GatewayMonitorTimer` | 同上 |
| `$script:PendingGatewayStartAfterMessagingInstall` | 同上 |
| `Stop-ExternalModelTimer` | 函数变孤立 |
| `Stop-ExternalGatewaySetupTimer` | 函数变孤立 |
| `Stop-ExternalMessagingTimer` | 函数变孤立 |
| `New-HiddenGatewayWrapper` | 函数变孤立 |
| `Schedule-GatewayLaunchCheck` | 函数变孤立（行 6038-6079） |
| `Get-ModelProviderCatalog` | 函数变孤立 |
| `Get-HermesModelSnapshot` | 仅被 `Save-HermesModelDialogConfig`/`Save-HermesProviderConfigOnly` 使用，可删 |
| `Test-ModelDialogInput` | 函数变孤立 |
| `Save-HermesModelDialogConfig` | 函数变孤立 |
| `Save-HermesProviderConfigOnly` | 函数变孤立 |
| `Test-ModelProviderConnectivity` | 函数变孤立 |
| `Get-HermesProviderModelCatalog` | 函数变孤立 |
| `Set-YamlTopLevelBlock` | 需检查是否有其他调用方 |

### 2.5 需要保留的关键读取函数

| 函数 | 行号 | 保留原因 |
|------|------|---------|
| `Test-HermesModelConfigured` | 455-529 | Refresh-Status → Get-UiState → 判断"开始对话"按钮是否可用 |
| `Get-OpenClawSources` | 445-453 | 旧版迁移流程需要 |

---

## 三、新增 WebUI 管理代码的插入点

### 3.1 新函数插入位置

现有 WebUI（hermes-webui）相关代码集中在两个区域：
- **定义区**：行 133-387（`Get-HermesWebUiDefaults` 到 `Get-HermesWebUiStatus`）
- **运行时区**：行 3165-3387（`Save-HermesWebUiRuntimeState` 到 `Ensure-HermesWebUiReady`）

**建议**：新的 hermes-web-ui 配置界面管理代码不需要新增函数。详见第四节分析。

### 3.2 "打开配置页面" 按钮替换

XAML 中的 `StageModelButton`（行 2973）和 `StageGatewayButton`（行 2974）是两个需要处理的按钮：

```xml
<Button x:Name="StageModelButton" ... Content="模型配置"/>
<Button x:Name="StageGatewayButton" ... Content="消息渠道"/>
```

**方案**：
- `StageModelButton` → 改 Content 为 "打开配置页面"，点击改为打开 hermes-web-ui 配置页
- `StageGatewayButton` → 直接从 XAML 中删除

### 3.3 启动器关闭事件处理

**当前没有 window.Add_Closing 事件处理！** 文件末尾（行 6776）直接调用 `$window.ShowDialog()`，finally 块（行 6777-6781）只释放 Mutex。

现有的 `Stop-HermesWebUiRuntime`（行 3325-3337）已经有停止 WebUI 进程的能力，但**没有在窗口关闭时调用**。

这意味着：**当前 hermes-webui 对话界面在启动器关闭时不会被自动停止**。这是一个已有的遗漏。

如果要在启动器关闭时停止 hermes-web-ui 配置界面进程，需要在 finally 块或 Add_Closing 事件中加入清理逻辑。

---

## 四、已有 WebUI 相关代码分析（关键发现）

### 4.1 现有 hermes-webui 架构

启动器已经有一套完整的 WebUI 管理系统：

| 函数 | 用途 |
|------|------|
| `Get-HermesWebUiDefaults` | 路径/端口/版本等配置 |
| `Test-HermesWebUiInstalled` | 检测安装状态 |
| `Install-HermesWebUi` | 下载 GitHub archive zip → 解压安装 |
| `Test-HermesWebUiPythonReady` | 检测 Python 依赖 |
| `Ensure-HermesWebUiPythonDependency` | 安装 Python 依赖 |
| `Load-HermesWebUiRuntimeState` | 读取运行时状态 |
| `Save-HermesWebUiRuntimeState` | 保存运行时状态 |
| `Test-HermesWebUiHealth` | 健康检查 |
| `Get-HermesWebUiStatus` | 综合状态 |
| `Resolve-HermesWebUiPort` | 端口选择 |
| `Start-HermesWebUiRuntime` | 启动 WebUI 服务 |
| `Stop-HermesWebUiRuntime` | 停止 WebUI 进程 |
| `Set-HermesWebUiDefaults` | 推送默认设置 |
| `Ensure-HermesWebUiReady` | 一键确保 WebUI 就绪 |

**关键发现**：这套代码管理的是 `nesquena/hermes-webui`（Python server.py），运行在 8787-8799 端口。

### 4.2 任务文档说的 hermes-web-ui 是什么？

任务文档说的是 `EKKOLearnAI/hermes-web-ui`，用于模型/渠道**配置界面**。这是一个 **Node.js 项目**，运行端口 3210。

**两者对比**：

| | 现有 hermes-webui | 新的 hermes-web-ui |
|---|---|---|
| 仓库 | nesquena/hermes-webui | EKKOLearnAI/hermes-web-ui |
| 语言 | Python (server.py) | Node.js |
| 用途 | 对话界面 | 模型/渠道配置界面 |
| 端口 | 8787-8799 | 3210 |
| 入口 | server.py | npm start / node server.js |
| 运行时 | Hermes venv 内的 Python | 需要独立 Node.js |

**冲突风险**：
- 命名空间冲突：两个都叫 "WebUI"，代码中变量/函数名容易混淆
- 安装目录冲突：现有 WebUI 在 `%LOCALAPPDATA%\hermes\hermes-webui\`，新的计划放在 `%LOCALAPPDATA%\hermes\hermes-web-ui\`（注意中间有横线差异）
- 状态文件可能冲突：需要独立的 state 文件

### 4.3 命名建议

为避免与现有 hermes-webui（对话）混淆，新的配置界面建议在代码中使用 `ConfigUI` / `HermesConfigUi` 命名前缀，而非 `WebUi`。例如：
- `Get-HermesConfigUiDefaults`
- `Install-HermesConfigUi`
- `Start-HermesConfigUiRuntime`
- `Stop-HermesConfigUiRuntime`

---

## 五、Node.js 依赖问题分析

### 5.1 问题本质

hermes-web-ui 是 Node.js 项目，需要 Node.js 运行时。目标用户是不懂命令行的小白。

### 5.2 方案对比

| 方案 | 描述 | 优点 | 缺点 |
|------|------|------|------|
| A. 预打包 portable Node.js | zip 包含 node.exe + node_modules + 构建产物 | 用户零配置；完全隔离 | zip 体积大（约 50-80MB）；需要维护打包流程 |
| B. 要求用户安装 Node.js | 检测 node，缺失时引导安装 | zip 体积小 | 不符合"面向小白"原则；Node 安装本身就很复杂 |
| C. 启动器内自动下载 portable Node.js | 首次使用时从官方下载 node.exe | zip 不需要包含 Node；按需下载 | 增加首次使用的等待时间；需要处理下载失败 |

### 5.3 推荐方案

**方案 A：预打包 portable Node.js**

理由：
1. 用户群体是不懂命令行的小白，任何额外安装步骤都是流失点
2. 任务文档的 PM 决策（决策 1）已经选了"内嵌安装流"，用户全程只看到进度条
3. portable Node.js (win-x64) 的 node.exe 约 40MB，压缩后约 15MB
4. zip 中包含 `node_modules`（预装好的），用户不需要运行 npm install
5. 启动器本身已有 GitHub Releases 下载 + 解压的成熟代码（`Install-HermesWebUi` 就是这个模式）

**具体做法**：
- 在 `EKKOLearnAI/hermes-web-ui` 的 GitHub Releases 发布预打包 zip
- zip 结构：`hermes-web-ui-win/node.exe` + `hermes-web-ui-win/server.js` + `hermes-web-ui-win/node_modules/` + ...
- 启动器下载后解压到 `%LOCALAPPDATA%\hermes\hermes-web-ui\`
- 启动时用内置的 `node.exe` 运行 `server.js`

---

## 六、整体改动策略

### 6.1 删除清单（精确函数级）

**直接删除的函数**：
1. `Get-ModelProviderCatalog`（531-909）
2. `Get-HermesModelSnapshot`（1071-1104）
3. `Test-ModelDialogInput`（1106-1136）
4. `Save-HermesModelDialogConfig`（1138-1175）
5. `Save-HermesProviderConfigOnly`（1177-1208）
6. `Test-ModelProviderConnectivity`（1210-1299）
7. `Get-HermesProviderModelCatalog`（1437-1549）
8. `Show-ModelConfigDialog`（3420-4439）
9. `Test-HermesGatewayReadiness`（2404-2565）
10. `Get-GatewayLockDirectory`（2567-2572）
11. `Clear-StaleGatewayRuntimeFiles`（2574-2601）
12. `Clear-StaleGatewayScopeLocks`（2603-2631）
13. `Get-GatewayRuntimeStatus`（2633-2700）
14. `Start-MessagingDependencyInstall`（2702-2725）
15. `New-HiddenGatewayWrapper`（4634-4665）
16. `Start-ExternalModelMonitor`（4667-4714）
17. `Start-GatewayRuntimeLaunch`（4716-4742）
18. `Start-ExternalGatewaySetupMonitor`（4744-4806）
19. `Start-ExternalMessagingMonitor`（4808-4872）
20. `Stop-ExternalModelTimer`（4466-4471）
21. `Stop-ExternalGatewaySetupTimer`（4473-4478）
22. `Stop-ExternalMessagingTimer`（4480-4485）
23. `Show-GatewayPanel`（5105-5157）
24. `Normalize-FriendlyMessagingDefaults`（2004-2040）
25. `Schedule-GatewayLaunchCheck`（6038-6079）
26. `Set-YamlTopLevelBlock`（1023-1069）— 已确认仅被删除的函数调用
27. `Set-EnvAssignmentValue`（927-967）— 已确认仅被删除的函数调用

**直接删除的 Invoke-AppAction 分支**：
- `'model'`（6409-6428）
- `'gateway-setup'`（6559-6577）
- `'gateway'`（6591-6626）
- `'install-messaging'`（6578-6590）
- `'confirm-local-chat'`（6537-6558）

**删除的 XAML**：
- `StageGatewayButton`（行 2974）

**删除的变量初始化**：
- `$script:GatewayRuntimeState`、`$script:GatewayRuntimeMessage`、`$script:GatewayTerminalPid`、`$script:GatewayMonitorTimer`（行 3063-3066）
- `$script:PendingGatewayStartAfterMessagingInstall`

**删除的事件绑定**：
- `$controls.StageGatewayButton.Add_Click`（行 6746）
- `$controls` 列表中的 `'StageGatewayButton'`（行 3025）

### 6.2 需要修改的代码

1. **XAML `StageModelButton`**：Content 从 "模型配置" 改为 "打开配置页面"
2. **`StageModelButton.Add_Click`**（行 6745）：从 `Invoke-AppAction 'model'` 改为 `Invoke-AppAction 'open-config-ui'`
3. **`Get-UiState`**（行 5741-5771）：移除 `GatewayStatus` 和 `GatewayRuntime` 字段
4. **`Refresh-Status`**（行 6094-6251）：简化首页状态逻辑，移除所有 Gateway 相关条件
5. **`Get-Recommendation`**（行 5773-5940）：移除所有 Gateway 相关推荐路径
6. **`Invoke-AppAction 'launch-webui'`**（行 6449-6484）：模型未配置时，改为打开配置页面而非模型弹窗
7. **`Get-UseModeActions`**（行 5982-6036）：移除 gateway 相关 action
8. **`Show-QuickCheckDialog`**（行 5940-5980）：移除 gateway 相关检查项
9. **`Show-AdvancedPanel`**（行 5159-5220）：已有 WebUI 管理按钮，考虑是否需要调整
10. **窗口关闭处理**（行 6777）：finally 块添加 `Stop-HermesWebUiRuntime`（现有 WebUI）和新配置 UI 的进程清理
11. **`Get-InstallFeedbackText`**（行 5562-5589）：移除 GatewayStatus 引用

### 6.3 新增代码

**新增 Invoke-AppAction 分支 `'open-config-ui'`**：
- 检测 hermes-web-ui 是否已安装
- 未安装 → 下载预打包 zip 并解压（显示进度）
- 已安装 → 检测服务是否运行
- 未运行 → 启动 node.exe server.js
- 已运行 → 直接打开浏览器
- 打开浏览器 → `http://127.0.0.1:3210`

这个 action 的逻辑大约 50-80 行，加上 5 个配置 UI 管理函数约 200 行，总计约 250-300 行新增。

---

## 七、风险评估

### 高风险
1. **Refresh-Status 改错**：这个函数是启动器的核心状态机，删除 Gateway 相关逻辑时如果遗漏引用会导致崩溃
2. **Get-UiState 返回结构变化**：所有引用 `$state.GatewayStatus` 和 `$state.GatewayRuntime` 的地方都需要清理

### 中风险
3. **现有 WebUI 命名冲突**：两套 WebUI 共存时的变量/目录/端口冲突
4. **Node.js 预打包 zip 尚未构建**：这是外部依赖，启动器代码可以先写好，但无法端到端测试

### 低风险
5. **XAML 按钮减少后布局变化**：删除"消息渠道"按钮后，首页按钮从 4 个变 3 个，视觉上可能需要微调

---

## 八、建议实施顺序

1. **第一步**：删除模型配置对话框 + Provider 目录 + IO 函数（约 1740 行）
2. **第二步**：删除消息渠道相关代码（约 652 行）
3. **第三步**：修改 Get-UiState、Refresh-Status、Get-Recommendation 等状态机代码
4. **第四步**：修改 XAML 和事件绑定（按钮改名/删除）
5. **第五步**：新增 hermes-web-ui 配置界面管理代码
6. **第六步**：添加窗口关闭时的进程清理

建议每一步完成后运行 SelfTest 验证不崩溃，再进行下一步。

---

## 九、待 PM 决策的问题

### 问题 1：两套 WebUI 如何命名区分？

现有 hermes-webui（对话界面）和新的 hermes-web-ui（配置界面）在用户层面怎么称呼？

- 选项 A：对话界面叫"对话窗口"，配置界面叫"配置页面"
- 选项 B：统一叫"WebUI"（因为对话本来就通过 WebUI 进行），配置界面叫"配置中心"
- 选项 C：其他

**建议选 A**，代码层面用 `WebUi`（现有对话）和 `ConfigUi`（新配置界面）区分。

### 问题 2：hermes-web-ui 预打包 zip 的构建由谁负责？

任务文档说"不在本次范围"，但启动器代码需要一个真实的下载 URL 才能端到端测试。

- 选项 A：先用 placeholder URL，启动器代码先写好，后续 zip 就绪后改 URL
- 选项 B：等 zip 构建好后再开始写启动器代码

**建议选 A**。

### 问题 3：窗口关闭时是否也停止现有的 hermes-webui 对话界面？

当前行为是不停止（遗漏）。本次改动可以顺手修复。

- 选项 A：修复，关闭启动器时同时停止 hermes-webui（对话）+ hermes-web-ui（配置）
- 选项 B：不修复，记进 TODO.md

**建议选 A**，代码只需在 finally 块加一行。
