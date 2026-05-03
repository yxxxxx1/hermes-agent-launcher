# 任务:修复 PM 反馈的高优 bug + 配套回归用例

**任务编号**: 014
**创建日期**: 2026-05-03
**预计耗时**: 8-14 小时(代码定位 + 修复 + 回归用例补全 + 真机验收)
**优先级**: P0(Bug A、B)+ P1(Bug C)
**依赖前置**: Task 013 已交付,v2026.05.02.2 已上线

---

## 1. 产品目的(Product Goal)

**让 PM 不再当 QA**。每次发版后用户都能在主流程上跑通,不要再依赖 PM 真机点出工程师没测出来的 bug。

PM 在 2026-05-03 反馈:多次发版(v2026.05.02.0 → v2026.05.02.2)后仍然是 PM 真机点出问题——这代表"工程师 → 质检员 → 整合者 → PM"四道关卡里,工程师自检 + QA 评估都漏掉了真实用户场景。本任务有两个目的:

1. **修复**当前 PM 已经发现并定级的 3 个 bug
2. **建立**一套"PM 反馈驱动的回归用例库"(`testcases/`),让以后每条 PM 反馈都直接落到一条可执行回归用例,工程师自检和 QA 评估都必须逐条对照

**关键:这次任务交付物不是只修 bug,而是修 bug + 写回归用例,两者缺一不可。**

引用 `CLAUDE.md` "协作姿态":

> 你是工程师 + 测试 + 架构师,我是用户 + 产品决策者。你的活不要让我干。

工程师 agent 必须把这句话当成红线,**不允许在交付报告里出现"建议 PM 跑命令验证 / 建议 PM 排查 / 建议 PM 选方案"这类话**。

## 2. 运营目的(Business Goal)

短期:
- Bug A 修复后,Telegram / 飞书 / Slack 这类外部渠道的"配置后无回应"投诉归零(目前是核心可用性问题)
- Bug B 修复后,已安装用户每次启动从"看到一堆安装提示"回到"直接进入主面板",首次到第二次开启的体验割裂消除
- Bug C 修复后,Dashboard 失败事件中 ~20% 的 `dispatcher: FileNotFoundException` 被消化掉,失败事件占比降到 < 10%

长期:
- 建立用例库 = 后面每次 PM 反馈都自动产生一条永久回归资产
- 4-6 次迭代后,`testcases/regression/` 应该覆盖所有历史踩过的真实用户场景,工程师 agent 的自检不再是"想象通过",而是"对照已有用例打勾"

## 3. 用户视角(User View)

### 当前痛点

**Bug A:配渠道但消息无回应**
- 用户在 webui 里填了 Telegram bot token → 等了几分钟 → 给 bot 发"hi" → 没回
- 用户重启 launcher 也不一定好,因为 `.env` watcher 可能没启,gateway 可能没重启,依赖可能没装
- 用户不知道是自己 token 错了还是程序坏了,只看到"消息没回应"
- 这是当前阻塞性最高的可用性问题

**Bug B:已装机器开启动器又走一遍安装流程**
- 用户上次已经装好 hermes 并用过 webui
- 关掉 launcher,过几天再打开,看到的不是"开始使用"而是"安装/更新 Hermes"
- 用户怀疑是不是被卸载了,或者是不是每次都要重装
- 体验上像"程序记不住状态"

**Bug C:Dashboard 看到 FileNotFoundException 高频报错**
- 用户视角无感知(主流程没断),但运营/PM 视角看 Dashboard 上 ~20% 失败事件都是这个错
- 长期不修会污染遥测数据,后续 bug 排查时这个错会一直在 top,真实问题被淹没

### 期望状态

**Bug A 修复后**
- 用户在 webui 配 Telegram → 等 30-60 秒 → 给 bot 发消息 → bot 必有回应
- 如果依赖装失败,主面板看到红色横幅 + 中文提示 + 复制错误按钮(不是默默无回应)
- 不依赖 PM 在终端跑 `uv pip install`

**Bug B 修复后**
- 已装的机器双击启动器 → 主面板**直接 Home Mode**,主按钮"开始使用"可点
- 不出现"安装/更新 Hermes" / "正在检测环境" / "Install Mode 进度卡" 任何元素
- 第一次和第 N 次开启,体验完全一致

**Bug C 修复后**
- Dashboard 上 `dispatcher: FileNotFoundException` 这一族错占比降到 < 5%
- 残余的报错有明确文件路径上下文(不是裸 exception)

## 4. 成功标准(Success Criteria)

完成定义:满足以下全部条件视为通过

### 必须达成(阻塞条件)

#### 4.1 Bug A — 渠道依赖按需安装 3 条触发链加固

