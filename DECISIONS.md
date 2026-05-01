# DECISIONS

重要技术决策与权衡记录，按时间倒序归档。

---

### 2026-05-01 — 任务 011：启动器接入匿名遥测（Cloudflare Worker + D1）

**背景**：长期处于"产品健康度黑盒"状态——不知道每天多少人下载、装成功率多少、失败卡在哪一步。继续靠用户群偶尔反馈做迭代等于猜。

**实现**：
- **数据通道**：Cloudflare Worker 接收 POST `/api/telemetry` → 写入 D1 数据库 `events` 表。看板 GET `/api/dashboard` 用 Bearer Token 鉴权，dashboard 是部署在 Cloudflare Pages 的单页 HTML，只调 Worker API。
- **隐私边界（第一红线）**：
  - **收集**：事件名、版本号、Win10/Win11 大类、内存档位（<8/8-16/>16 GB）、错误类型（脱敏后的 reason）、首次生成的匿名 UUID（`%APPDATA%\HermesLauncher\anonymous_id`）。
  - **不收集**：用户名、机器名、邮箱、IP（IP 仅做 8 位哈希用于地理粗粒度统计）、API Key/Token/密码、对话内容、本地路径中的用户名段。
  - **脱敏**：所有上报字符串经 `Sanitize-TelemetryString` 处理：`sk-*`、`api_key=*`、`token=*`、`password=*`、`secret=*`、`Bearer *`、用户名、Win/POSIX 用户路径、邮箱、IPv4 全部替换。
- **决策 A**：默认开启 + 设置可关 + 首次启动顶部小提示（非弹窗、非阻塞）。可在「关于」对话框中关闭。
- **决策 D（事件清单）**：取 D2 中版（任务文档默认 14 + 工程师补 3 = 17）。WSL 相关事件实际无钩子（启动器走 Git Bash 不走 WSL），剔除后实际埋了 16 个事件名（含成功/失败两态）。`first_conversation` 事件在 webui 内发生，本期未埋（v2 待办）。
- **决策 E（看板鉴权）**：Bearer Token Header（Worker 的 `DASHBOARD_TOKEN` secret），令牌不进 URL，不会被浏览器历史/Cloudflare 访问日志泄漏。

**关键约束**：
- 上报失败必须**完全静默**，绝不阻塞主线程或弹错（陷阱 #1 / #4）。所有 `Send-Telemetry` 调用全程 try-catch，异步走 `HttpClient.PostAsync` fire-and-forget。
- 匿名 ID / 设置文件用 UTF-8 无 BOM 写入（陷阱 #21）。
- Worker 源码 (`worker/`) 走 deploy.sh 黑名单 + `.cloudflareignore` 双保险，绝不部署到 Pages（陷阱 #7 / #12）。

**为什么是基础设施而不是直接画图**：第一版数据足够支撑 PM 用 D1 控制台直接 SQL 查；可视化看板（更复杂的图表/Grafana/Metabase）放 v2，避免第一版 over-engineer。

**返工后补充（2026-05-01）**：v1 一次性过 QA 失败，QA 实测脱敏函数对 GitHub PAT / Google AIza key / IPv6 / URL 编码路径 / JSON 风格 password 共 5 类真实生产可触发的格式漏脱（11/16）。整合者判定返工，5 项 F1-F5 修复后：
- **脱敏覆盖**：QA 对抗测试 16/16 + 工程师正向测试 21/21 = **32 个 case 全过**。漏脱即"脏数据进 D1 永久存储"，且 D1 无"重写历史"概念，必须在上线前堵死。
- **端点固定为 `telemetry.aisuper.win`**：通过 `wrangler.toml [[routes]] custom_domain=true` 自动绑定到 PM 自有 zone（`aisuper.win` 已在同一 Cloudflare 账号下）。**取代**之前的 `*.workers.dev` 占位 URL，PM 部署后无需回头改代码重打包发版（陷阱 #30）。
- **deploy.sh 加版本 vs zip 自检**：从 `HermesGuiLauncher.ps1` 解析 `$script:LauncherVersion` 后校验 `downloads/Hermes-Windows-Launcher-v$VERSION.zip` 存在 + `index.html` 引用一致，缺失则 abort。防陷阱 #13 / #31 复刻。
- **关于按钮可见性**：Foreground 从 `#94A3B8` → `#E2E8F0`，BorderBrush 从 `#334155` → `#475569`，与标题栏其他文字同对比度。
- **关闭遥测视觉反馈**：「关于」对话框 CheckBox 下方加 `AboutTelemetryStatus` 实时显示「✓ 已开启 / 已关闭」状态，不再要求用户去日志区找确认。

