# 质检员评估报告 — 任务 011

## 任务编号
011 — 启动器匿名遥测系统(v1)

## 总评分:85 / 100

| 维度 | 得分 | 满分 | 备注 |
|------|------|------|------|
| 基础可用性 | 37 | 40 | 代码可跑,但部署陷阱 + 端点硬编码 |
| 用户体验 | 25 | 30 | 关于按钮对比度差,关闭无视觉反馈 |
| 产品姿态 | 15 | 20 | 启动器内 UI 未跟 LauncherPalette 暖色规范 |
| 长期质量 | 8 | 10 | 脱敏覆盖不全,文档与代码描述存在偏差 |

## 是否通过 90 分门槛?

**否(85 / 100)**。

**P0 阻塞问题至少 3 项**(其中 1 项命中任务文档第一红线"隐私脱敏",这一项独立卡住通过,与其他维度无关)。

---

## 严重问题(必须修复,阻塞上线)

### P0-1 脱敏函数 5 处真实漏洞,违反任务"第一红线"

任务文档 L232 明确:**"任何质检评分中『脱敏不全』扣分必须重过其他指标"**。

我编写了独立的 [Test-QASanitizeEdgeCases.ps1](Test-QASanitizeEdgeCases.ps1)(16 个 QA 设计的真实场景),实测 **5 个 case 漏脱**:

| # | 场景 | 输入 | 实际输出 | 风险 |
|---|------|------|---------|------|
| 1 | **GitHub PAT 裸出现** | `Auth failed with ghp_AbCdEf0123456789ABCDEF` | 原样输出 | git clone 异常 → token 直进 D1 |
| 2 | **Google API key (AIza...)** | `Using AIzaSyAbCdEfGhIjKlMn...` | 原样输出 | Gemini provider 配错时 stack trace 上传 key |
| 3 | **IPv6 地址** | `Connection from 2001:db8::1 refused` | 原样输出 | 任务文档明确"不收集 IP",但只匹配 IPv4。中国用户大量已是 IPv6 |
| 4 | **URL-encoded 用户路径** | `C%3A%5CUsers%5C74431%5Capp.log` | 原样输出 | HTTP error / .NET URL 异常常见此格式,**违反"路径中用户名段自动替换"承诺**(`关于`对话框 L4428 显式承诺) |
| 5 | **JSON 风格 password** | `{"password": "Sup3rS3cret!"}` | 原样输出 | 模型校验失败 dump 配置时易出现 |

**触发路径核对**(实际埋点会传什么):

- `model_config_failed` 用 `$_.Exception.Message`(L3118)—— hermes 抛的异常 message 大概率包含上述任意一种格式
- `webui_failed` 用 `$ErrorMessage`(L3236)
- `unexpected_error/dispatcher`(L2938)、`appdomain`(L2948)、`startup_refresh`(L5284)—— `.NET Exception.Message` 是"啥都可能进"的字段,这是脱敏函数承诺要兜底的最后一道防线
- `hermes_install_failed/start_terminal`(L5040)用 `$_.Exception.Message`

**结论**:5 个真实可触发的隐私泄露路径,任务红线触发,**必须**修复才能交付。

**建议修复**(纯正则补丁,不影响主流程):
```powershell
# 在 Sanitize-TelemetryString 第 239 行附近增加:
$s = [regex]::Replace($s, '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}', '<REDACTED>')                      # GitHub PAT 全家
$s = [regex]::Replace($s, '\bAIza[0-9A-Za-z_\-]{30,}',                '<REDACTED>')                      # Google API
$s = [regex]::Replace($s, '\b(?:[0-9a-fA-F]{1,4}:){2,}[0-9a-fA-F:]+\b','<IP>')                          # IPv6 (粗匹配,允许多 colon)
# URL-encoded path:解码常见编码再脱敏
$s = $s -replace '%5C', '\' -replace '%3A', ':' -replace '%2F', '/'  # 然后已有规则会接着处理
# JSON style password/token/secret 带引号
$s = [regex]::Replace($s, '"(password|token|secret|api_key|api-key)"\s*:\s*"[^"]+"', '"$1":"<REDACTED>"', 'IgnoreCase')
```