引用 `TODO.md` 现有条目"渠道平台可选依赖未随 hermes 安装(上游问题)"和 PM 在 2026-05-03 的明确指示,**保留按需(on-demand)路径,不做 eager pre-install**,但要让按需不会漏。

修复点:

- [ ] **`.env` watcher 加 60 秒 polling 兜底**
  FileSystemWatcher 在某些场景下不触发(防病毒拦截、跨盘符、网络盘),polling 兜底确保即使 watcher 失效,60 秒内也能感知 .env 变化并触发重启
  实现:在现有 watcher 注册旁加一个 `System.Timers.Timer`,每 60 秒读 `.env` 文件 hash,与上次比较,变化时触发与 watcher 相同的 handler
- [ ] **`Restart-HermesGateway` 在 `$script:GatewayHermesExe` 为 null 时从 InstallDir 推导,不早退**
  对应陷阱 #27:快速路径未初始化 GatewayHermesExe 时,.env 变化触发的重启会因找不到可执行文件而 silently skip。修复后必须从 `$script:InstallDir`(或默认 `%LOCALAPPDATA%\hermes\hermes-agent\Scripts\hermes.exe`)推导,推导失败再上报错误
- [ ] **`uv pip install` 失败显式上报**
  当前是 silent failure。要求:
  1. 新增 telemetry 事件 `platform_dep_install_failed`(payload: 渠道名 + uv 错误码 + 错误尾部 50 行)
  2. 主面板显示红色横幅"渠道依赖安装失败:Telegram。点这里查看详情",点击展开错误尾部 + 复制按钮
  3. 主按钮变灰,提示"渠道依赖未就绪,请先解决"
- [ ] **3 条触发链都跑过同一份 `Install-GatewayPlatformDeps`**:
  1. 首次安装结束后(主路径)
  2. `.env` watcher 触发的 `Restart-HermesGateway` 之前
  3. polling 触发的同一个 handler
  禁止有任何一条触发链跳过依赖检查

#### 4.2 Bug B — 已装机器每次启动走 install 流程

工程师必须**先定位再修**,不准瞎改。怀疑根因(三选一,工程师必须 grep 代码确认):

- [ ] 怀疑根因 1:`Test-HermesInstalled` 检测路径漂移(默认 InstallDir 与实际安装路径不一致)
- [ ] 怀疑根因 2:`Refresh-Status` L6144 附近 `(-not isInstalled) -OR pendingOpenClaw` 中 `OpenClawSources` 误判残留(老 OpenClaw 残留导致即使已装也走 install)
- [ ] 怀疑根因 3:InstallDir 默认值与实际安装路径不一致(用户改过 InstallDir 但启动器没读到 settings.json)
- [ ] 工程师必须在交付报告里**明确指出根因是哪个,grep 哪几行代码确认,改了哪几行**
- [ ] 修复后,在 6 种已装场景下都必须直接 Home Mode(见 `testcases/core-paths/TC-002` 和 `TC-005`)

#### 4.3 Bug C — Dashboard 高频 FileNotFoundException

- [ ] grep `HermesGuiLauncher.ps1` 中所有可能抛 `FileNotFoundException` 的位置(`Get-Content` / `[System.IO.File]::ReadAllText` / `Start-Process` 等),逐处加 `Test-Path` 前置检查或 try-catch 兜底
- [ ] 重点排查 `Send-TelemetryEvent` 内部和 `dispatcher` 关键字附近的代码
- [ ] 修复后跑一次 SelfTest + 真机至少打开 3 次启动器 + 触发 1 次安装,Dashboard 7 天内此族报错占比 < 5%

#### 4.4 回归用例配套

每条 bug 修复必须配套至少 1 条回归用例,放到 `testcases/regression/`:

- [ ] `testcases/regression/A-channel-deps-on-demand.md` — Bug A 的 3 条触发链各 1 条用例(共 3 条)
- [ ] `testcases/regression/B-installed-machine-home-mode.md` — Bug B 的回归用例
- [ ] `testcases/regression/C-dispatcher-filenotfound.md` — Bug C 的回归用例
- [ ] 每条用例必须按 `testcases/README.md` 定义的格式,含前置条件 / 测试步骤 / 预期结果 / 执行证据要求 / 关联陷阱

### 验证条件(真机测试)

- [ ] PM 真机抽查:`testcases/core-paths/TC-002`(已装机器进 Home Mode)+ `TC-003`(Telegram 渠道按需依赖)+ `TC-009`(WebUI 断连恢复)各跑一次,全部通过
- [ ] 工程师交付报告里**逐条用例打勾**,通过 / 未通过 / 无法本地验证三选一,后两种必须给出原因
- [ ] Dashboard 上线后观察 3 天,`dispatcher: FileNotFoundException` 占失败事件 < 5%

