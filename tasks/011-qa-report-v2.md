# 质检员评估报告(第二轮)— 任务 011

## 任务编号
011 — 启动器匿名遥测系统(v1)— 返工后复审

## 总评分:94.5 / 100 ✅

| 维度 | 第一轮 | 第二轮 | 满分 | 变化 |
|------|--------|--------|------|------|
| 基础可用性 | 37 | **39** | 40 | ↑ +2(P0 三项全解) |
| 用户体验 | 25 | **28** | 30 | ↑ +3(F4 对比度 / F5 视觉反馈) |
| 产品姿态 | 15 | **18** | 20 | ↑ +3(暖色规范留 v2 已批准) |
| 长期质量 | 8 | **9.5** | 10 | ↑ +1.5(对抗测试回灌 + WORKFLOW 沉淀) |

**90 分门槛:通过**(94.5 / 100,远超门槛)。

---

## P0 三项解除情况

### ✅ P0-1 脱敏漏洞 → **完全解除**

**亲眼验证** — 我又写了**全新一批 20 个对抗 case**(`Test-QAv2Adversarial.ps1`,工程师没看过的),实测结果:

```
QA-v2: Total 20  Passed 19  Failed 1
```

**通过的 19 个真实场景**:
- GitHub PAT mid-sentence、URL 内 AIza key、IPv6 with port bracket `[2001:db8::cafe:1]:8080`
- URL-encoded lowercase `c%3a%5cusers%5c74431` → `c:\users\<USER>`
- JSON 各种变体(api-key 连字符、apikey 大写、双引号 / 单引号 / 无引号)
- 多 GitHub token 同行、Bearer multiline、IPv6 loopback `::1`、AIza 短串(<30 不误吃)
- **中文用户名** `C:\Users\张三\` → `<USER>`(关键!中国用户都用中文用户名)
- 多种正反误判防线:Hex hash 不被吃成 IP、`%XX` 在普通数据中保留、版本号 `gh*_short` <20 不误删

**1 个 false positive**:`dotnet 6.0.1.4 build` → `dotnet <IP> build` —— 这是 IPv4 正则在 v1 已存在的老行为(`\b\d{1,3}.\d{1,3}.\d{1,3}.\d{1,3}\b`),**不是本次返工新引入**。属于**轻度可用性问题**(误把版本号当 IP),不是隐私漏洞。建议加进 TODO.md 当 v2 待办,**不阻塞通过**。

**工程师跑过的两套测试结果我也复跑确认**:
- `Test-QASanitizeEdgeCases.ps1`: **16/16 通过**(原来 11/16)
- `Test-TelemetrySanitize.ps1`: **21/21 通过**(原来 16/16,工程师把 QA 5 个对抗 case 回灌进来了)

**结论**:任务文档"第一红线"达标。脱敏正则**经得起新对抗测试**,不是为通过测试而通过。

### ✅ P0-2 zip 未打包 → **完全解除**

实测验证:
```
$ ls -la downloads/Hermes-Windows-Launcher-v2026.05.01.6.zip
58180 bytes — present (60K)

# Positive path:
$ bash Test-DeploySelfCheck.sh
OK: launcher v2026.05.01.6 zip is present (60K)
OK: index.html references v2026.05.01.6
ALL CHECKS PASS

# Negative path (我故意把 zip 改名):
$ bash Test-DeploySelfCheck.sh
ERROR: downloads/Hermes-Windows-Launcher-v2026.05.01.6.zip not found.
exit=1
```

deploy.sh 起手三检(版本号提取 / zip 存在 / index.html 引用一致)在我手里**正向 + 反向**都按预期工作。下一次再忘打包,deploy.sh 起手就拒绝继续。

### ✅ P0-3 endpoint 硬编码 → **完全解除**

三处同步实测:
- `worker/wrangler.toml`:`[[routes]] pattern = "telemetry.aisuper.win/*" custom_domain = true` ✓
- `HermesGuiLauncher.ps1:43`:`https://telemetry.aisuper.win/api/telemetry` ✓
- `dashboard/index.html:164`:`const DEFAULT_ENDPOINT = 'https://telemetry.aisuper.win';` ✓
- `dashboard/index.html:193-194`:promptForCfg 第一参数提示"默认 https://telemetry.aisuper.win,按回车即可",第二参数 `existing.endpoint || DEFAULT_ENDPOINT` ✓

