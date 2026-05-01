# TODO

代码中发现的已知问题，当前不修，记录备查。

---

### 待办：遥测系统 v2（任务 011 后续）

任务 011 v1 上线后的下一轮迭代，按价值优先级排：

1. **Mac 版埋点**：本期只覆盖 Windows 启动器，Mac 端 `LauncherRootView.swift` 同样需要接入。
2. **`first_conversation` 事件**：发生在 webui 内部，启动器观察不到。需要 hermes-web-ui 同样接入遥测，或启动器去读 webui 的对话历史目录做粗判（侵入性大）。
3. **`hermes_install_step` 事件**：上游 install.ps1 在外部终端运行，启动器只能拿到最终退出码。要拿到分步事件需要要么修改上游脚本（违反"不 fork 上游"原则），要么 wrapper 脚本里加日志解析。
4. **可视化看板升级**：现在的 `dashboard/index.html` 只画了基础表格 + 简单漏斗。后期可改用 Grafana / Metabase / 自建 React + Recharts。
5. **数据异常自动告警**：失败率突增、独立用户数暴跌等，自动推到 PM 邮箱或 Telegram。
6. **D1 自动按月分表**：当前所有事件都进同一张 `events` 表，量大后需要按月切分（`events_2026_05`、`events_2026_06`）防止单表过大影响查询。
7. **崩溃事件补传**：启动器异常崩溃时本地写一份 `crash.json`，下次启动时补传 `crash` 事件。
8. **遥测数据保留期策略**：当前没有自动清理。建议 90 天后归档，180 天后删除。

整合者补充（QA 报告 P1-3/P1-4/P2-1/P2-2）：

9. **[v2 - 视觉规范] 启动器内 banner / 关于对话框迁移到 LauncherPalette 暖色调**（QA 报告 P1-3）—— 整体 Windows 端 UI 暖色化是单独任务，不在遥测范围内。
10. **[v2 - 健壮性] Sanitize-TelemetryProperties 递归处理嵌套 hashtable / PSCustomObject，默认 fail-secure**（QA 报告 P1-4）—— 当前所有埋点都是扁平结构，没有真实泄露路径；fail-secure 是好实践但属于代码健壮性而非合规性。
11. **[v2 - 性能] launcher_closed 的 600ms sleep 改成 task.Wait(800) 带 timeout 同步等**（QA 报告 P2-2）—— 当前已可工作，是优化项。
12. **[v2 - deploy] 移除 deploy.sh L67-71 永远不触发的 worker/ 守卫，或改成扫源码 cp 列表**（QA 报告 P2-1）—— "心安代码"无害，可下版本清理。

---

### 待办：保存模型配置前增加连通性校验

**用户反馈**：用户填了 API Key 和 Base URL 点保存，保存直接成功了，
但用户去对话时才发现填的信息其实是错的（key 失效、base_url 打错、余额不足等）。
用户的心智预期是"保存成功 = 可以用"，现在不是这样。

**建议方案**：保存前自动对填的 provider + base_url + api_key + model 发一次简单请求
（比如让模型回复"ok"），3-5 秒内能拿到响应就算成功。

**交互细节待定**：
- 校验时长、超时处理
- 失败后是强制修改还是允许"先保存后续再改"
- 本地模型（Ollama 等）是否也要校验

**优先级**：~~中~~ → **高**。

**为什么提升为高**：hermes 有 `fallback_model` 机制，当用户填的自定义配置不通（key 错、base_url 错等）时，hermes 会静默切到备用模型继续对话。用户看到对话能通，以为配置正确，其实用的是备用模型。这比单纯"填错了没提示"更严重 — 它制造了一个"一切正常"的假象，用户可能长期使用错误的模型而不自知。

**建议**：和未来的"模型配置向导"放一起做，在保存时发一次试探请求，把实际响应的模型名显示给用户确认。

**进展**：已拆为 `tasks/002-validate-model-config.md`，方案设计中。

