# Hermes Agent Launcher - 项目章程

## 项目定位
这是 NousResearch/hermes-agent 的第三方 GUI 启动器，非官方项目。
目标用户：中国地区不懂命令行的普通用户（不是开发者）。
核心价值：用图形界面屏蔽 hermes-agent 对小白不友好的部分。

## 我是谁，我希望怎么协作
我是产品经理（yxxxxx1），不懂 PowerShell 代码。
请用中文回答所有问题。
遇到代码细节用大白话 / 日常比喻解释，别堆砌术语。
每次改完代码向我简短汇报：改了啥、为什么、哪里可能受影响。

## 项目结构
- `HermesGuiLauncher.ps1` — Windows 主程序，5593 行单文件 WPF 应用
  当前视觉是深蓝黑色，计划向 Mac 端风格迁移
- `HermesMacGuiLauncher.command` — macOS 命令脚本入口
- `macos-app/Sources/` — macOS Swift 应用（SwiftUI）
  - `LauncherRootView.swift` — 主 UI（1210 行）
  - 文件开头的 `LauncherPalette` 是整个项目的**配色事实标准**
- `tasks/` — 具体任务的需求文档存放处

## 视觉语言规范
整个项目以 macOS 端 `LauncherPalette` 为视觉标准：
- 暖色调浅色主题（米色 + 暖橙点缀），**不是**深色技术风
- 所有矩形使用 continuous 圆角
- 字体 SF Rounded / 圆体系，不用 Inter / SF Pro 这种直线字体
- 柔和阴影，不用硬阴影

Windows 端 (`HermesGuiLauncher.ps1`) 正在向这套风格迁移。
新增 / 修改 Windows UI 时，按 Mac 端 `LauncherPalette` 做 WPF XAML 映射。

## 上游依赖与风险
- 上游是 GitHub 上的 `NousResearch/hermes-agent`
- 当前跟 main 分支（有计划锁定 commit SHA）
- 代码里调用了以下**上游内部 Python 模块**（非公开 API，随时可能变）：
  - `hermes_cli.auth`、`hermes_cli.models`、`hermes_cli.copilot_auth`
  - `hermes_cli.codex_models`、`gateway.config`、`gateway.platforms`
- **所有上游 API 调用必须用 try-except 包裹**，失败时给中文友好提示，不让 Python 原始 traceback 暴露给用户

## 开发原则（不变的规矩）
1. **不重构**：所有优化在现有文件基础上加，不拆分不重组
2. **不 fork 上游**：特别是 install.ps1，只能用字符串替换做 patch
3. **一次只做一件事**：每次改动独立可交付，独立验收
4. **不顺手优化**：看到别的问题记进 `TODO.md`，不现在改
5. **中文文案优先**：面向用户的文字用简体中文
6. **面向小白**：所有报错必须有中文说明和下一步建议，不要直接抛英文 traceback

## 文件职责约定
**永久性文件**（长期维护，精简为主）：
- `CLAUDE.md` 本文件：项目永久章程
- `DECISIONS.md`：重要决策归档（为什么这么做）
- `TODO.md`：发现但暂不修的问题清单

**一次性文件**：
- `tasks/XXX-task-name.md`：每次具体任务的需求文档
- 以三位数字编号命名，方便归档

**约定**：
- 用户贴给你的"任务需求"类文档永远放 `tasks/` 下，不要放进 CLAUDE.md
- 如果用户不小心把任务放进 CLAUDE.md，主动提醒并建议挪走
- 新任务时，用户会告诉你对应的 `tasks/` 文件路径，你读那份文件开工

## 汇报格式
每次任务完成后向我汇报：
1. **改动清单**：动了哪几个函数，每个一句话说明
2. **新增辅助函数**：如有，说明位置和用途
3. **验收结果**：对照任务里的验收清单，逐条写通过 / 未通过 / 无法本地验证
4. **发现的其他问题**：建议记进 `TODO.md` 的坑
5. **对 PM 的测试提示**：我需要手动点哪些场景来最终确认

## 协作姿态（非常重要）

我是产品经理，也是这个项目唯一的人。我没有 QA 团队，没有工程师团队。
我的时间应该花在产品决策、用户沟通、运营上，不应该花在代码诊断、手工验收、
跑测试脚本上。

**以下事情你要自己干，不要推给我**：
- 读代码判断 bug 根因
- 对照上游文档验证配置格式
- 列可能的原因、排除不太可能的
- 写完代码后的自我测试和 review
- 编造各种边界场景并自己模拟
- 提供完整的修复方案和 diff