---

### P0-2 v2026.05.01.6.zip **未打包**,直接 deploy 必 404

`index.html:509` 已指向 `Hermes-Windows-Launcher-v2026.05.01.6.zip`,但 `downloads/` 目录里只到 `.5`。如果 PM 按工程师部署清单顺序操作 `./deploy.sh "" "" --with-worker`,**用户点下载即 404**。

工程师的部署清单(报告 L213-285)从 `cd worker; npx wrangler login` 开始,**完全没提"先用 Compress-Archive 打 zip"**。这是直接命中 CLAUDE.md 陷阱 #13(依赖未就绪的外部资源上线)的复现。

**建议修复**:
1. 工程师本地跑一遍标准发版打包命令,产出 `downloads/Hermes-Windows-Launcher-v2026.05.01.6.zip` 和 `downloads/Hermes-Windows-Launcher.zip`
2. 在工程师报告"Cloudflare 部署清单"开头补一节"步骤 0:打包(必做)"

---

### P0-3 $script:TelemetryEndpoint 硬编码 → PM 多半要改代码再重新打包

`HermesGuiLauncher.ps1:42`:
```powershell
$script:TelemetryEndpoint = 'https://hermes-telemetry.aisuper.workers.dev/api/telemetry'
```

但 `wrangler deploy` 后实际 URL 是 `hermes-telemetry.<your-cloudflare-account>.workers.dev`(每个账号子域不同)。工程师在报告 L242 也提到"如果 URL 不一样,改第 41 行,**重新打包发版**"——

PM 章程明确:"以下事情你要自己干,不要推给我:...让我跑命令、查字段..."。让 PM 部署完后回头改代码 + 重新打包 + 重新 commit + 重新 deploy 是不可接受的。

**建议修复**(任选其一):
1. 在 Cloudflare 配 Custom Domain,工程师把端点固定为 `https://telemetry.aisuper.win/api/telemetry`(自己控制的域),`wrangler.toml` 里加 `[[routes]]` 配置即可。**推荐**——一次性配置完全闭环。
2. 启动器从 `index.html` 上的 meta tag 拉端点(用户启动时在线探测一次,缓存 24 小时)。代价:启动多一次 HTTP 请求,首次启动也得有兜底。**不推荐**,复杂度增加。
3. PM 部署后只改一处 `HermesGuiLauncher.ps1:42` 然后 deploy.sh 自动重打包重发。**最低成本但 PM 体验差**。

---

## 中等问题(强烈建议修复)

### P1-1 「关于」按钮视觉对比度过低,工程师自己已声明顾虑

`HermesGuiLauncher.ps1:2743`:
```xml
<Button x:Name="AboutButton" ... Background="Transparent" BorderBrush="#334155"
        BorderThickness="1" Foreground="#94A3B8" Content="关于"/>
```

`#94A3B8` 灰色文字 + 透明背景在 `#111C33` 深蓝头上,亮度对比度 ≈ 4.1:1,刚卡 WCAG AA 边界。工程师在报告 L328 已自承担心"用户找不到"。

**建议**:Foreground 换 `#E2E8F0`(标题同色),BorderBrush 换 `#475569`(更亮),保持低调但确保可识别。

### P1-2 关闭遥测后用户**无直观反馈**

`Show-AboutDialog` 中 CheckBox unchecked 后只有 `Add-LogLine '匿名数据上报:已关闭'`(L4463)。日志区在主窗口,关于对话框是 modal,用户在对话框里看不到日志条变化。

**建议**:在 CheckBox 下方加一行轻量状态文字 `<TextBlock x:Name="AboutTelemetryStatus">`,Checked / Unchecked 时切换 "✓ 已开启" / "已关闭"。

### P1-3 启动器内 UI(banner / 关于对话框)未遵从 CLAUDE.md 视觉规范