**沉淀的新陷阱**：#28（HttpClient fire-and-forget 进程退出中断）、#29（任务事件清单与代码 hook 不匹配）、#30（硬编码外部 URL）、#31（发版前必须先打 zip）。

**沉淀的流程改进**：WORKFLOW.md 新增「红线要求专项流程」——任务文档标"第一红线"的，工程师必须额外提供"对抗性测试"，质检员独立写一份对抗测试不参考工程师的，两套都过才算红线达标。本规则在任务 011 由 QA 帮发现 5 个漏脱后沉淀。

**最终里程碑（2026-05-01，整合者 v2 判定）**：**任务 011 最终通过，QA 二轮评分 94.5/100**（基础可用性 39/40 + 用户体验 28/30 + 产品姿态 18/20 + 长期质量 9.5/10）。三 Agent 协作流完整跑通：工程师 v1 → QA v1（85，返工）→ 整合者锁定 5 项 F1-F5 → 工程师 v2 →  QA v2（94.5，通过）→ 整合者最终判定。PM 介入预算 = 任务模板 10 分钟 + 真机验收 10 分钟 = 20 分钟，符合 WORKFLOW.md 协作流目标。**核心学习**：(1) 第一红线机制必要——若无 QA 独立对抗测试，5 处隐私漏洞将永久进 D1；(2) 加分项无法折抵红线扣分——工程师 v1 在诚实度 / 防御性编码 / 测试覆盖度都是 95+ 质量，但任务红线独立卡死；(3) 流程改进 > 代码改进——本任务最大副产品是 WORKFLOW.md「红线要求专项流程」，未来同类任务直接受益。**对外发版**：v2026.05.01.6（Windows 端首次接入遥测 + 第三方 Cloudflare 基础设施 v1）。

**生产上线（2026-05-01，完整部署完结）**：

- **Worker**：`https://telemetry.aisuper.win`（Custom Domain 自动绑定到 PM 自有 zone，HTTPS 自动签发，无需手动配 DNS）
- **D1 Database**：`hermes-telemetry`（APAC region），表 `events` + 3 索引就绪
- **看板**：`https://hermes.aisuper.win/dashboard/`（Bearer Token 鉴权）
- **下载页**：`https://hermes.aisuper.win/downloads/Hermes-Windows-Launcher-v2026.05.01.6.zip`，58 KB
- **沉淀的新陷阱**：6 条（#28 HttpClient fire-and-forget / #29 事件清单与 hook 不匹配 / #30 硬编码外部 URL / #31 zip 必须先打 / #32 Custom Domain pattern 不支持 wildcard / #33 `cat | pipe` 引入尾换行）。其中 #32 #33 是部署 + token 轮换时新发现的，已沉淀。
- **部署期间的小波折（无害）**：(a) Custom Domain pattern `/*` 被拒，改裸域名 → 陷阱 #32；(b) 首次 token 上传后 PM 看板鉴权 401，诊断为 `cat | pipe` 引入换行，改用 Git Bash + `< file` 重定向后通过 → 陷阱 #33；(c) 这两个 gotcha 都在 30 分钟内闭环，没影响整体进度。
- **运营意义**：**这是 AI 自我升级系统的"听觉"**。从此每次发版后，PM 不需要靠用户群偶尔的反馈猜产品健康度——D1 + 看板会告诉我们：每天多少人下载、多少人装成功、卡在哪一步、什么错误最高频。下一轮迭代的优先级有数据支撑，不再是"凭感觉"。这是一项基础设施投资，配套的 Mac 端埋点、`first_conversation` 事件、可视化看板升级、自动告警等都已记入 TODO.md v2 待办。
- **真正最终发版动作**：worktree 分支 `claude/hardcore-keller-ec71a3` 合并到 `codex/next-flow-upgrade`（发布源），README.md + index.html 同步到 `main` 分支（GitHub 主页展示）。详见同期 git 提交记录。