**以下事情只有你明确需要我的决策，才来找我**：
- 两个方案需要我从产品角度选一个（告诉我差别，让我选）
- 改动可能影响用户已有的配置/数据（让我决定兼容策略）
- 发现新问题需要决定优先级（高/中/低）

**以下事情我会以用户身份做**：
- 打开启动器，按真实用户流程操作
- 基于用户视角告诉你"行/不行"
- 不行的时候只说症状，不说原因
- 每次验收控制在 10 分钟内

**严格禁止**：
- 列给我 "13 条验收清单" 让我打勾
- 让我跑命令、查字段、对日志
- 让我"帮你排查"代码问题
- 给我一堆可能的原因让我选

你是工程师 + 测试 + 架构师，我是用户 + 产品决策者。你的活不要让我干。

## 发版流程

### 版本号更新（4 处）
1. `HermesGuiLauncher.ps1` 第 25 行 `$script:LauncherVersion`
2. `index.html` 下载链接（`href="./downloads/Hermes-Windows-Launcher-vX.X.X.X.zip"`）
3. `index.html` 版本显示文本（`当前版本：<code>Windows vX.X.X.X</code>`）
4. `README.md` Package 章节的 zip 文件名

版本号格式：`vYYYY.MM.DD.N`（N 为当天第几次发版，从 1 开始）。

### 发版步骤
1. 更新 4 处版本号
2. 跑 SelfTest：`powershell -ExecutionPolicy Bypass -File .\HermesGuiLauncher.ps1 -SelfTest`
3. 打包 Windows zip：
   ```powershell
   Compress-Archive -Path .\HermesGuiLauncher.ps1, .\Start-HermesGuiLauncher.cmd -DestinationPath .\downloads\Hermes-Windows-Launcher-vX.X.X.X.zip -Force
   Copy-Item .\downloads\Hermes-Windows-Launcher-vX.X.X.X.zip .\downloads\Hermes-Windows-Launcher.zip -Force
   ```
4. Git commit + push
5. 部署到 Cloudflare Pages：
   ```bash
   npx wrangler pages deploy . --project-name=hermes-gui-launcher-20260410 --branch=main --commit-hash=<hash> --commit-message="Release Windows launcher vX.X.X.X"
   ```

### 发版前安全检查
- 扫描 `sk-`、`api_key`、`token`、`secret`、`password` 等敏感关键词
- 确认不存在 `.env` 文件
- 确认 `.cloudflareignore` 存在且排除了内部文档

### 发版后验证（3 步）
1. 打开 hermes.aisuper.win，确认版本号已更新
2. 点下载链接，确认 zip 文件大小正确
3. 访问 hermes.aisuper.win/CLAUDE.md，确认返回 404（内部文档未泄露）

### 注意事项
- Cloudflare Pages 是手动部署（Git Provider=No），push 到 GitHub 不会自动上线
- 线上生产实际跑的是 `codex/next-flow-upgrade` 分支，部署时用 `--branch=main` 标记
- macOS 端如无改动，不需要重新打包

---

## 多 Agent 协作系统

本项目使用三角色 Agent 协作流（详见 `WORKFLOW.md`）：

| 角色 | 文件 | 职责 |
|------|------|------|
| 工程师 | `.claude/agents/engineer.md` | 实现功能 + 5 层自检 |
| 质检员 | `.claude/agents/qa.md` | 严苛评估打分（90 分门槛） |
| 整合者 | `.claude/agents/integrator.md` | 综合决策 + PM 验收清单 |

### 协作流程
1. PM 填 `tasks/0XX-*.md` 任务模板
2. 工程师读任务 → 出 A/B/C 方案 → PM 选 → 实现 → 自检 → 产出报告
3. 质检员评估 → 评分报告
4. 整合者综合决策 → 通过/返工/重做
5. 通过 → PM 5 分钟真机验收

### PM 介入节点（仅 4 处）
- 填任务模板（5-10 分钟）
- 选方案（5 分钟）
- 复制流转（30 秒 × 2）
- 真机验收（5-10 分钟）

---

## 已知陷阱清单（Known Traps）

> 每个陷阱都是过去踩过的坑。任何 Agent 开始任务前必读此清单。
> 工程师 Agent 必须在产出报告中声明"规避了哪些陷阱"。

### #1 WPF Dispatcher 异常处理