CLAUDE.md "视觉语言规范" 明确:"新增 / 修改 Windows UI 时,按 Mac 端 LauncherPalette 做 WPF XAML 映射"。

工程师在 dashboard/index.html 用了暖色调(`#FFF8F1` + `#E8854F`),但**启动器内的 banner(L2747)和关于对话框(L4397)仍是深蓝色调**(`#0B1220` / `#1E2C45`)。

这是新增 UI,不是改造旧 UI,理应遵从新规范。

**情有可原的地方**:启动器主体仍是深色,如果只把 banner / about 改暖色会突兀。但至少 banner 上的强调色应该接近 LauncherPalette 的暖橙(`#E8854F`)。

**建议**:本次先**降级为 P1**(应修),整合者酌情决定是否当场修。如果留到下版本统一迁移,需要在 TODO.md 显式标记"#视觉规范 banner/about 暖色化"。

### P1-4 Sanitize-TelemetryProperties 不处理嵌套 hashtable

```powershell
# L282-284
} else {
    $out[[string]$key] = Sanitize-TelemetryString ([string]$value)
}
```

如果哪天某个埋点传 `Properties = @{ context = @{ secret = '...' } }`,内层 hashtable 会被 `[string]$value` 转成 `"System.Collections.Hashtable"` —— 数据丢失,但更糟的情况是 PSCustomObject 转字符串会得到完整 JSON-like 表示,**敏感字段照样泄露**。

当前所有埋点都是扁平 hashtable,实际不踩雷,但脱敏函数应当**默认关闭未知输入**(fail-secure),不是默认透传。

**建议**:if 链里加 `$value -is [hashtable]` → 递归调用 `Sanitize-TelemetryProperties`,输出嵌套对象;`PSCustomObject` 同理。

### P1-5 工程师报告 L189 与代码不符

报告写"760×560 ScrollViewer 内容是否完整显示",实际 `HermesGuiLauncher.ps1:4392-4393` 是 `Width=560 Height=560`。是工程师手误,不影响交付,但下次报告需要更严谨——这种小不一致会让整合者 / PM 对自检的可信度打折。

---

## 轻微问题(可选修复)

### P2-1 deploy.sh L67-71 worker/ 守卫永远不会触发

```bash
if [ -d "$DEPLOY_DIR/worker" ]; then
  echo "DANGER: worker/ found in Pages deploy dir!"
  ...
fi
```

但 deploy.sh 的 cp 命令(L27-50)从未把 `worker/` 复制到 `$DEPLOY_DIR`。这个守卫是"心安"代码而非真守卫。**不影响交付**,但下次 review 时建议改成"扫源码目录是否有 worker/ 出现在 cp 列表"或者直接删除。

### P2-2 launcher_closed 的 600ms 固定 sleep,体验最优解是 task.Wait(800)

`HermesGuiLauncher.ps1:5292` `Start-Sleep -Milliseconds 600` 给 PostAsync 留时间。但实际网络快时浪费,网络慢时仍会丢。

**建议**:改成 `try { $task.Wait(800) } catch {}`,带 timeout 的同步等。可作为 v2 优化项,**不阻塞本次**。

### P2-3 dashboard 部署到 hermes.aisuper.win/dashboard/ 是公开可访问

任何人输 URL 都能加载页面(只是没 token 看不到数据)。陷阱 #7 角度看这是"页面 + token 双重屏障",合理。但 dashboard 的 `<meta name="robots" content="noindex,nofollow">` 已防搜索引擎收录,接受。

---

## 用户视角发现

### 小白用户视角(主要客户)

- ✓ 不打开关于,看不到任何遥测痕迹(banner 一句话扫过)
- ✗ 看到 banner 字面"上报匿名数据帮助改进产品",**部分小白会担心**(中国地区对"上报"敏感)。文案可以再柔化:"产品需要听见使用情况才能持续优化"
- ✓ 「✓ 知道了」按钮明确,关掉就好
- ✗ 万一好奇点了"关于"看到一大段"我们收集 / 不收集",**反而引发疑虑**——但这是合规所需,接受

