# 任务:启动器匿名遥测系统(v1)

**任务编号**: 011
**创建日期**: 2026-05-01
**预计耗时**: 6-10 小时(启动器埋点 + Cloudflare Worker + D1 + 简易看板)
**优先级**: P1

---

## 1. 产品目的(Product Goal)

让产品**听见自己**——把"装失败的人去哪了、卡在哪一步、为什么"这件事从黑盒变成数据。

当前我们对真实安装情况一无所知:
- 不知道每天多少人下载启动器
- 不知道多少人最终装成功并真在用
- 不知道失败的人卡在哪、报什么错

没有这些数据,迭代就是在猜。这个任务装上"听觉",让后面所有产品决策都有数据支撑。

## 2. 运营目的(Business Goal)

短期:
- **量化产品健康度**:每天活跃数、安装转化率、各步骤流失率
- **定位高频卡点**:数据驱动下一轮迭代,而不是"凭感觉哪里要改"
- **验证修复效果**:每次发版后能看到"卡在 X 步的用户从 30% 降到 8%"

长期:
- 数据沉淀成"AI 自我升级"的输入
- 高频失败原因 → 自动建议下一轮迭代任务
- 建立"用户在用什么版本、装在什么环境"的全局视图

## 3. 用户视角(User View)

### 当前痛点
- 用户:无感(纯后台埋点)
- PM:**完全瞎飞**——只能靠用户群偶尔的反馈猜产品状态

### 期望状态
- 用户:无感(只在首次启动看到一句"我们会上报匿名安装数据帮助改进产品,可在设置里关闭",30 字以内,不打扰)
- PM:每天能看到一份「健康度看板」——多少人开,多少人成,多少人失败,失败在哪

## 4. 成功标准(Success Criteria)

完成定义:满足以下全部条件视为通过

### 必须达成(阻塞条件)
- [ ] 启动器在关键节点埋点上报(下文事件清单)
- [ ] 启动器首次启动展示一次性"匿名数据收集"提示,默认开启,可在「关于」/「设置」里关闭
- [ ] 启动器中实现 `Send-Telemetry` 函数,异步、容错(网络失败不阻塞 UI、不报错弹窗)
- [ ] 设备生成稳定匿名 UUID(本地存储,首次生成),不包含任何身份信息
- [ ] Cloudflare Worker 接收 POST /api/telemetry,写入 D1 数据库
- [ ] D1 表结构合理,支持后续 SQL 查询(独立用户数、漏斗转化率、失败原因分布)
- [ ] 错误信息上报前自动脱敏:API Key、用户名、本地路径全部替换为占位符
- [ ] 简易看板 HTML 页面(部署在同 Cloudflare Pages),可通过 SQL 查到当日基础指标
- [ ] 看板有最低限度的鉴权(密码或简单 token),不公开访问
- [ ] 上报失败时不弹窗、不阻塞,只写本地日志
- [ ] 整套基础设施免费(在 Cloudflare 免费额度内)

### 验证条件(真机测试)
- [ ] 在 Windows 10/11 上启动启动器,首次提示正常显示
- [ ] 走完整安装流程一次,能在 D1 看到事件序列(opened → wsl2_check → hermes_install_start → hermes_install_completed → first_chat 等)
- [ ] 关掉数据上报开关后,后续操作不再上报
- [ ] 断网状态下启动器正常运行(不报错、不卡顿)
- [ ] 触发一次安装失败(故意填错 API Key),失败事件 + 脱敏后的错误信息正确入库
- [ ] 看板能显示当日活跃用户数、各步骤转化率、错误类型 top 3

### 加分项(可选)
- [ ] 看板加上趋势图(过去 7 天)
- [ ] D1 自动按月分表(防数据量爆炸)
- [ ] 启动器异常崩溃时,在下次启动时补传上次的 crash 事件

## 5. 边界(Boundaries)

### 这次做的
- Windows 版启动器(`HermesGuiLauncher.ps1`)埋点 + 首次提示 + 设置开关
- Cloudflare Worker 接收 + D1 存储
- 极简看板(单页 HTML,SQL 查询直查)
- 隐私文案:写一份简短的"我们收集什么、不收集什么"放在「关于」对话框

