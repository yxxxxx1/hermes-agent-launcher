# 任务 010 工程师报告：启动器瘦身 — 统一迁移至 hermes-web-ui

## 一、改动清单

### 步骤 1：删除模型配置代码（~1740 行）
| 函数 | 说明 |
|------|------|
| `Get-ModelProviderCatalog` | 29 个 provider 的静态定义，已删除 |
| `Set-EnvAssignmentValue` | .env 写入辅���函数，仅被删除的函数调用，已确认安全删除 |
| `Set-YamlTopLevelBlock` | YAML 写入辅助函数，仅被删除的函数调用，已确认安全删除 |
| `Get-HermesModelSnapshot` | 读取 config.yaml 中的 model 块快照 |
| `Test-ModelDialogInput` | 校验对话框输入 |
| `Save-HermesModelDialogConfig` | 写入 config.yaml + .env |
| `Save-HermesProviderConfigOnly` | 仅���入 provider 配置 |
| `Test-ModelProviderConnectivity` | API 连通性校验 |
| `Get-HermesProviderModelCatalog` | 通过 Python 获取 provider 支持的模型列表 |
| `Show-ModelConfigDialog` | 完整的模型配置弹窗（~1019 行） |

**保留**：`Test-HermesModelConfigured`、`Get-EnvAssignmentValue`、`Get-YamlTopLevelBlockText`、`Get-YamlBlockFieldValue`

### 步骤 2：删除消息渠道配置代码（~652 行）
| 函数 | 说明 |
|------|------|
| `Normalize-FriendlyMessagingDefaults` | 微信消息渠道授权方式调整 |
| `Test-HermesGatewayReadiness` | 通过 Python 探测已配置渠道 |
| `Get-GatewayLockDirectory` | 获取 gateway 锁目录 |
| `Clear-StaleGatewayRuntimeFiles` | 清理 gateway.pid/state |
| `Clear-StaleGatewayScopeLocks` | 清理 scope lock 文件 |
| `Get-GatewayRuntimeStatus` | 读取 gateway 进程状态 |
| `Start-MessagingDependencyInstall` | 启动消息渠道依赖安装终端 |
| `Stop-ExternalModelTimer` | 停止模型配置监视器 |
| `Stop-ExternalGatewaySetupTimer` | 停止 gateway setup 监视器 |
| `Stop-ExternalMessagingTimer` | 停止消息依赖安装监视器 |
| `New-HiddenGatewayWrapper` | 生成后台 gateway 启动脚本 |
| `Start-ExternalModelMonitor` | 监视模型配置终端进程 |
| `Start-GatewayRuntimeLaunch` | 后台启动 gateway |
| `Start-ExternalGatewaySetupMonitor` | 监视 gateway setup 终端 |
| `Start-ExternalMessagingMonitor` | 监视消息依赖安装终端 |
| `Show-GatewayPanel` | 消息渠道子面板弹窗 |
| `Schedule-GatewayLaunchCheck` | 延迟复检 gateway 启动状态 |

### 步骤 3：删除旧版对话 WebUI 代码（~500 行）
| 函数 | 说明 |
|------|------|
| `Get-HermesWebUiDefaults`（旧） | nesquena/hermes-webui 的路径/端口/版本配置 |
| `Test-HermesWebUiInstalled`（旧） | 检测 Python server.py 安装状态 |
| `Assert-SafeWebUiPath` | WebUI 路径安全检查 |
| `Install-HermesWebUi`（旧） | 下载 GitHub archive zip 并解压 |
| `Test-HermesWebUiPythonReady` | 检测 Python pyyaml 依赖 |
| `Ensure-HermesWebUiPythonDependency` | 安装 Python 依赖 |
| `Load-HermesWebUiRuntimeState` | 读取 WebUI 运行时状态 |
| `Test-HermesWebUiHealth`（旧） | 端口健康检查 |
| `Get-HermesWebUiStatus`（旧） | 综合状态 |
| `Save-HermesWebUiRuntimeState` | 保存运���时状态到 JSON |
| `Wait-HermesWebUiHealth` | 轮询等待健康检查通过 |
| `Resolve-HermesWebUiPort` | 端口选择（8787-8799） |
| `Start-HermesWebUiRuntime`（旧） | 用 Python 启动 server.py |
| `Set-HermesWebUiDefaults` | 推送默认设置到 WebUI API |
| `Stop-HermesWebUiRuntime`（旧） | 停止 WebUI 进程 |
| `Ensure-HermesWebUiReady` | 一键确保 WebUI 就绪 |

### 步骤 4：修改状态机
| 函数 | 改动 |
|------|------|
| `Get-UiState` | 移除 `GatewayStatus`、`GatewayRuntime` 字段；WebUiStatus 改用新 `Get-HermesWebUiStatus` |
| `Refresh-Status` | 首页状态文字简化为"已就绪"；移除所有 Gateway 和旧 WebUI 条件分支 |
| `Get-Recommendation` | 简化为 3 个分支（未安装 → OpenClaw 迁移 → 已就绪） |
| `Get-UseModeActions` | 简化为单一"开始使用"动作 |
| `Show-QuickCheckDialog` | 移除 Gateway 相关检查项，改为 hermes-web-ui 状态 |
| `Get-InstallFeedbackText` | 移除 `MessagingConfigured` 字段，改为 `WebUiInstalled`/`WebUiHealthy` |