### 中级用户视角

- ✓ 找得到关闭开关
- ✗ 关闭后没有"已关闭"的视觉确认(P1-2)
- ✓ 「不收集 API Key / 用户名 / 路径」清晰

### 高级用户(QA / 技术用户)

- ✗ 打开 Wireshark 抓包能看到上报的 endpoint URL —— 但 endpoint 是公开的,接受
- ✗ 仔细看脱敏可能发现漏洞(P0-1)—— 这是真实风险

---

## 已知陷阱核对结果

| # | 陷阱 | 工程师声称 | QA 复核结果 |
|---|------|-----------|------------|
| 1 | WPF Dispatcher 异常处理 | ✓ 全程 try-catch + ContinueWith 吞异常 | **通过**。`Send-Telemetry` L321-356 严密 |
| 4 | UI 信息位置错误 | ✓ banner 顶部 + 关于按钮右上 | **通过**(banner 位置合理),但**关闭后无视觉反馈**(P1-2)轻微违反"信息找得到"精神 |
| 7 | 内部文档暴露 CDN | ✓ deploy.sh 守卫 + .cloudflareignore 双保险 | **通过**(`.cloudflareignore` 加了 `worker/`、`Test-*.ps1`),但 deploy.sh 守卫 L67-71 实际不会触发(P2-1) |
| 12 | Cloudflare 部署不删旧资产 | ✓ 沿用现有白名单 | **通过**,deploy.sh 已用白名单 + dummy 文件 |
| 21 | Set-Content 编码破坏 UTF-8 | ✓ 全用 `[System.IO.File]::WriteAllText` + UTF8(false) | **通过**。L132 / L175 均显式使用 UTF8 无 BOM |
| 13 | 依赖未就绪的外部资源上线 | 工程师未声明 | **新违反**:`v2026.05.01.6.zip` 没打包 → P0-2 |
| 14 | 只跑 SelfTest 不测 GUI 全流程 | ✓ 已声明盲区 | **诚实声明,通过** |

---

## 新发现的陷阱(建议加入清单)

工程师沉淀的 #28(HttpClient PostAsync 进程退出中断)、#29(任务事件清单与代码 hook 不匹配)质量都好,**接受沉淀**。

QA 补充建议沉淀的:

### #30(候选)硬编码外部服务 URL → PM 部署后必须改代码重打包

**触发条件**:启动器代码引用一个用户/PM 在 Cloudflare/Vercel 等部署的服务 URL,而该 URL 在不同账号下的子域名不同(如 `<account>.workers.dev`)

**坑的表现**:工程师写代码时取了个占位 URL,部署后实际 URL 不同,启动器对接失败。**用户感知**:遥测无声失败(任务可接受);**未来同类**:支付回调、推送服务、OAuth 回调失效则用户必崩。

**预防动作**:
- 部署到自有域名(Cloudflare Custom Domain),URL 由 PM/工程师控制不依赖账号子域
- 如果必须用动态 URL,启动器应在线探测端点(放在 index.html 的 meta 里),避免硬编码
- 工程师交付时部署清单第一步必须是"配自定义域名",不能让 PM 跑完 `wrangler deploy` 后回头改代码

**踩过日期**:2026-05-01

### #31(候选)发版前必须先打 zip 才能 deploy

**触发条件**:升版本号 + 改 index.html 的下载链接,但忘了 `Compress-Archive` 打包对应的 `.zip`

**坑的表现**:用户访问网站点下载 → 直接 404。SelfTest 测不到这一类,工程师不会发现。

**预防动作**:
- deploy.sh 起手判断 `downloads/Hermes-Windows-Launcher-v$VERSION.zip` 是否存在,不存在 → 报错退出
- 工程师交付报告里"部署清单"第一步必须是打包指令
- 发版前 `git status` 检查 downloads/ 目录是否包含新 zip(未追踪也算,因为 zip 不需要进 git)