### 这次不做的
- ❌ Mac 版启动器埋点(下个迭代)
- ❌ 复杂仪表盘(用 D1 控制台或简单 SQL 凑合先)
- ❌ 用户行为画像/个性化推荐
- ❌ 实时告警(数据异常 PM 自动收到通知)
- ❌ A/B 测试基础设施

### 不能动的范围
- 不修改启动器核心安装/配置流程
- 不影响已发布版本的用户体验
- 不增加启动器启动时间(异步埋点,主线程不等)
- 上报代码失败必须静默处理,绝不抛异常给用户

## 6. 输入资源(Inputs)

### 已有资产
- `HermesGuiLauncher.ps1`(主启动器,5500+ 行 WPF)
- 现有日志机制(`Write-Log` 等)
- 已用 Cloudflare Pages(`hermes.aisuper.win`),延伸 Worker + D1 在同一账号下
- `deploy.sh` 部署脚本(可扩展)
- 现有任务/Agent 协作流(WORKFLOW.md)

### 必须遵守的协作原则
- 工程师 Agent:走 5 层自检
- 质检员 Agent:重点验证「隐私脱敏到位」「失败容错不打扰用户」「免费额度不超」
- 整合者 Agent:综合决策时优先考虑用户隐私和数据可信度

### 已知相关陷阱(从 CLAUDE.md 摘录)
- **陷阱 #1**:WPF Dispatcher 异常处理 → `Send-Telemetry` 必须全程 try-catch,绝不能让上报失败影响 UI 主流程
- **陷阱 #4**:UI 信息位置错误 → 首次"匿名数据上报"提示必须显眼但不抢戏(非弹窗、非阻塞,放主界面顶部小字带关闭按钮)
- **陷阱 #7**:内部文档暴露 CDN → 看板部署时确保 `.cloudflareignore` 排除所有内部文档,且看板自身有鉴权
- **陷阱 #21**:Set-Content 编码 → 写本地匿名 ID / 设置文件时必须用 UTF-8 无 BOM
- **陷阱 #12**:Cloudflare 手动部署不删旧资产 → 看板部署也用白名单方式(走 deploy.sh)

## 7. 期望产出(Deliverables)

### 文件层
- 修改 `HermesGuiLauncher.ps1`:新增 `Send-Telemetry` / `Get-OrCreateAnonymousId` / `Show-FirstRunTelemetryConsent` / `Toggle-TelemetryEnabled` 等函数;在关键节点(全部见下文事件清单)插入埋点调用
- 新建 `worker/telemetry-worker.js`:Cloudflare Worker 接收逻辑
- 新建 `worker/schema.sql`:D1 表结构 DDL
- 新建 `worker/wrangler.toml`:Worker 部署配置
- 新建 `dashboard/index.html`:极简看板
- 修改 `deploy.sh`:增加 Worker 部署 + 看板部署步骤
- 升级版本号到 `v2026.05.01.1`(发版前)
- 更新 `README.md`:简单提"启动器收集匿名安装数据,可在设置里关闭"
- 更新 `index.html`(下载页):同步版本号 + 简短隐私说明

### 数据层
- D1 数据库 schema:`events` 表(event_name, anonymous_id, version, os_version, timestamp, properties JSON, ip 哈希前 8 位用于地理粗粒度统计)
- 索引:event_name + timestamp、anonymous_id + timestamp

### 验证层
- 工程师产出报告(标准格式)
- 质检员评估报告(评分 + 问题清单),重点核对脱敏覆盖率
- 整合者决策报告(最终决定 + PM 测试清单)
- PM 真机验收记录

### 学习层
- DECISIONS.md 追加:
  - "2026-05-01:启动器接入匿名遥测,Cloudflare Worker + D1,默认开启 + 可关闭。这是产品健康度可观测性的第一块基础设施"
  - 记录隐私边界(收集什么/不收集什么)
- TODO.md 追加:
  - v2 待办:Mac 版埋点
  - v2 待办:可视化看板(Grafana / Metabase / 自建 React)
  - v2 待办:数据异常自动告警
- 如踩到新陷阱:加入 CLAUDE.md 已知陷阱清单(本任务大概率会踩到 Worker 鉴权、D1 schema 设计、PowerShell 异步上报这几块的坑)

## 8. 决策点(Decision Points)

### 已 PM 决策(直接落地,不用再问)