**触发条件**：WPF 应用中的异步操作 + UI 更新

**坑的表现**：Dispatcher.Invoke 异常未捕获 → 整个进程崩溃

**预防动作**：
- 所有 `Dispatcher.Invoke` / `Dispatcher.BeginInvoke` 必须 try-catch
- 异常情况下显式调用 fallback UI 路径
- 不要用 `Application.Current.Dispatcher.DoEvents()`（已知会导致重入）

**踩过日期**：2026-04-24

---

### #2 WPF ComboBox 内部 TextBox 事件绑定时机

**触发条件**：给 ComboBox 内部的 TextBox 加事件监听

**坑的表现**：控件还没渲染时绑定 → 绑定失败,事件不触发

**预防动作**：
- 用 `Add_Loaded` 事件包装绑定逻辑
- 确保控件已渲染后再绑定
- 用 `FindName` 或 `VisualTreeHelper` 安全查找内部控件

**踩过日期**：2026-04-24

---

### #3 中文 Windows 错误消息匹配

**触发条件**：基于错误消息文本判断异常类型

**坑的表现**：中文 Windows 错误消息 ≠ 英文版,字符串匹配失败

**预防动作**：
- **绝不**用错误消息文本匹配
- 用 `WebExceptionStatus` / `HResult` / 异常类型枚举
- 例：`if (ex is WebException webEx && webEx.Status == WebExceptionStatus.Timeout)`

**踩过日期**：2026-04-24

---

### #4 UI 信息位置错误（找得到 ≠ 信息存在）

**触发条件**：错误处理 / 状态提示 / 帮助信息

**坑的表现**：信息确实存在,但放在用户视线流外的位置（比如另一个面板）

**预防动作**：
- 错误信息**紧贴出错的输入框**（下方或右侧）
- 状态信息在用户当前操作的视线焦点
- 不要假设"用户会去找"——他们不会
- 5 层自检的"第 2 层用户场景"必须验证此项

**踩过日期**：2026-04-24

---

### #5 跨框架 API 替换需 UI 交互测试

**触发条件**：替换底层 API/SDK/库

**坑的表现**：静态分析全过,但 UI 交互时崩

**预防动作**：
- 不要只信单元测试
- 必须有"模拟用户操作"的集成测试
- 如果 AI 测不了,必须明确声明盲区,让 PM 真机验证

**踩过日期**：2026-04-24

---

### #6 分支管理：非 main 分支 commit 必须告知 PM

**触发条件**：Claude Code 自主选择分支

**坑的表现**：commit 到 codex/next-flow-upgrade,PM 以为发布的是 main

**预防动作**：
- 任何 commit 前必须明确告知"我要 commit 到 X 分支"
- 重要 commit（发版相关）必须等 PM 确认分支选择
- DECISIONS.md 必须记录"哪个分支是当前发布源"

**踩过日期**：2026-04-24

---

### #7 内部文档暴露 CDN

**触发条件**：Cloudflare Pages 部署

**坑的表现**：CLAUDE.md / DECISIONS.md / tasks/ 等内部文档被部署到公网

**预防动作**：
- 项目根目录必须有 `.cloudflareignore`
- 排除：`.git/`、`.claude/`、`CLAUDE.md`、`DECISIONS.md`、`TODO.md`、`tasks/`、`openspec/`、`prompts/`
- 部署前用 `wrangler pages deploy --dry-run` 检查

**踩过日期**：2026-04-24

---

### #8 版本说明匹配用户感知

**触发条件**：写发版 release notes

**坑的表现**：写"重构了内部架构",用户不关心;漏写"修复了 X 闪退",用户实际遇到的

**预防动作**：
- 发版说明从用户视角写,不是工程师视角
- 优先列"用户能感知的修复"
- 内部重构放最后或不写

**踩过日期**：2026-04-24

---

### #9 对外文档（README/官网）更新必须 sync 到 main

**触发条件**：在非 main 分支改了 README / 官网内容

**坑的表现**：GitHub 主页显示的 README 是 main 的旧版本,用户看到旧信息

**预防动作**：
- 任何对外文档改动,必须 cherry-pick 或合并到 main
- DECISIONS.md 记录"main 分支的角色：对外展示"
- 区分：
  - main：GitHub 展示用
  - codex/next-flow-upgrade：发布源

**踩过日期**：2026-04-24

---

### #10 Claude Code 自检覆盖"功能跑没跑起来",不覆盖"用户找不找得到"