---

### 待办：补上 Anthropic 原生接口的连通性校验

Anthropic 的 API 不是 OpenAI 兼容格式（用 Messages API 而非 chat/completions），任务 002 先跳过校验，选 Anthropic 时 UI 提示"当前 provider 暂不支持自动校验"。

**优先级**：低。Anthropic 用户量较少，且 API Key 型用户更少（多数走账号登录）。

---

### 待修复：模型名下拉框背景色与深色主题不协调（低优先级）

WPF 的 `ComboBox` 在 `IsEditable="True"` 模式下，内部的 `PART_EditableTextBox` 背景色总是白色，和深色主题的整体配色冲突。纯样式覆盖不生效，需要用 `ControlTemplate` 重写。

**影响范围**：仅模型名下拉框（`ModelNameTextBox`），不影响功能。

**优先级**：低。视觉问题，不影响操作。等 Windows 端整体风格迁移时一并处理。

---

### 发版流程工具化（低优先级）

当前发版依赖手动跑 wrangler 命令。将来可以写个 deploy.ps1 脚本把完整流程封装起来（更新版本号 + 打包 + .cloudflareignore 检查 + 部署 + 验证提示）。本次先不做，等下次发版体感不顺时再做。

**优先级**：低。

---

### 待办：Refresh-Status 其他裸调用加保护（Medium）

**背景**：本次 Python 闪退 bug 修复（第 6767 行）为 Refresh-Status 加了 try-catch，但全文还有约 30 处裸调用未做同等保护。如果这些位置的上下文环境异常，同样可能导致静默闪退或日志中断。

**建议方案**：统一封装一个 `Invoke-RefreshStatus` 包装函数，内含 try-catch + 日志写入，全局替换裸调用。

**优先级**：中。等 Python 修复上线验证稳定后，下一个专项任务处理。

---

### 待办：Refresh-Status 异常时增加用户可见 fallback UI（Low-Medium）

**背景**：当前 catch 块只写日志，用户不知道环境检测出了问题。建议：异常时设置安装模式 + 在界面某处显示"环境检测遇到异常，请查看日志"提示。

**优先级**：低-中。用户已不会闪退，只是体验未达最优。可与上条裸调用整改一起做。

---

### 待办：Invoke-AppAction 中裸 Refresh-Status 调用加保护（Medium）

**背景**：质检发现 `Invoke-AppAction` 函数内也有无保护的 Refresh-Status 调用，属于同类风险点。

**优先级**：中。纳入下次 Refresh-Status 整改范围一起处理。

---

### 待办：Install-HermesWebUi 下载期间 UI 线程阻塞（Medium）

**背景**：`Install-HermesWebUi` 中的 `Invoke-WebRequest` 和 `Start-HermesWebUiRuntime` 中的端口等待循环都是同步调用，会阻塞 WPF UI 线程。下载预打包 zip（50-80MB）时窗口会显示"未响应"。

**建议方案**：用 RunspacePool 或 Background Job 做异步下载，进度通过 Dispatcher 回调更新 UI。

**优先级**：中。当前流程功能正确但体验不佳，等 hermes-web-ui 预打包 zip 就绪后优先处理。

---

### 待办：hermes-web-ui 保存渠道配置后显示"保存失败"（上游问题）

**背景**：用户在 hermes-web-ui 中配置消息渠道（微信、飞书等），点保存后 UI 显示"保存失败"。实际上配置已成功写入 `~/.hermes/.env`，但 web-ui 保存后会自动调用 `hermes gateway restart`，该命令在 Windows 上依赖 systemd 不可用，导致崩溃。web-ui 把"写配置"和"重启 gateway"两步的结果合并展示，所以用户看到的是"失败"。

**当前规避**：启动器已改为每次启动时 `--replace` 重启 gateway + 设置 `GATEWAY_ALLOW_ALL_USERS=true`，所以用户重开启动器后渠道会生效。