#### 决策 A:隐私姿态 → **默认开启 + 设置可关 + 首次小提示**
- 启动器首次启动时,顶部显示一行小字提示:"我们会上报匿名安装数据帮助改进产品,可在「关于」里关闭",带 [✓ 知道了] 按钮关闭
- 在「关于」对话框中加 toggle:[✓] 启用匿名数据上报
- 隐私文案要写明"收集什么、不收集什么",放「关于」中

#### 决策 B:数据粒度 → **中版**
收集:
- 事件名 + 时间戳
- 启动器版本号
- Windows 版本(简化:只取 Win10 / Win11 / Server 大类)
- 内存大小(粗粒度:< 8GB / 8-16GB / > 16GB)
- 错误类型(枚举:network_timeout / disk_full / wsl2_unavailable / model_validation_failed / 其他)
- 错误的关键技术细节(脱敏后)

不收集:
- 具体 Windows 版本号、机器型号、CPU 型号
- 用户名、机器名、本地路径
- API Key、token、密码任何敏感字段
- IP 地址(只保留哈希前 8 位用于地理粗粒度,无法反推具体 IP)

#### 决策 C:错误信息脱敏 → **自动脱敏 + 保留错误类型 + 最后 5 行调用栈(脱敏后)**
- 一律 mask 掉:`sk-*`、`api_key`、`token`、`password`、`secret`、用户名(从 `$env:USERNAME` 提取后替换)、本地路径中的用户名段
- 保留:错误类型、关键技术细节(URL host 不带 query、HTTP 状态码、超时秒数等)
- 调用栈:只保留最后 5 行,且每行经过同样脱敏过滤

### 工程师 Agent 在产出方案时给 PM 选

#### 决策 D:事件清单是否够用?
工程师 Agent 给一份完整事件清单(默认下文这版,工程师可补充):

**会话级**
- `launcher_opened` —— 每次启动器打开
- `launcher_closed` —— 每次正常关闭(带停留时长)

**安装漏斗(关键路径)**
- `wsl2_check` —— 检测 WSL2(pass/fail)
- `wsl2_install_started` —— 触发 WSL2 安装
- `wsl2_install_completed` / `wsl2_install_failed`(带 reason)
- `dependencies_check` —— 检测 Python / uv 等
- `hermes_install_started`
- `hermes_install_step` —— 进入某一步(step name)
- `hermes_install_completed` / `hermes_install_failed`(带 reason + step name)
- `model_config_started`
- `model_config_validated` / `model_config_failed`(带 provider type)

**使用层**
- `webui_started`
- `first_conversation` —— 用户的第一次对话
- `feedback_button_clicked`(若 008 反馈按钮也在这版做)

**异常**
- `crash`(带脱敏的调用栈)
- `unexpected_error`(常规 catch 触发,带 reason)

PM 看完后:确认 / 增删 / 调整

#### 决策 E:看板鉴权方式
工程师 Agent 给 PM 选:
- A. 简单密码(URL 参数 `?token=xxx`,工程师写在配置)
- B. Cloudflare Access(更正规,但配置麻烦)
- C. Basic Auth(浏览器原生弹窗)

默认建议 C(简单 + 浏览器原生支持 + Cloudflare Worker 内一行代码搞定)

### AI 自主决策(不打扰 PM)
- D1 表结构具体字段类型 / 索引设计
- Worker 内具体路由结构 / 中间件
- 启动器埋点调用的代码风格 / 命名
- 看板 SQL 查询具体写法
- 异步上报的具体实现(后台 PowerShell job vs Runspace)
- 文件系统中匿名 ID 的存储位置(`%APPDATA%\HermesLauncher\anonymous_id` 之类)

---

## 备注

**这是 011 任务**,沿用多 Agent 协作流(engineer → qa → integrator → PM 真机验收)。

特别注意:
- 这次大头是 Cloudflare Worker / D1 / 看板这三块**新基础设施**——工程师 Agent 在动手前应当先确认是否已经熟悉 Cloudflare 生态,否则要分阶段(第一阶段先把启动器埋点做完,把数据写本地 JSON 即可看到效果;第二阶段再上 Cloudflare)
- **隐私是这个任务的第一红线**——任何质检评分中"脱敏不全"扣分必须重过其他指标
- 真机验证时,PM 必须特别盯:用户是否能"找到关闭开关",和"关闭后是否真的不上报"