---

### 2026-04-29 — v2026.04.29.2 安装流程健壮性修复

**问题**：新电脑首次安装时遇到三个连环问题：
1. 安装参数重复传递（Build-InstallArguments 返回了 PowerShell 级参数，wrapper 又加了一遍）
2. 安装终端闪退看不到报错（上游脚本退出码 0 时 wrapper 直接关窗口）
3. 上次安装失败残留的目录无法删除（Python venv 长路径超过 260 字符限制，"MS-DOS 功能无效"）

**修复**：
- Build-InstallArguments 只返回脚本参数，不再包含 -ExecutionPolicy/-File
- wrapper 成功时保留 5 秒、失败时要求按 Enter，都有中文提示
- Test-InstallPreflight 增加残留目录检测，三级清理：Remove-Item → cmd rd → robocopy 空目录镜像
- 清理失败时弹窗 + 打开文件资源管理器帮用户定位

**教训**：PowerShell 方法调用中 `-f` 格式化运算符的逗号会被解析为方法参数分隔符，必须先格式化成变量再传入。

---

### 教训：分支分叉状态下，文档类更新要同步到 main

本项目当前 main 和 codex/next-flow-upgrade 两个分支分叉。
Cloudflare 部署用的是 codex 分支，但 GitHub 仓库首页默认展示 main 分支。

对用户可见的"显示类"文件（README.md、LICENSE、图片等），
更新时必须同时推到 main，否则 GitHub 访客看到的是老版本。

约定：以后 Claude Code 改这几类文件时，主动询问 PM
"是否需要同步到 main 分支"，不要默认只推到当前工作分支。

---

### 2026-04-22 — 发版流程经验总结

**部署方式**：Cloudflare Pages 手动部署（Git Provider=No），不是 GitHub 自动触发。每次发版必须手动跑 `npx wrangler pages deploy`，push 到 GitHub 不会自动上线。

**线上生产分支**：`codex/next-flow-upgrade`，不是 `main`。历史遗留，部署时用 `--branch=main` 标记为 Production 环境。短期不改，但需要知道这个事实。

**安全措施**：`.cloudflareignore` 文件排除内部文档（CLAUDE.md、DECISIONS.md、TODO.md、tasks/、openspec/、.claude/）。每次新增内部文档类型时要同步更新这个文件，否则会被部署到 CDN 上可公开访问。

**发版前安全检查**：部署前必须扫描敏感内容（sk-*、api_key、.env 文件等），确认无真实凭据泄露。

---

### 产品沟通原则：版本说明要按用户感知裁剪，不按内部工作量写

发版说明的长度和详细度，应该**匹配用户实际感知到的变化**，而不是
匹配作者这次做了多少活。

判断标准：
- 用户不升级会错过什么？如果大部分用户不升级也无感，说明是小迭代
- 对这类小迭代，群里一两句话即可，不要写格式化长文
- 真正值得详细说明的时机：重大功能上线、破坏性变更、高频反馈集中回应

反例：把 "内部修复 4 个 bug + 新增 1 个功能 + UI 迭代两轮" 当成
卖点逐条列出——用户根本不关心过程，只关心结果。