**用户感知**：
- 配完渠道看到"保存失败" → 以为没保存上 → 实际已保存
- 需要重开启动器才能让渠道生效 → 用户不知道要这么做

**理想方案**：向 hermes-web-ui 上游反馈，在 Windows 上跳过 `hermes gateway restart`，改用信号或 API 通知 gateway 热加载配置。或者启动器端拦截 web-ui 的 gateway 管理，由启动器统一管理 gateway 生命周期。

**优先级**：中。功能可用但体验误导，需要向上游提 issue。

---

### 待办：Gateway 默认拒绝所有消息用户（已临时修复）

**背景**：hermes gateway 默认 `GATEWAY_ALLOW_ALL_USERS=false`，所有消息平台（微信、飞书、Telegram 等）的用户发消息会被静默拒绝，日志显示 `Unauthorized user`。对于个人启动器场景，用户不会理解"为什么配好了还是没反应"。

**当前修复**：启动器 `Start-HermesGateway` 中已设置 `$env:GATEWAY_ALLOW_ALL_USERS = 'true'`。

**风险**：如果用户不通过启动器而是手动运行 `hermes gateway run`，仍会遇到此问题。

**优先级**：低。启动器端已修复，仅手动运行场景受影响。

---

### 待办：hermes-web-ui 内置升级按钮无效（上游问题）

**背景**：hermes-web-ui 检测到新版本后，界面会显示升级提示。用户点击升级按钮后没有任何反应。

**根因**：web-ui 的 `POST /api/hermes/update` 接口被自身的 auth 中间件拦截，返回 `Unauthorized`。升级请求根本没到达 npm install 那一步。

**次要问题**：即使 auth 修复了，升级命令 `npm install -g hermes-web-ui@latest` 也有两个隐患：
- 便携版 Node.js 的 npm 默认全局目录（`%APPDATA%\npm`）与启动器实际使用的目录（`%LOCALAPPDATA%\hermes\npm-global`）不一致（启动器已通过设置 `NPM_CONFIG_PREFIX` 环境变量规避）
- 升级后执行 `hermes-web-ui restart`，可能与启动器的进程管理冲突

**当前规避**：启动器在启动 web-ui 前自动比较版本号，发现旧版自动通过 npm install 升级。用户只需更新启动器即可获得最新 web-ui。

**理想方案**：向 hermes-web-ui 上游反馈，修复升级 API 的 auth 问题。

**优先级**：低。启动器端已有自动升级机制。

---

### 待办：渠道平台可选依赖未随 hermes 安装（上游问题）

**背景**：hermes-agent 的消息渠道（飞书、Telegram、Slack、钉钉、Discord 等）依赖额外的 Python 包（如 `lark-oapi`、`python-telegram-bot` 等），这些包是可选依赖，`hermes install` 不会自动安装。用户在 web-ui 中配置渠道后，gateway 因缺少依赖而静默跳过该平台，日志中没有明显报错，用户只看到"消息没回应"。

**当前修复**：启动器 `Install-GatewayPlatformDeps` 函数在启动 gateway 前自动检测 `.env` 中配置的渠道并安装缺失依赖。

**覆盖的渠道**：飞书（lark-oapi）、Telegram（python-telegram-bot）、Slack（slack-bolt）、钉钉（dingtalk-stream）、Discord（discord.py）。

**理想方案**：hermes 上游在 web-ui 保存渠道配置时，自动安装对应的 Python 依赖。

**优先级**：低。启动器端已修复。

---

### 待办：hermes-web-ui 0.5.0 在中文 Windows 上无法启动（上游问题）

**背景**：hermes-web-ui 0.5.0 在中文 Windows 环境下有多个兼容性问题，导致启动失败。