**前提合理**:工程师正确识别 `aisuper.win` zone 已在同一 Cloudflare 账号下(hermes.aisuper.win 已用 Pages),`custom_domain=true` 会自动创建 DNS,**PM 不需要去 Cloudflare DNS 控制台手动操作**。

---

## P1 五项解除情况

### ✅ P1-1 关于按钮对比度 → **完全解除**

`HermesGuiLauncher.ps1:2755`:`Foreground="#E2E8F0" BorderBrush="#475569"`
- 与标题"Hermes Agent" 文字同色(`#E2E8F0`),视觉一致
- WCAG 计算:`#E2E8F0`(L≈0.81)vs `#111C33` 背景(L≈0.013)→ 对比度 ≈ 14.4:1,**超 WCAG AAA(7:1)**

### ✅ P1-2 关闭遥测视觉反馈 → **完全解除**

四处一致(`HermesGuiLauncher.ps1:4448-4498`):
- XAML:`<StackPanel>` 包裹 `CheckBox + AboutTelemetryStatus`,布局正确
- 控件字典:`AboutTelemetryStatus` 已注册到 `$aboutControls`(L4468)
- 初始状态:根据 `IsChecked` 设置文字 + 颜色(开启=`#86EFAC` 浅绿,关闭=`#FCA5A5` 浅红)
- Checked / Unchecked handler:同步切换文字 + 颜色(L4483-4498)
- **Bonus**:工程师明确避免 `GetNewClosure()` 嵌套,援引 DECISIONS.md L82 任务 002 历史经验,与已工作的 `AboutCloseButton.Add_Click` 同模式

### ⏭ P1-3(暖色规范迁移)/ P1-4(嵌套 hashtable)/ P2-1(worker 守卫)/ P2-2(launcher_closed sleep)→ 留 v2

整合者批准,工程师已加进 TODO.md 第 9-12 条 v2 待办。**接受**。

### ⚠ P1-5 报告 760×560 vs 实际 560×560 → **未明确修复**

工程师返工报告里没提这个不一致,实际 XAML 一直是 560×560(对话框正常显示),不影响交付,但下次报告希望严谨。**轻微扣分,不阻塞**。

---

## 加分项观察(返工最亮眼的部分)

### 🌟 F1b 把对抗 case 回灌进正向测试 — 流程级改进

`Test-TelemetrySanitize.ps1` 从 16 case 升级到 21 case:
- 后 5 个 case 是从 QA 第一轮对抗测试集**回灌**的:GitHub PAT、Google AIza、IPv6、URL-encoded path、JSON-style password
- 这意味着以后**任何工程师改 Sanitize 函数**都会自动跑这 21 个 case → **防回归到位**
- 这是整合者**没要求**的额外工作,工程师主动做的

### 🌟 WORKFLOW.md 新增"红线要求专项流程" — 流程治理级提升

工程师把第一轮 QA 流程的核心经验沉淀为永久协作规则:
- 任务文档标"第一红线"的,工程师必须提供**正向单元测试 + 对抗性测试**
- 质检员**独立**写对抗测试,不参考工程师的(避免确认偏差)
- 红线扣分**独立卡通过**,与其他维度无关(把任务 011 任务文档 L232 的判定逻辑写进协作章程)

**意义**:任何未来"第一红线"任务都享受双对抗测试保护,这是 011 任务**最大的副产品**。

### 🌟 4 个陷阱完整沉淀进 CLAUDE.md(#28-#31)

- #28 HttpClient PostAsync fire-and-forget 进程退出中断(工程师沉淀)
- #29 任务事件清单与代码 hook 不匹配(工程师沉淀)
- #30 硬编码外部服务 URL → PM 必须改代码(QA 沉淀)
- #31 发版前必须先打 zip 才能 deploy(QA 沉淀)

每条都有明确"触发条件 / 坑表现 / 预防动作 / 踩过日期",符合 CLAUDE.md 沉淀格式。

### 🌟 deploy.sh 自检超出最低要求

不仅检查 zip 存在,还检查 index.html 是否引用了**对应版本**。任何"忘改 index.html 链接但忘打 zip"的混合错误都会被拦截。

### 🌟 dashboard 默认值 + 提示语优化 PM 体验

prompt 提示文案改成"默认 https://telemetry.aisuper.win,按回车即可"——PM 第一次访问看板只需输 token,不需要复制粘贴 endpoint。**符合 CLAUDE.md 协作姿态"PM 不必跑命令查字段"原则**。

### 🌟 诚实声明 4 个新盲区