**触发条件**：Claude Code 报告"测试通过"

**坑的表现**：功能确实能跑,但用户在 UI 上找不到入口/反馈/错误

**预防动作**：
- 工程师 Agent 必须诚实声明盲区
- 质检员 Agent 必须按"用户视角"复审
- 不要把"代码逻辑通过"等同于"产品可用"

**踩过日期**：2026-04-24

---

### #11 部署分支与 main 分支的 index.html 不同步

**触发条件**：从 `codex/next-flow-upgrade` 分支部署，而 main 分支的 index.html 有单独更新（如 Mac 版本号）

**坑的表现**：部署后网站上 Mac 下载区的版本号、下载链接、app 名称丢失或回退到旧版

**预防动作**：
- 部署前必须 `git diff main -- index.html` 检查两个分支的差异
- 如果 main 有 index.html 的改动（特别是 Mac 相关），先合并过来再部署
- deploy.sh 中可加入自动检查步骤

**踩过日期**：2026-04-28

---

### #12 Cloudflare Pages 手动部署不删旧资产且不读 .cloudflareignore

**触发条件**：用 `wrangler pages deploy` 手动部署（非 Git Provider 模式）

**坑的表现**：
- `.cloudflareignore` 完全无效（只在 Git 集成模式下才生效）
- 之前部署过的文件（如 CLAUDE.md）即使新部署不包含，仍然在 CDN 上可访问
- `_redirects` 无法覆盖已存在的静态文件

**预防动作**：
- 必须用 `deploy.sh`（白名单方式）部署，不直接 `wrangler pages deploy .`
- deploy.sh 里用 dummy 文件覆盖之前泄露的内部文档
- 部署后必须 `curl` 验证 CLAUDE.md 返回的不是真实内容

**踩过日期**：2026-04-28

---

### #13 依赖未就绪的外部资源上线

**触发条件**：代码依赖一个 placeholder URL / 未发布的包 / 未部署的服务

**坑的表现**：功能必定失败，用户看到的是"打不开"/"卡死"，而 SelfTest 通过因为不走那条路径

**预防动作**：
- 如果外部依赖还没就绪，代码必须有**不依赖它也能用**的降级路径
- 降级路径必须是默认路径（而不是只在 catch 里）
- 交付前必须测"用户点了主按钮会发生什么"，不只是 SelfTest
- placeholder URL 的代码不允许走到实际下载步骤

**踩过日期**：2026-04-29

---

### #14 只跑 SelfTest 不测 GUI 全流程

**触发条件**：大量删改代码后只跑 `-SelfTest` 验证

**坑的表现**：SelfTest 通过，但用户双击打开后闪退 / 主按钮不可用 / UI 卡死

**预防动作**：
- SelfTest 只覆盖非交互路径，不等于 GUI 可用
- 删改 > 100 行时，必须测一次真实 GUI 启动（窗口能打开）
- 必须模拟用户主操作路径（点主按钮、看结果）
- 如果无法在当前环境测 GUI，必须在报告中声明盲区

**踩过日期**：2026-04-29

---

### #15 安装参数重复传递导致上游脚本报错

**触发条件**：构建安装参数时混入了 PowerShell 级别参数（-ExecutionPolicy、-File），而 wrapper 脚本已经硬编码了这些参数

**坑的表现**：上游 install.ps1 收到多余的 `-ExecutionPolicy Bypass -File <路径>` 作为脚本参数，可能导致参数绑定错误或不可预测行为

**预防动作**：
- `Build-InstallArguments` 只返回脚本级参数（-InstallDir、-HermesHome 等），不返回 PowerShell 级参数
- wrapper 脚本负责 PowerShell 级参数（-NoProfile、-ExecutionPolicy Bypass、-File）
- 不要用 `$args` 作为变量名（PowerShell 保留自动变量）

**踩过日期**：2026-04-29

---

### #16 上次安装失败残留目录导致重装必定失败

**触发条件**：首次安装中途失败（依赖报错、网络断开等），留下不完整的安装目录（有文件但没有 .git）

**坑的表现**：上游 install.ps1 检测到"目录存在但不是 git 仓库"直接报错退出，用户无法重新安装

**预防动作**：
- 环境检测阶段（Test-InstallPreflight）自动检测并清理残留目录
- Python venv 会创建超过 260 字符的深层路径，普通 Remove-Item 和 rd 都删不掉（"MS-DOS 功能无效"）
- 必须用 robocopy 空目录镜像方式清理：`robocopy $emptyDir $targetDir /MIR` 再 `rd`
- 如果三种方法都失败，弹窗帮用户打开文件资源管理器定位到该目录