**问题列表**：
1. **SQLite 数据库不兼容**：0.5.0 的数据库 schema 迁移代码（`ALTER TABLE ... DROP COLUMN`）与 0.4.9 的数据库不兼容，报 `near ",": syntax error` 和 `cannot drop PRIMARY KEY column: "id"`
2. **Profile 名称编码乱码**：0.5.0 的多 profile 管理功能在 GBK 编码环境下读取 profile 名称全部乱码（`"������������"`）
3. **Gateway restart GBK 编码崩溃**：0.5.0 尝试调用 `hermes gateway restart`，上游 gateway.py 中的 Unicode 字符（`\u2695`）无法被 GBK 编码，导致 `UnicodeEncodeError`

**当前规避**：启动器锁定 web-ui 版本为 0.4.9（`$script:HermesWebUiVersion = '0.4.9'`），不自动升级到 0.5.0。

**理想方案**：向 hermes-web-ui 上游反馈中文 Windows 兼容性问题，等修复后再升级。

**优先级**：中。0.4.9 功能正常，暂不影响使用。

---

### 待办：HermesGuiLauncher.ps1 死代码 / 历史遗留元素清扫（v2 任务）

**背景**：UI 全量地图扫描（见 `mockups/011-windows-ui/UI-MAP.md`）发现 3 处 UI 死代码和遗留元素，与功能无关、与视觉迁移可拆开做。建议下一个空档期单独立任务清掉，避免迁移视觉时把死代码也照搬一遍。

**清扫清单**：

1. **`InstallSettingsEditorBorder` 永远 collapsed**（`HermesGuiLauncher.ps1` L2790-2823）
   - XAML 里写了完整的安装设置编辑器（数据目录 / 安装目录 / Git 分支 / NoVenv / SkipSetup）+ 保存/恢复按钮
   - 全文 grep 所有 `Visibility` 设置点，**没有任何代码会把它设回 Visible**——它的入口已被 `Show-InstallLocationDialog` 替代
   - 删除影响：纯减法，无功能影响
2. **HomeModePanel 里 3 个 0×0 隐藏按钮**（`HermesGuiLauncher.ps1` L2867-2873）
   - `StageModelButton`、`SecondaryActionButton`、`RefreshButton` 三个按钮 Width=0/Height=0/Visibility=Collapsed
   - 仍然挂着 `Add_Click` 事件（L5234-5235、L5277），但 UI 上完全不可见
   - 历史遗留：早期 Home Mode 多按钮设计的残骸
   - 删除影响：要顺便把 L5233-5235、L5277 的事件绑定一并清掉
3. **`Show-QuickCheckDialog` 函数没任何 UI 入口**（`HermesGuiLauncher.ps1` L4752）
   - 函数定义存在；唯一调用点是 `Invoke-AppAction 'quick-check'`（L5110）
   - 但全文 grep 没有任何按钮/菜单/事件会派发 `quick-check` action
   - 函数本身也调用了 `MessageBox.Show`，与 Mac 端暖色调不兼容，迁移视觉前就该决定保留还是删除
   - 删除影响：可整段删函数 + 删 Invoke-AppAction 的 case 分支

**优先级**：低。无功能影响、无安全影响，是纯卫生项。建议在下一轮视觉迁移**之前**做，避免把死代码也按新视觉重做一遍。

---

### 待办：Windows 启动器视觉迁移 · 第二轮（Top-3 之外的所有项）

**背景**：任务 011-windows-ui Top-3 视觉迁移只覆盖了 (1) Home Mode 已就绪页 (2) Install Mode 安装漏斗主路径 (3) 关于对话框 + 首次启动隐私 banner。其他 UI 状态、对话框、嵌入元素仍是旧版深蓝黑色风格，与 Mac 端 `LauncherPalette` 暖色调不一致。建议下一轮单独立任务统一迁移。

完整地图见 `mockups/011-windows-ui/UI-MAP.md`，本条仅汇总未做的项 + 行号锚点。

**主窗口残余状态**（`HermesGuiLauncher.ps1` 主 XAML 在 L2734-2906）：