### 步骤 5：简化首页 XAML 和事件绑定
- `StageGatewayButton` → 从 XAML 和 controls 列表中删除
- `StageModelButton` → Content 改为 "开始使用"，点击改为 `Invoke-AppAction 'launch'`
- `PrimaryActionButton` → Content 改为 "开始使用"
- `StatusHeadlineText` → 默认文字改为 "已就绪"
- 首页现在只有 3 个按钮：`PrimaryActionButton`（开始使用）、`StageModelButton`（开始使用）、`StageAdvancedButton`（更多设置）

### 步骤 6：新增 hermes-web-ui 管理代码（~195 行）
| 函数 | 说明 |
|------|------|
| `Get-HermesWebUiDefaults` | 路径/端口/版本配置（InstallDir: `%LOCALAPPDATA%\hermes\hermes-web-ui`，Port: 3210） |
| `Test-HermesWebUiInstalled` | 检测 node.exe 和 server.js 是否存在 |
| `Install-HermesWebUi` | 下载预打包 zip → 解压到 InstallDir，显示进度 |
| `Test-HermesWebUiHealth` | HTTP 检查 127.0.0.1:3210 |
| `Start-HermesWebUiRuntime` | 用内置 node.exe 启动 server.js，后台进程，等端口就绪（最多 15 秒） |
| `Stop-HermesWebUiRuntime` | 停止 hermes-web-ui 进程（PID 文件 + 进程扫描） |
| `Get-HermesWebUiStatus` | 综合状态（Installed、Healthy、Url、Version） |

### 步骤 7：重写 Invoke-AppAction 'launch' 分支
```
用户点"开始使���" →
  1. hermes 未安装？→ 提示先安装
  2. hermes-web-ui 已在运行？→ 直接打开浏览器
  3. hermes-web-ui 未安装？�� Install-HermesWebUi（显示进度）
  4. Start-HermesWebUiRuntime → 等端口就�� → 打开浏览器
  5. 失败时提供命令行对话备选
```

### 步骤 8：窗口关闭清理
- `finally` 块���添加 `Stop-HermesWebUiRuntime` 调用
- 确保启动器关闭时 hermes-web-ui 进程被正确终止

### 其他清理
- 删除了 6 个 `$script:` 级 Gateway 相关变量
- 删除了 5 个 `$script:` 级 External monitor 相关变量
- 删除了 `$script:LocalChatVerificationPending`、`$script:LocalChatVerified` 变量
- 替换旧 WebUI script 变量为新的 `$script:HermesWebUiHost`、`$script:HermesWebUiPort`、`$script:HermesWebUiDownloadUrl`、`$script:HermesWebUiVersion`
- 新增 `$script:WebUiProcessRef` 用于保存 hermes-web-ui 进程引用
- `Get-HermesDefaults` 移除了旧 WebUI 相关字段
- `Show-AdvancedPanel` 的 WebUI 区块更新为 hermes-web-ui 风格
- 删除了 Invoke-AppAction 中的 `'model'`、`'confirm-local-chat'`、`'gateway-setup'`、`'install-messaging'`、`'gateway'`、`'restart-webui'`、`'update-webui'` 分支
- 更新了 `'open-webui-logs'`、`'open-webui-dir'` 分支使用新的 `Get-HermesWebUiDefaults`
- 移除了重���的 `Get-ObjectPropertyValue` 函数定义

## 二、SelfTest 结果

```
通过。输出 JSON 正确，包含新的 WebUi 字段（Version/Installed/Healthy/Url）。
```

## 三、行数统计

| 项目 | 行数 |
|------|------|
| 原始文件 | 6782 行 |
| 最终文件 | 3559 行 |
| 净减少 | **3223 行** |
| 新增代码 | ~240 行 |
| 总删除代码 | ~3463 行 |

## 四、���知陷阱规避声明

| 陷阱编号 | 规避措施 |
|----------|---------|
| #1 WPF Dispatcher 异常 | 新增的 launch 流程中 Install/Start 操作都在 try-catch 内 |
| #3 中文 Windows 错误匹配 | 新代码不做错误消息文本匹配 |
| #4 UI 信息位置 | 进度/错误信息通过 Add-ActionLog 写入日志区，在用户视线内 |
| #5 跨框架 API 替换 | 新的 hermes-web-ui 是 Node.js，不依赖旧 Python WebUI |
| #6 分支管理 | 当前在 `codex/next-flow-upgrade` 分支，未 commit |

## 五、自检盲区声明

### 无法覆盖的方面
- WPF 窗口实际渲染效果（按钮减少后的布局是否美观）
- 真实 hermes-web-ui zip 的下载和解压（当前 URL 是 placeholder）
- 真实 Node.js 服务的启动和端口就绪
- 中文 Windows ���境下 node.exe 的进程行为
- 安全软件对 node.exe 的拦截行为
- 高 DPI 屏幕的显示效果
- 网络代理/翻��环境下的 zip 下载

### 需要 PM 真机验证
1. 打开启动器，确认首页只有 2 个主按钮区域
2. 点击"开始使用"按钮，确认流程走通（需要 hermes-web-ui zip 先发布）
3. 关闭启动器后确认 node 进程被终止
4. 确认"更多设置"面板的 hermes-web-ui 区块显示正确