**踩过日期**:2026-05-01

---

## 加分项观察(超出预期的)

1. **诚实声明 2/17 事件缺失而非假装** —— 工程师明确列出"剪掉的事件 + 原因"(报告 L100-110),WSL 事件、`first_conversation`、`crash` 都有合理技术理由,而非借口。**这是核心好习惯**。
2. **独立单元测试脚本** `Test-TelemetrySanitize.ps1` —— 通过 AST parser 抽函数到测试上下文,16 个 case,可重复跑。质量超出"自检"预期。
3. **Worker 端有完整防御性编码** —— `VALID_EVENTS` 白名单、`MAX_PROPS_BYTES`/`MAX_FIELD_LEN` 截断、CORS allowlist、anonymous_id 正则校验、IP_HASH_SALT secret。第一版基础设施就有这些,值得肯定。
4. **Dashboard 防 XSS** —— 全部用 `escapeHtml`(L216-220)处理用户控制字符串,即便失败 reason 含 `<script>` 也无 XSS 风险。
5. **盲区声明分级** —— 高/中/低 三档,具体到"中文 Windows HttpClient 行为"这种我都没想到的边界。**工程师诚实度满分**。
6. **沉淀的 2 个陷阱质量高** —— #28 HttpClient fire-and-forget 中断、#29 事件清单与 hook 不匹配,都是可复用的工程方法论。
7. **盐密码哈希 IP** —— 任务文档只要求"哈希前 8 位",工程师加了 IP_HASH_SALT secret,防止彩虹表反推,**安全意识超过任务要求**。

---

## 给整合者 Agent 的明确建议

**返工(85/100,P0 阻塞 3 项)**。

**核心理由**:任务文档第 232 行明确写"隐私是这个任务的第一红线—— 任何质检评分中『脱敏不全』扣分必须重过其他指标"。P0-1 的 5 个脱敏漏洞是真实可触发的隐私泄露路径,违反第一红线 → **直接卡通过**,与其他维度无关。

**建议返工范围**:
1. **必修**:P0-1(脱敏正则补 5 条)+ P0-2(打 zip 并验证存在)+ P0-3(决定 endpoint 方案,推荐 Cloudflare Custom Domain)
2. **强烈建议同回合修**:P1-1(关于按钮对比度)、P1-2(关闭遥测视觉反馈)
3. **可留到下版本**:P1-3(暖色调迁移)、P1-4(嵌套 hashtable)、P1-5(报告与代码偏差)
4. **接受**:工程师沉淀的 2 个陷阱(#28、#29)+ QA 补充的 2 个陷阱(#30、#31),整合者把它们加入 CLAUDE.md "已知陷阱清单"

**不建议重做**:整体架构(Worker + D1 + Dashboard)、埋点策略、隐私决策、UI 整体布局都正确,只是末梢的脱敏正则不够全 + 部署清单细节缺失。**返工成本 < 1 小时**,远低于重做。

**给 PM 的真机验收清单**(返工修完后,5-10 分钟):
1. 打开启动器,顶部出现暖色 banner,点「✓ 知道了」消失,**关启动器再开 banner 不出现**
2. 点窗口右上"关于",弹框显示版本 `Windows v2026.05.01.6` + 收集/不收集说明 + CheckBox
3. 取消 CheckBox → 关弹框,**应有视觉反馈**(P1-2 修后)。再开关于,CheckBox 保持未勾选
4. 重新勾选 → 关弹框 → 故意填错 API Key 触发模型校验失败 → 启动器**不应有任何错误弹窗、卡顿、闪退**
5. 断网做同样动作,启动器表现一致

**返工后再过一遍 QA**:重新跑 `Test-QASanitizeEdgeCases.ps1`,**16 个 case 必须全过**(原来 11/16)。同时验证 `downloads/Hermes-Windows-Launcher-v2026.05.01.6.zip` 存在且大小正常。