- **环境检测阻塞·缺 Git**（扫描时位于 L4889-4902）：失败摘要红色 + 主按钮"打开 Git 下载页"
- **环境检测阻塞·目录不可写**（L4891）：失败摘要 + 主按钮"更改安装位置"
- **环境检测阻塞·其他**（L4897）：失败摘要 + 主按钮"查看解决说明"
- **环境检测阻塞·上次残留目录**（L4250 + 4251 残留提示弹窗）：自动清理失败时的弹窗 + 主面板阻塞态
- **安装失败摘要**（L3568-3569 + L4860 主面板）：红色多行文本块（含退出码 + 最近日志）
- **OpenClaw 迁移引导**（L4843、L2845 `OpenClawPostInstallBorder`）：独占主面板的迁移卡片 + 立即迁移 / 暂不迁移按钮

**对话框残余项**：

- **2.2 更多设置面板** — `Show-AdvancedPanel`（L3908）+ 通用对话框壳 `New-SubPanelWindow`（L3785）+ 分区构造器 `Add-SubPanelSection`（L3832）。780×560，6-7 个分区卡片。高级用户高频使用。
- **2.3 更改安装位置对话框** — `Show-InstallLocationDialog`（L4539）。760×430，含 FolderBrowserDialog 调用 + Expander 高级选项。低频但表单密集。
- **2.4 终端确认对话框** — `Confirm-TerminalAction`（L2308）。原生 `MessageBox.Show`。被 9 个操作复用，**几乎每个核心操作都会撞一次**。要换外观需自绘 WPF 对话框替代原生 MessageBox，工作量较大。
- **2.5 卸载选择对话框** — L5212-5223 原生 `MessageBox.Show` YesNoCancel
- **2.6 快速检测结果对话框** — `Show-QuickCheckDialog`（L4752）。原生 MessageBox。**当前无入口**，见死代码清扫条目，决定保留再迁移。
- **2.7 WebUI 启动失败对话框** — `Stop-LaunchAsync` 内 L3258 原生 MessageBox YesNo
- **2.8 残留目录提示对话框** — L4251 原生 MessageBox OKCancel + 配套 explorer 定位
- **2.9 简易报错 / 校验对话框** — 共 8 处 `MessageBox.Show($message, 'Hermes 启动器')`：L14（单实例锁）、L5014/5026/5030/5034/5079/5093/5116/5128/5138（命令未找到 / 字段为空 / 顺序错）、L4986（显示安装位置）

**嵌入元素残余项**：

- **安装日志区** `LogSectionBorder`（L2880）：黑底 Consolas 终端风，最大高度 190。Install Mode 显示，Home Mode 隐藏。
- **底部状态栏** `FooterBorder`（L2901）：单行状态文字。同样 Install Mode 显示、Home Mode 隐藏。
- **进度指示**：当前没有专门的 ProgressBar 控件，进度=按钮 disable + 文本里的 ✓✓→○ 字符。视觉迁移时可考虑加专门的进度组件。

**隐性 UX 问题**（顺手改建议）：

- Home Mode 启动 webui 时，footer/log 都被 collapse，用户从点"开始使用"到浏览器打开（最长 1-2 分钟）只看到一个 disabled 按钮，**全程无进度反馈**。建议第二轮做 Home Mode 时增加一块"启动进度"区域。

**优先级**：中。Top-3 上线后用户会感受到"主流程很 Mac，分支/对话框还是老样子"的割裂感。建议 Top-3 灰度稳定 1-2 周后立第二轮任务。

---

### 元任务提醒：视觉迁移整体节奏

下一轮 Windows 端视觉迁移做完 Top-3 后，如果想做到全量统一，从上面"第二轮"那条扩展，按主窗口状态 → 高频对话框 → 低频对话框 → MessageBox 自绘的顺序推进；**MessageBox 自绘**（条目 2.4-2.9）成本高收益低，可一直放最后甚至不做。