- 高 DPI 屏幕按钮可见度
- AboutTelemetryStatus 快速切换 race
- wrangler custom_domain 自动 DNS 是否真不需要 PM 手动
- SSL 证书签发时间

每条都给了"为什么我测不到 + PM 应该怎么验证"。**不是甩锅,是结构化交底**。

---

## 新发现的问题(P2 级别,不阻塞)

### P2-A IPv4 正则误吃版本号

`Sanitize-TelemetryString` L259 的 IPv4 正则会把 `dotnet 6.0.1.4` 中的 `6.0.1.4` 误吃成 `<IP>`。这是 v1 已存在的老问题,**不是本次返工新引入**。但实际场景中:
- `model_config_failed` 异常 message 经常包含 .NET 版本号
- Dashboard 看板上"失败原因 Top10"会出现 `Hermes runtime <IP> not supported` 这种乱码

**建议**:加进 TODO.md v2 待办,正则改成 `\b(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])\b`(后跟非数字非点)。

**优先级**:中。dashboard 数据噪音,不影响隐私。

### P2-B ALLOWED_ORIGINS 含未存在域名

`worker/wrangler.toml:16`:`ALLOWED_ORIGINS = "https://hermes.aisuper.win,https://hermes-dashboard.aisuper.win"` —— 第二个域名当前未启用(dashboard 实际部署在 `hermes.aisuper.win/dashboard/`)。

**影响**:无害,只是冗余白名单。**不扣分**。可在 v2 顺手清理。

### P2-C 工程师返工报告中"760×560"未纠正

整合者第二轮 review 没强制要求改,工程师也没主动改。**不阻塞**,下次报告希望严谨。

---

## 已知陷阱二轮核对

| # | 陷阱 | v2 状态 | 备注 |
|---|------|---------|------|
| 1 | WPF Dispatcher 异常处理 | ✅ | 未动核心逻辑,仍合规 |
| 4 | UI 信息位置错误 | ✅ | F5 把状态反馈紧贴 CheckBox 下方,**比 v1 更好** |
| 7 | 内部文档暴露 CDN | ✅ | deploy.sh 守卫 + .cloudflareignore 双保险沿用 |
| 12 | Cloudflare 部署不删旧资产 | ✅ | 沿用白名单 + dummy 文件 |
| 21 | Set-Content 编码破坏 UTF-8 | ✅ | 本次返工无新写盘路径 |
| 13 | 依赖未就绪外部资源上线 | ✅ | F2 zip 自检 + F3 自定义域名双重闭环 |
| 14 | 只跑 SelfTest 不测 GUI | ✅ | 工程师明确 4 个 PM 真机验收点 |
| **#28** | HttpClient fire-and-forget 中断 | ✅ 新沉淀 | 已加 CLAUDE.md |
| **#29** | 事件清单与 hook 不匹配 | ✅ 新沉淀 | 已加 CLAUDE.md |
| **#30** | 硬编码外部 URL | ✅ 新沉淀 + 闭环 | 已加 CLAUDE.md + F3 修了 |
| **#31** | 发版必须先打 zip | ✅ 新沉淀 + 闭环 | 已加 CLAUDE.md + F2 修了 |

---

## 工程师 4 个新盲区合理性核对

| 盲区 | QA 评估 |
|------|---------|
| 高 DPI 按钮可见度 | **合理**。我代码层判 14:1 对比度足够,但 200%+ 缩放下小字模糊确实可能影响,需真机看 |
| AboutTelemetryStatus 快速切换 race | **轻度过度声明**。WPF UI 线程串行,理论安全;`Set-TelemetryEnabled` 同步写盘最坏情况是重复写,无数据 race。声明不扣分 |
| wrangler custom_domain 自动 DNS | **合理**。基于 Cloudflare 文档 + zone 已托管的假设。第一次部署可能需要 PM 在 wrangler 提示时按 Y 确认,这是合理交底 |
| SSL 证书签发时间 | **合理**。Cloudflare 自动签发但有 30 秒 - 1 分钟延迟,PM 部署后立即 curl 可能 SSL 错。明确告知 PM 等一会儿再测,负责任 |

**结论**:4 个盲区**全部合理**,不是甩锅,是真实交底。

---

## 给整合者 Agent 的最终建议

**通过(94.5 / 100,远超 90 分门槛)**。