**踩过日期**：2026-04-29

---

### #17 安装终端闪退用户看不到报错

**触发条件**：安装脚本执行完毕，退出码为 0（上游脚本 ErrorActionPreference=Continue 时即使有报错也可能返回 0）

**坑的表现**：wrapper 脚本只在退出码非 0 时暂停，退出码 0 直接关窗口。用户看到依赖报错但来不及读内容

**预防动作**：
- 失败时（非 0）：显示中文提示 + 要求用户截图 + 按 Enter 才关闭
- 成功时（0）：也保留 5 秒并提示"如有报错请截图"，给用户缓冲时间
- wrapper 用 try/catch 包裹内部 powershell 调用，防止异常直接退出

**踩过日期**：2026-04-29

---

### #18 Windows 上 `hermes gateway run --replace` 必崩

**触发条件**：已有一个 gateway 进程在运行，启动器用 `--replace` 启动新 gateway

**坑的表现**：`--replace` 尝试读 `gateway.lock` 文件时触发 `PermissionError`（运行中的进程独占锁），新 gateway 立即崩溃。因为 `-WindowStyle Hidden`，崩溃完全不可见。旧 gateway 继续运行，启动器以为新 gateway 已启动。

**预防动作**：
- 永远不用 `--replace` 参数
- 启动器自己负责杀进程：先 `Stop-Process` 杀已知 PID，再 `Get-Process hermes` + 命令行匹配杀残留，最后删 `gateway.lock`
- 等 500ms 让 OS 释放文件句柄后再启动新 gateway
- 启动后 3 秒检查进程是否还活着

**踩过日期**：2026-04-30

---

### #19 .env 文件监控未在早期返回路径启动

**触发条件**：WebUI 已在运行，用户再次点击「开始使用」

**坑的表现**：`Start-LaunchAsync` 检测到 WebUI 健康后直接 return，跳过了 `Start-GatewayEnvWatcher`。之后用户在 webui 配置渠道时 .env 变化无人监听，gateway 永远不会重启。

**预防动作**：
- 所有返回路径（早期返回 + 状态机完成）都必须调用 `Start-GatewayEnvWatcher`
- 同时监听 Created + Changed 事件（新安装时 .env 是新建不是修改）

**踩过日期**：2026-04-30

---

### #20 Gateway API 端口与 WebUI 上游端口不匹配 → "未连接"

**触发条件**：config.yaml 中 `platforms.api_server.extra.port` 设为非 8642 的值

**坑的表现**：Gateway 在非默认端口（如 8645）上监听 API，但 hermes-web-ui 的 upstream 硬编码为 `http://127.0.0.1:8642`。WebUI 连不上 gateway → 显示"未连接"。Telegram/微信等渠道实际已连接，但用户通过 WebUI 完全无法感知。

**预防动作**：
- 启动器在启动 gateway 前检查 config.yaml 的 api_server port，自动修正为 8642
- `Repair-GatewayApiPort` 函数负责此修正
- 必须用 `[System.IO.File]::WriteAllText` + UTF-8 无 BOM 写入 config.yaml，绝不能用 PowerShell 的 `Set-Content`（中文 Windows 默认写 GBK，破坏 YAML 中的 emoji 字符导致语法错误）
- `Stop-ExistingGateway` 必须同时杀 hermes.exe 和其子进程 python.exe（从 hermes venv），否则旧进程占端口，新 gateway 无法绑定 8642

**踩过日期**：2026-04-30

---

### #21 PowerShell Set-Content 在中文 Windows 上破坏 UTF-8 文件

**触发条件**：用 PowerShell 5.1 的 `Set-Content` 写 UTF-8 文件（如 config.yaml）

**坑的表现**：`Set-Content` 默认用系统编码（中文 Windows = GBK/CP936），把 UTF-8 的 emoji 等多字节字符写坏。YAML 解析器报 "mapping values are not allowed here" 或 "invalid continuation byte"，整个 config 回退到空配置。

**预防动作**：
- 需要原样保留编码的文件（config.yaml、.env 等），用 `[System.IO.File]::ReadAllText` + `[System.IO.File]::WriteAllText` + `UTF8Encoding($false)`（无 BOM）
- 永远不要用 `Set-Content`、`Out-File` 处理非 ASCII 内容的文件
- 如果只需要简单文本替换，优先用 Python 处理