### 加分项(可选)

- [ ] `testcases/regression/A-channel-deps-on-demand.md` 里多写一条:"webui 直接修改 .env(不通过 webui 表单),polling 60 秒内重启 gateway"——这条是兜底场景,真机测可选
- [ ] 写一个本地脚本 `Test-RegressionAll.ps1`,自动跑所有 `testcases/regression/*.md` 中可自动化的步骤,生成报告

## 5. 边界(Boundaries)

### 这次做的

- 修复 Bug A、B、C 三个 PM 已定级的问题
- 建立 `testcases/` 目录骨架(本任务首阶段已完成)
- 写 3 条回归用例(对应 A、B、C)
- 工程师 5 层自检对照新增的核心路径用例(TC-001 ~ TC-010)逐条声明

### 这次不做的

- ❌ 改其他陷阱清单里没出过的 bug(发现就记 TODO.md,不顺手改)
- ❌ 重构 `Refresh-Status` 状态机(只在 Bug B 范围内动)
- ❌ 改 telemetry 上报字段定义(只新增 `platform_dep_install_failed` 一个事件)
- ❌ 改 webui / gateway / hermes-agent 上游代码(全是启动器侧修复)
- ❌ Phase 2 的"可用性用例摸底"(TC-001~TC-010 是骨架,后续摸底是另起任务)

### 不能动的范围