**核心理由**:
1. **P0 三项全解** —— 我用 20 个**新对抗 case** 复测,F1 经得起 over-fit 检验;F2 + F3 实测正反向都 OK
2. **P1 主修两项(F4 / F5)全解** —— WCAG AAA 对比度 + 视觉反馈四处一致
3. **P1 留 v2 三项** —— 整合者已批准,TODO.md 已加,不阻塞
4. **超出预期的流程级改进** —— F1b 对抗 case 回灌 + WORKFLOW.md 红线流程沉淀,**这是这次返工最大的价值**
5. **4 个陷阱完整沉淀** —— 未来同类任务直接受益

**未阻塞的轻微问题**:IPv4 误吃版本号(v1 老问题)、ALLOWED_ORIGINS 冗余、报告 760×560 偏差 —— 都进 TODO.md / v2 待办即可。

**不需要再返工**。直接走 PM 5-10 分钟真机验收。

---

## 给 PM 的真机验收清单(原整合者清单 + QA 二轮强化)

5 步,5-10 分钟:

1. **打开启动器** → 顶部出现 banner "我们会上报匿名安装数据..." + 「✓ 知道了」按钮。点击 → banner 消失。**关启动器再开** → banner 不再出现 ✓
2. **点窗口右上角"关于"** → 注意按钮**应该清晰可见**(F4 修复点,#E2E8F0 文字 + #475569 边框)。点击 → 弹出关于对话框,显示 `Windows v2026.05.01.6` + 收集/不收集说明 + CheckBox + 下方一行**绿色** "✓ 已开启 — 感谢帮助我们改进产品"
3. **取消勾选 CheckBox** → **绿色文字应立即变红** "已关闭 — 我们不会再上报数据"。这是 F5 修复点,**视觉反馈不依赖日志区**
4. **关闭 / 重开关于** → CheckBox 状态保持(持久化生效),状态文字也对应正确颜色
5. **断网状态下做一次"开始使用"** → 启动器**不应有任何卡顿、错误弹窗、闪退**

**Cloudflare 部署清单已替换到 011-engineer-report.md**(整合者要求 PM 只看一份),关键变化:
- 步骤 0(必做)先打 zip
- 步骤 8 改 `wrangler deploy` 后第一次会自动绑 `telemetry.aisuper.win` DNS,**PM 不再需要手动改启动器代码**
- 步骤 9 dashboard 默认值已是 `telemetry.aisuper.win`,prompt 按回车即可

**SSL 注意**:`wrangler deploy` 后,SSL 证书签发可能需要 30 秒-1 分钟。如果立即 `curl https://telemetry.aisuper.win/health` 报 SSL 错,等 1 分钟再试。

---

## 我自己的对抗测试残留

我创建了 `Test-QAv2Adversarial.ps1` 在 worktree 根目录,20 个新对抗 case。这份文件按 WORKFLOW.md "红线要求专项流程"原则**保留为长期防线**,未来任何工程师改 Sanitize 函数都应跑这一份 + Test-QASanitizeEdgeCases + Test-TelemetrySanitize 三份测试(**56 个 case 同时通过 = 红线达标**)。

---

## 最终评分明细

```
基础可用性 39 / 40
  - 不闪退/不崩溃         10/10
  - 主流程跑通             9.5/10  (扣 0.5: ALLOWED_ORIGINS 冗余 + IPv4 误吃版本号 v1 老问题未声明)
  - 错误信息用户可见       10/10
  - 没破坏其他功能         9.5/10  (扣 0.5: 新代码 +34 行入侵风险极低,但 SelfTest 是非交互覆盖)

用户体验 28 / 30
  - 信息找得到             9.5/10  (F4 修后明显提升,扣 0.5: 高 DPI 真机未验)
  - 文案清晰              10/10
  - 操作流畅              8.5/10   (扣 1.5: launcher_closed 600ms sleep 留到 v2,关闭 toggle 视觉反馈无动画过渡)

产品姿态 18 / 20
  - 符合品牌调性          8/10     (扣 2: banner/about 仍深蓝色调,未跟暖色规范——已批准留 v2)
  - 不增加认知负担        10/10

长期质量 9.5 / 10
  - 代码可维护            5/5     (脱敏函数集中,deploy.sh 自检清晰,F1b 防回归)
  - 文档同步              4.5/5   (扣 0.5: 工程师返工报告未纠正 760×560 偏差)

总计:39 + 28 + 18 + 9.5 = 94.5 / 100  ✅ 通过
```

返工后表现优异。**建议整合者直接判定通过,移交 PM 真机验收**。