**踩过日期**：2026-04-30

---

## 自检盲区清单（Honest Limits）

> Claude Code / Codex 等 AI 工程师在自检时**无法覆盖**的方面。
> 工程师 Agent 必须在产出报告中明确声明哪些属于盲区。

### UI 类盲区
- WPF 窗口实际渲染效果
- 按钮位置 / 大小 / 颜色对不对
- 用户能否找到关键信息（找得到 ≠ 信息存在）
- 交互流畅度（响应是否在预期时间内）
- 中文显示是否乱码
- 高 DPI 屏幕的缩放表现
- 暗色/浅色主题切换

### 环境类盲区
- 真实 Windows 环境的进程行为
- 不同 Windows 版本的差异（7/10/11/Server）
- 安全软件的拦截行为（360/腾讯/卡巴/Defender）
- 网络代理/翻墙环境
- 中文路径 / 中文用户名
- 不同地区的语言环境
- 不同硬件配置的性能差异

### 体验类盲区
- 文案是否符合品牌调性
- 错误提示是否对用户友好
- 整体节奏是否合理
- 用户实际操作时的"卡住时刻"
- 视觉美感
- 长期使用的疲劳感

### 集成类盲区
- 真实 Hermes Agent 安装过程的卡点
- 真实 API key 的认证表现
- 真实网络环境下的 API 调用
- 多用户/多版本共存场景

---

## 经验沉淀强制流程（Forced Sedimentation）

> 每次踩坑或修复后必须沉淀到文档,否则任务不算完成。

### 沉淀触发条件

以下情况**必须**沉淀到 CLAUDE.md "已知陷阱清单"：

1. PM 真机测试发现工程师没测出的问题
2. 同样的错误出现两次以上
3. 质检员 Agent 发现新类型的问题
4. PM 验收时发现"AI 又犯了之前的错"
5. 任何"AI 自检通过但实际有 bug"的情况

### 沉淀格式

每条新陷阱按以下格式追加到 CLAUDE.md：

```markdown
### #编号 [简短标题]

**触发条件**：[在什么场景下会遇到]

**坑的表现**：[具体表现]

**预防动作**：[下次怎么避免]

**踩过日期**：YYYY-MM-DD
```

### 沉淀强制点

1. **工程师 Agent 完成任务前**：检查本次有没有踩到/发现陷阱
2. **质检员 Agent 评估时**：逐条核对已知陷阱,发现漏报 → 扣分
3. **整合者 Agent 决策后**：明确指出本次需要沉淀的内容
4. **PM 验收后**：发现 Agent 团队都没发现的问题 → 手动加入清单

### 不沉淀的后果

不沉淀 = 同样的坑下周再踩。**这是死规则,不是建议**。

---

## 反馈结构化模板

> PM 向 AI 反馈问题时,使用此模板。

### 标准反馈格式

```markdown
## 反馈类型
- [ ] 阻塞性 bug（影响主流程）
- [ ] 体验性问题（影响感受但不阻塞）
- [ ] 边缘场景（罕见但需要处理）
- [ ] 优化建议（非 bug）

## 1. 我做了什么（Action）
[具体操作步骤,1/2/3...]

## 2. 我期望什么（Expectation）
[基于任务文档,我期待看到什么]

## 3. 我看到了什么（Observation）
[实际发生了什么,带截图最好]

## 4. 影响范围（Impact）
- 偶发 / 必现?
- 阻塞性 / 体验性?
- 影响多少用户?

## 5. 我的猜测（可选）
```

---

## PM 介入标准（再次强调）

### PM 必须介入的：
1. 涉及多方案选择的产品决策
2. 涉及钱、品牌、合规风险的决策
3. UI 完整性的最终确认（真机看 5-10 分钟）
4. 用户视角的"舒不舒服"判断

### PM 不必介入的：
1. 代码实现细节
2. 性能调优、错误处理、边界情况
3. 自测覆盖度
4. 文档更新

### 触发 PM 介入时的格式

```markdown
## 需要 PM 介入

**事项**：[一句话]

**为什么需要 PM**：涉及 [钱/品牌/合规/产品决策/真机验收]

**我准备了什么**：
- 选项 A / B / C

**我的建议**：[选 X,理由]

**PM 需要做什么**：回复"A"/"B"/"C" 或 [具体测试步骤]

**预计 PM 投入时间**：[X 分钟]
```