正例：70 字说清楚"谁该升级、能解决什么问题、下载在哪"。

以后当你帮我拟对外沟通（发版公告、群通知、README 更新）时，默认走
"裁剪到用户视角"路线。除非我明确说"写详细版本"。

---

### 2026-04-22 — 任务 002 收尾：保存前连通性校验完成交付

**完整改动清单**：
1. 新增 `Test-ModelProviderConnectivity` 函数：对填入的 provider + base_url + api_key + model 发试探请求，区分 auth/connection/timeout/not_found 四类错误
2. `$saveHandler` 闭包：保存前调用连通性校验，失败时显示错误并允许"保留错误设置保存"
3. `$onFieldEdited` 闭包：用户编辑任一字段后自动清除错误状态，恢复正常按钮样式
4. `$refreshDialog` 闭包：切换 provider 时重置校验状态，显示对应 provider 的帮助文案
5. XAML 标签修改：右侧"当前检测"改为"已保存配置"，空状态文案同步更新

**两轮迭代原因**：

第一轮（3 个 crash + 1 个静默失败）：
- `Dispatcher.Invoke` 在 WPF 按钮事件中造成 PowerShell runspace 重入 → 删除 Dispatcher 调用
- `{ & $resetValidationState }.GetNewClosure()` 闭包嵌套导致 PS 5.1 会话状态链断裂 → 改为单层 `$onFieldEdited` 闭包
- `if (...) { ... } else { '' } + '中文'` PowerShell 运算符优先级解析错误 → 用 `$hintPrefix` 临时变量隔离
- 中文 Windows 的 .NET 异常消息被本地化，英文正则匹配失败 → 改用 `WebExceptionStatus` 枚举值判断

第二轮（4 个 UI 定位问题）：
- "当前检测"标签误导用户以为是实时校验结果 → 改为"已保存配置"
- 校验失败原因只显示在右侧面板，用户视线路径上看不到 → 改为在输入框附近的 `FieldHintText` 显示
- 底部警告只说"校验失败"太笼统 → 改为包含具体错误原因
- 超时提示不区分本地/远程服务 → localhost 提示"确认本地模型服务已启动"，远程提示"检查网络连接"

**结论**：所有功能和 UI 调整均经用户验收确认通过。

---

### 2026-04-22 — 经验：设计方案和实现必须逐条对照

**事件**：任务 002 设计方案明确写了"失败原因要在对应输入框附近显示"，但实现时把错误信息塞到了右侧"状态与引导"面板的 `ValidationStatusText` 里。功能测试全部通过，用户却找不到错误提示。

**教训**：UI 类任务做完前，必须对照设计方案里每一条交互描述，逐条确认实现位置是否和设计一致。AI 自测覆盖的是"数据对不对"，而不是"用户看得到吗"。

**约定**：
- 以后 UI 类任务的自测必须包括"用户视线路径模拟"：填写输入 → 看按钮 → 看反馈，这条路径上能看到关键信息吗？
- 同一信息（如"校验失败"）不在多处重复
- 文案要根据当前情境动态显示，不做一刀切的通用提示

---

### 2026-04-22 — 任务 001 调查结论：WebUI "用错配置"不是 bug

**用户反馈**：配置了自定义模型后，WebUI 对话好像没用新配置。

**调查结论**：启动器正确写入了 config.yaml 和 .env，hermes 也读到了配置。但用户填的自定义配置本身不通（key 错、base_url 错等），hermes 通过 `fallback_model` 机制自动切到了备用模型。用户在 UI 上看到对话能通，误以为启动器没用新配置。

**决策**：
- 任务 001 的 4 个 bug（api_key 双写、config.yaml 识别、回显、YAML 正则）已修复完成，启动器这一侧已做完该做的事。
- fallback 导致的"静默错误"属于用户体验问题，需通过"保存前连通性校验"解决，已提升为高优先级待办。
