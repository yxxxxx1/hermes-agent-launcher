# TODO

代码中发现的已知问题，当前不修，记录备查。

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