- 任何陷阱清单(#1 ~ #39)的现有修复点不能回滚
- 遥测沙化逻辑不动(011 已上线)
- deploy.sh 不动(本任务无发版)
- Mac 端代码完全不碰

## 6. 输入资源(Inputs)

### 已有资产

- `HermesGuiLauncher.ps1`(主程序)
- `TODO.md`"渠道平台可选依赖未随 hermes 安装"条目
- `CLAUDE.md`"已知陷阱清单"#18、#19、#20、#22、#23、#27、#39(全是 Bug A、B 相关)
- `testcases/README.md`(本阶段已写,工程师必读)
- `testcases/core-paths/TC-001 ~ TC-010`(本阶段已写骨架,工程师执行时填证据)

### 必须遵守的协作原则(红线)

引用 `CLAUDE.md` "协作姿态" + PM 反馈记忆的核心原则:

1. **不给 PM 选项**
   修复方向 PM 已定(保留按需 + 加固 3 条触发链 + 不 eager pre-install)。工程师不要再列 ABCD 让 PM 选。如果工程师在执行中发现修复方向不对,**先在交付报告里独立列一段"需要 PM 重新决策的点"**,不要在主交付里夹带方案变更。

2. **不给个例方案**
   不准建议 PM 跑命令绕过(例:"如果还是不行,PM 可以手动 `uv pip install python-telegram-bot`")。所有 fallback 必须在代码里实现,失败要在 UI 上有明确提示。

3. **5 层自检必须对照回归用例**
   不允许"想象通过"。每条用例必须给出**截图 / 日志 / 命令输出**作为证据(放到 `testcases/regression/<case>.md` 的"执行证据"章节,或附在工程师交付报告里)。

4. **盲区诚实声明**
   如果 agent 在 sandbox 里没法跑某条用例(例:没真实 .env watcher 行为、没中文 Windows、没国内网络),必须诚实写"我没跑过 TC-XXX,因为 sandbox 没有 X"。**不准伪造通过**。

5. **不重构,不顺手优化**
   只在本任务范围内动代码。看到别的问题记进 TODO.md。

### 已知相关陷阱(从 CLAUDE.md 摘录)

- **陷阱 #16**:残留目录(robocopy 镜像清理)— Bug B 排查需考虑安装目录残留
- **陷阱 #18**:Windows 上 `hermes gateway run --replace` 必崩 — 修复 Restart-HermesGateway 时不能用 `--replace`
- **陷阱 #19**:.env 文件监控未在早期返回路径启动 — Bug A 的根因之一
- **陷阱 #20**:Gateway API 端口与 WebUI 上游端口不匹配 — TC-009/010 用到
- **陷阱 #21**:PowerShell Set-Content 在中文 Windows 上破坏 UTF-8 — 写 .env / config.yaml 时严防
- **陷阱 #22**:WebUI GatewayManager 30 秒超时 — TC-009 用到
- **陷阱 #23**:Gateway 未就绪时启动 WebUI — Bug A 修复时要加 health 等待
- **陷阱 #27**:快速路径不等 Gateway 健康 + 不初始化 GatewayHermesExe — **Bug A 修复点 #2 直接对应**
- **陷阱 #29**:任务文档的事件清单可能与实际代码 hook 点不匹配 — Bug A 加新事件 `platform_dep_install_failed` 时,工程师必须 grep 确认埋点位置确实会被走到
- **陷阱 #37**:交付报告里"对 PM 的部署提示"≠"已经实现的自动化" — 工程师不准把"PM 记得跑 X"写进报告就声称完成,必须 commit 到代码或 README 才算
- **陷阱 #39**:venv python.exe 在 Windows 上是 stub launcher — 修复 Restart-HermesGateway 杀进程时必须用 CommandLine 而非 Path 过滤

### PM 反馈记忆中的核心原则

(以下两条是 PM 在过往多次反馈中沉淀的元规则,工程师必须当成红线,不论这两条原则是否已经存在 memory 文件)

- **systemic fix, not workaround**:出问题不准给 PM "下次绕一下" 的临时方案,必须从代码层面消除根因
- **no options just execute**:PM 已经拍板的方向,工程师执行,不再列 ABCD

## 7. 期望产出(Deliverables)

### 文件层

- 修改 `HermesGuiLauncher.ps1`:Bug A、B、C 三处修复(具体行号由工程师定位后填)
- 新增 `testcases/regression/A-channel-deps-on-demand.md`(3 条用例)
- 新增 `testcases/regression/B-installed-machine-home-mode.md`
- 新增 `testcases/regression/C-dispatcher-filenotfound.md`
- 修改 `testcases/core-paths/TC-001 ~ TC-010` 中每条的"执行证据"章节(工程师能跑的用例填证据,跑不了的诚实声明盲区)
- 不动 deploy.sh、不动 worker、不动 dashboard 前端

### 验证层

- 工程师 5 层自检报告,**对照 TC-001 ~ TC-010 + 3 条回归用例,逐条打勾 + 证据**
- 质检员 agent 评估报告(对照 90 分门槛)
- 整合者 agent 综合决策(通过 / 返工 / 重做)
- PM 真机验收清单:TC-002 + TC-003 + TC-009 三条,< 10 分钟跑完

### 学习层

- `DECISIONS.md` 新增条目:为什么保留按需依赖安装而不做 eager pre-install(PM 拍板)
- `TODO.md` 不新增渠道相关条目(本任务已闭环);如本任务执行中发现新坑,新增条目
- 如有新陷阱(例:本任务发现 polling timer 与 watcher 双触发的并发问题),按 CLAUDE.md 强制沉淀流程加进陷阱清单(下一个编号 #40)

## 8. 决策点(Decision Points)

### 必须 PM 决策的点

(本任务 PM 已经在任务书里拍板,默认无新决策点。工程师执行中如遇真实分歧,必须独立列出而不是夹带在主交付里)

1. (无 — 修复方向已定)

### AI 自主决策(不打扰 PM)

- 代码具体行号修改(包括 Bug B 根因定位)
- polling timer 间隔具体值(60 秒是上限,工程师可以选 30-60 秒)
- `platform_dep_install_failed` 事件的 payload 字段名(只要包含渠道名 + 错误码 + 错误尾部即可)
- 红色横幅 UI 具体位置(主面板顶部或底部)
- 回归用例的"执行证据"如何组织(截图放哪个目录、日志命名规则等)

---

## 备注

### 与 Phase 2 "可用性用例摸底"的关系

`testcases/core-paths/TC-001 ~ TC-010` 已在本任务首阶段写出骨架,但**没有填执行证据**。工程师在本任务中:

- 能跑的(TC-002 / TC-005 / TC-006 / TC-010 等不依赖特殊环境的)→ 跑 + 填证据
- 跑不了的(TC-001 干净 VM / TC-007 中文用户名 / TC-008 国内网络等)→ 诚实声明盲区,不填证据
- Phase 2 摸底是另起任务,届时把跑不了的用例补全 + 扩展更多用例

**本任务不要求把 TC-001 ~ TC-010 全部填满证据**,但要求工程师诚实声明每条的状态。

### 工程师 agent 启动顺序建议

1. 读 `CLAUDE.md` 已知陷阱清单(全文,不跳)
2. 读本任务书(逐节)
3. 读 `testcases/README.md` 用例库格式
4. 读 `testcases/core-paths/TC-001 ~ TC-010`(知道用例怎么写)
5. 出修复方案(Bug A、B、C 各自的代码定位 + 修改行号)
6. 实施代码修改
7. 写 3 条 regression 用例
8. 跑 SelfTest + 能跑的 core-paths 用例 + 3 条 regression 用例
9. 写自检报告(逐条用例打勾 + 证据 / 盲区声明)
10. 报告提交,等质检员 agent 评估
