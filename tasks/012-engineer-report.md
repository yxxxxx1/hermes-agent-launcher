# 工程师产出报告 - 任务 012

## 任务编号
**012 - Windows 启动器 UI 视觉迁移 v1**

## 实现方案 (PM 已选)

### 决策 G:字体策略
**选 A3 — 混合(英文 Quicksand + 中文 Microsoft YaHei UI)**

实现:
- 在 `assets/fonts/` 目录 bundle 3 个静态字重 `Quicksand-Regular.ttf` (78 KB) / `Quicksand-SemiBold.ttf` (78 KB) / `Quicksand-Bold.ttf` (78 KB),合计 ~237 KB
- Quicksand 来源:Google Fonts repo 现在只发 variable font,工程师用 fontTools 把 `Quicksand[wght].ttf` 切成 3 个静态字重(license 是 SIL OFL,二次分发合法,无需署名)
- WPF 字体注册路径:`HermesGuiLauncher.ps1` line 25-46 加 `$script:UiFontFamily` 变量,运行时拼接 `file:///D:/.../assets/fonts/#Quicksand, Microsoft YaHei UI, Segoe UI Variable Display, Segoe UI` 多 family fallback 链
- WPF GlyphTypeface 验证:family="Quicksand", weights=Normal/SemiBold/Bold 都正确识别

### 决策 H:WindowsPalette 实现方式
**选 B1 — 嵌入主 XAML `<Window.Resources>` 段**

实现:
- 主 XAML(line 2755-2933)`<Window.Resources>` 加入 35+ 个 `SolidColorBrush` token(LauncherPalette 全色值)+ 2 个 `LinearGradientBrush`(暖橙按钮 / 进度条) + 2 个 `FontFamily` 资源 + 5 个 button/progressbar Style
- 关于对话框(line ~5151+)单独有同样的 token 段(B1 方案的"复制 2 处"代价,~30 行)
- 没有引入新文件依赖,deploy 链路不变

---

## 改动清单

| 文件 | 行数变化 | 改动概要 |
|------|---------|---------|
| `HermesGuiLauncher.ps1` | +约 1100 / -约 250 | 主 XAML 重写(170 → 730+ 行),关于对话框 XAML 重写,Refresh-Status 接 3 大步骤指示器,Step-LaunchSequence 接 7 段 mini-step + 进度条,新增 6 个 UI helper 函数,字体路径变量,版本号升至 v2026.05.02.1 |
| `assets/fonts/Quicksand-Regular.ttf` | +78 KB | 新增,Quicksand Regular 静态字重 |
| `assets/fonts/Quicksand-SemiBold.ttf` | +78 KB | 新增,Quicksand SemiBold 静态字重 |
| `assets/fonts/Quicksand-Bold.ttf` | +78 KB | 新增,Quicksand Bold 静态字重 |
| `index.html` | +1 / -1 | 下载链接和版本号文案升到 v2026.05.02.1 |
| `README.md` | +1 / -1 | Package 章节版本号升级 + 视觉迁移说明 |

---

## 关键代码位置

### 字体 + Palette 基础设施
- [HermesGuiLauncher.ps1:25](HermesGuiLauncher.ps1:25) — 版本号升至 v2026.05.02.1
- [HermesGuiLauncher.ps1:27-46](HermesGuiLauncher.ps1:27) — 字体路径声明 + WPF FontFamily fallback 链
- [HermesGuiLauncher.ps1:2755-2933](HermesGuiLauncher.ps1:2755) — 主 XAML `<Window.Resources>` token 段(35+ Brush + 2 渐变 + 2 字体 + 5 Style)

### 7 个状态视觉(主 XAML 内)
- 状态 1 未安装(环境检测) — `InstallTaskCardBorder` step tag "1" + 步骤指示器 1=active
- 状态 6 准备中(位置确认) — `InstallPathCardBorder` step tag "2" + 步骤指示器 1=done/2=active
- 状态 7 准备安装 — step tag "3" + 步骤指示器 1=done/2=done/3=active
- 状态 8 安装中 — `InstallProgressBar` + `InstallSubStepsPanel` (4 段) + `InstallCurrentStageBorder` + step tag "正在安装"
- 状态 9 安装失败 — `InstallFailureLogPreviewBorder` (深色 monospace 末尾 8 行) + step3=failed
- 状态 11 已就绪 — `HomeReadyContainer` 暖橙 badge + 大字标题
- 状态 12 启动 WebUI 中 — `LaunchProgressCard` + 7 段 mini-step + 进度条 + spinner

### UI 状态同步 helpers (line ~4023-4244)
- `Set-InstallStepCardState` — 切换 3 大步骤指示器卡片 active/done/pending/failed 视觉
- `Set-InstallSubStepState` — 切换 4 段子阶段视觉
- `Set-LaunchMiniStepState` — 切换 7 段 mini-step 视觉
- `Show-LaunchProgressCard` / `Hide-LaunchProgressCard` — 控制 WebUI 启动进度卡显隐
- `Update-LaunchProgressCardPhase` — phase → mini-step + ProgressBar + 文案 + spinner 旋转 30°
- `$script:LaunchPhaseMap` — 7 个 phase 映射到 step index/文案/进度区间

### 接入点
- [HermesGuiLauncher.ps1:3984](HermesGuiLauncher.ps1:3984) — `Start-LaunchAsync` 末尾调 `Show-LaunchProgressCard`(进入启动流时显示卡)
- [HermesGuiLauncher.ps1:4253](HermesGuiLauncher.ps1:4253) — `Step-LaunchSequence` 入口每 tick 调 `Update-LaunchProgressCardPhase $s.Phase`
- [HermesGuiLauncher.ps1:3997](HermesGuiLauncher.ps1:3997) — `Stop-LaunchAsync` 调 `Hide-LaunchProgressCard`(出错或 cancel 时还原)
- [HermesGuiLauncher.ps1:5979-6111](HermesGuiLauncher.ps1:5979) — `Refresh-Status` 重写,各分支同步 step tag 文案 + 步骤指示器 active/done/failed + 进度条/子阶段/失败 LogPreview 显隐
- [HermesGuiLauncher.ps1:4535-4595](HermesGuiLauncher.ps1:4535) — `Start-ExternalInstallMonitor` 失败分支填充 `InstallFailureLogPreviewText` + 标记 step3=failed

### 关于对话框重写
- [HermesGuiLauncher.ps1:5151+](HermesGuiLauncher.ps1:5151) — `Show-AboutDialog` 改用米色暖橙主题 + Quicksand 字体 + 我们收集/不收集双列卡片 + 暖橙 toggle row + 状态文字暖色配色(SuccessBrush/DangerBrush)
- 决策 F:**未加** 4 pill 链接(GitHub/官网/文档/报告),保留极简

### 隐私 banner 持久化
- 控件名沿用 `TelemetryConsentBanner` / `TelemetryConsentDismissButton`
- 视觉换成米色 + 暖橙 i icon + 暖橙 dismiss 按钮(透明 + accent 文字)
- 持久化已在 011 任务做好(`Mark-FirstRunConsentShown` → `Save-TelemetrySettings -FirstRunConsentShown $true` UTF-8 无 BOM JSON,陷阱 #21 已规避),本次 wire 上不变

---

## 自检结果

### 第 1 层 - 代码自检 ✓ 已通过
- [x] `[System.Management.Automation.Language.Parser]::ParseFile` AST 解析:**0 错误**
- [x] `powershell.exe -SelfTest` 跑通:返回正常 JSON 状态
- [x] WPF 主 XAML `[Windows.Markup.XamlReader]::Load` 通过:Window 1040×780 + 119 个 x:Name 全数加载
- [x] WPF 关于对话框 XAML Load 通过:Window 580×660 + 4 个关键控件全数找到
- [x] `controls` 字典里 116 个名字 100% 在主 XAML 有 x:Name 定义(差额 3 个是 XAML 内部装饰名如 `LaunchSpinnerRotate` `InstallTaskStepTagBorder` `InstallTaskStepTagNum`,不需进 controls 字典)
- [x] 没有引入新 PowerShell 模块依赖
- [x] 没有引入新 NuGet/.NET 依赖
- [x] 字体文件 + Python fontTools 切片是构建期 helper,**用户运行时不需要 Python**

### 第 2 层 - 用户场景自检 ✓ 已通过(代码路径)
- [x] 用户双击 `.cmd` → 看到米色窗口,Quicksand "Hermes Agent" 标题(代码路径已对齐 mockup)
- [x] 状态 1(未安装)路径:`Refresh-Status` 走 preflight 分支 → InstallTaskCardBorder visible + step1 active
- [x] 状态 6(位置确认)路径:走 `-not InstallLocationConfirmed` 分支 → InstallPathCardBorder visible + step2 active
- [x] 状态 8(安装中)路径:走 `installRunning` 分支 → ProgressBar + 4 子阶段 + 当前阶段文字 + 提示卡全部 visible
- [x] 状态 9(失败摘要)路径:`Start-ExternalInstallMonitor` exitCode≠0 → 设 `InstallFailureSummaryText.Visibility=Visible` + 填 `InstallFailureLogPreviewText` + 标 step3=failed
- [x] 状态 11(已就绪)路径:Home Mode 切换,大暖橙 badge + 大字标题 + 主按钮"开始使用"
- [x] 状态 12(启动 WebUI 中)路径:`Start-LaunchAsync` → `Show-LaunchProgressCard` → 每 tick `Update-LaunchProgressCardPhase` 同步 mini-step + ProgressBar + 文案
- [x] 关于对话框路径:点"关于"按钮 → 580×660 暖色对话框 + toggle 即时反馈
- [x] 隐私 banner 路径:首启动显示 → 点"知道了" → `Mark-FirstRunConsentShown` 写持久化
- [x] **修复 Home Mode 启动 WebUI 进度反馈盲区**:用户点"开始使用"后立即在主区中央看到 LaunchProgressCard,7 段 mini-step 实时切换 — 这是任务核心目标之一

### 第 3 层 - 边界场景自检 ✓ 已通过
- [x] 字体文件缺失:`$script:UiFontBundleAvailable=$false` → fallback 到 `Microsoft YaHei UI, Segoe UI Variable Display, Segoe UI`,启动器仍可用,只是英文不圆润
- [x] WPF FontFamily fallback 链:Quicksand 不含中文 glyph 时,WPF 自动按 Unicode 区段切到 Microsoft YaHei UI(显式硬编码,不会掉到 SimSun)
- [x] WPF Style trigger:`PrimaryButtonStyle` 在 `IsEnabled=False` 时切到灰色 + 移除 DropShadow,disabled 状态视觉一致
- [x] LaunchProgressCard 反复 show/hide:`HomeReadyContainer.Visibility` 跟 `LaunchProgressCard.Visibility` 互斥,Refresh-Status 在非 LaunchState 时强制 reset 互斥状态(避免残留)
- [x] OpenClaw pendingMigration 时:全部 install card collapse,只显示 OpenClaw 卡 + 步骤指示器 3 个全 done
- [x] 安装失败后用户再点重试:`Refresh-Status` 重新走 preflight → step1=active(failed 状态被覆盖到 active),不会粘连
- [x] 用户在状态 8 中关闭外部终端非 0 退出:Start-ExternalInstallMonitor 检测到后填充 LogPreview + step3=failed,Refresh-Status 之后再设回(避免被默认 hide 行为覆盖)

### 第 4 层 - 产品姿态自检 ✓ 已通过
- [x] 暖橙主色不刺眼:`#D9772B` 配 `accent-soft #F2B56B` 渐变,按钮带 `0.32 alpha` 暖色阴影,符合 Mac 端 LauncherPalette 视觉
- [x] 文案温暖:"我们已经检查了你的电脑环境" / "环境没问题,一起把 Hermes 装上吧" / "另一个黑色窗口是官方安装终端" — 全部口语化中文,不堆术语
- [x] 失败文案不绝望:"安装没能完成,我们来看看怎么解决" + 提供原因列表 + "大多数失败重新点一下下方'重新开始'就能过"(避免技术 traceback 直接糊脸)
- [x] 关于对话框去除多余 link pill(决策 F),保持极简
- [x] 业务逻辑零变更:`Send-Telemetry` / `Get-OrCreateAnonymousId` / `Sanitize-TelemetryString` / 安装 / Gateway / WebUI 启动状态机 全部保留原行为,只换 UI 层

### 第 5 层 - 已知陷阱核对 ✓ 已规避
- **#1 WPF Dispatcher 异常处理**:所有新 helper 函数 `Set-InstallStepCardState` / `Update-LaunchProgressCardPhase` / `Show-LaunchProgressCard` 全部 try-catch 包裹,不让单个控件 null 拖崩主 dispatcher
- **#2 ComboBox 内部 TextBox 时机**:本次没动 ComboBox,无关
- **#3 中文 Windows 错误消息匹配**:本次没改错误处理,无关
- **#4 UI 信息位置错误(找得到 ≠ 信息存在)**:LaunchProgressCard 直接放在 Home Mode 主区中央,不是侧边栏 — 用户视线焦点 100%。InstallFailureLogPreview 紧贴失败摘要,不在底部日志区。InstallStepTipBorder 紧贴当前 active 步骤
- **#5 跨框架 API 替换需 UI 交互测试**:本次大量 XAML 重写,**已**通过 WPF Load 静态测试(主 + 关于 + 119 控件全部能 FindName);GUI 实际渲染交给 PM 真机验
- **#10 测试通过 ≠ 用户找得到**:5-10 分钟 PM 真机验收清单见末尾,逐个状态对照 mockup
- **#11 部署分支 vs main**:本次未触碰 deploy.sh / 未发版,只升 4 处版本号,如发版需注意陷阱 #11
- **#21 Set-Content 编码**:无新写文件路径,沿用 011 已建好的 UTF-8 无 BOM 持久化(`Save-TelemetrySettings`)
- **#28 fire-and-forget HTTP**:无新遥测,沿用现有 `Send-Telemetry` 路径
- **#29 任务文档事件清单 vs 实际 hook**:本次无新遥测事件,N/A
- **#31 zip 漏打包**:本次新增 `assets/fonts/*.ttf` 3 个文件 + `assets/fonts/` 目录路径必须打入 zip — **PM 发版前看末尾"对 PM 的部署提示"**

---

## 自检盲区(必须 PM 真机验证)

### 字体相关盲区
1. **WPF 在中文用户名路径下加载 Quicksand ttf**:`file:///` URI 在 `C:\Users\张三\AppData\Local\hermes-launcher\assets\fonts\` 这种中文路径上能否成功 `[System.Uri]::new` 解析,我没法本地测(本机用户名是 `74431`)
2. **Quicksand SemiBold/Bold 是否真切到对应字重**:WPF GlyphTypeface 验证显示 family/weight 正确,但实际 button "开始安装" 渲染出来的 SemiBold 字符是不是肉眼可分辨的"中粗",需要 PM 看
3. **中英文混排 fallback 顺序**:"Hermes Agent · v2026.05.02.1" 这种中英混排下,英文是不是真走 Quicksand 而不是默默掉到 Segoe UI

### 视觉布局盲区
4. **米色 #F2F0E8 背景在不同显示器上的呈现**:色彩管理 / 色温差异可能让米色看起来偏黄或偏白,跟 mockup 浏览器里"温暖感"是否一致需要 PM 肉眼比对
5. **WindowsPalette token 的相对色值是否够区分**:`SurfacePrimary #FAF8F2` vs `SurfaceSecondary #F4F0E8` vs `SurfaceTertiary #F0E8DE` 三档浅米色,在低亮度屏幕上是否能区分卡片层次
6. **暖橙渐变按钮 + DropShadowEffect 在低色深屏(8-bit)上是否有色带**:不能本地测
7. **continuous 圆角:WPF 不支持**:用的是标准圆角(quadrant arc),跟 mockup CSS `border-radius` 视觉差异接受,但 PM 真机看是否突兀
8. **窗口 padding 36px 在 1024×768 低分辨率屏上是否过宽**:窗口最小 960×720,padding 占 72px 后剩 888px,够 1.4*+1*双列 grid

### DPI / 高 DPI 屏幕
9. **WPF DPI Aware**:启动器 manifest 没明确声明 PerMonitorV2,在 150% / 175% / 200% 缩放屏上视觉是否变形 — 需要 PM 高 DPI 屏真机看
10. **`TextOptions.TextFormattingMode="Display"`**:加了用于 Win10/Win11 字体清晰度,但是否真生效需要肉眼看

### 系统兼容
11. **Win10 vs Win11 视觉差异**:Win11 的 `Segoe UI Variable Display` 不存在于 Win10,fallback 到 `Segoe UI`,某些场景视觉不一致 — 需要 PM 在两套环境下分别测
12. **暗色系统模式**:本期统一用浅色,系统暗模式不强制变暗。但 WPF 默认 ScrollBar 颜色会跟系统主题,在暗模式下可能跟米色背景反差大
13. **杀毒软件**:增加 ttf 文件可能触发 360/腾讯/卡巴误报,不能本地测

### 用户视角
14. **"找得到关键信息"**:状态 8 安装中,用户能否在 1 秒内找到"现在跑到哪一步" — 取决于步骤指示器是否在视线焦点
15. **WebUI 启动 7 段 mini-step 的文案选择**:"环境 / 下载 Node / 解压 / 装 WebUI / 启 Gateway / 等待就绪 / 启 WebUI" 这套文案是否对用户够清晰,需要 PM 主观判断
16. **spinner 旋转节奏**:每 800ms tick 转 30° = 9.6 秒一圈 — 慢转,真机看是否过快或过慢

### 集成盲区
17. **真实安装流程下 LaunchProgressCard 视觉真切**:download-node 分支需要真实跑 ~30 MB 下载,我无法跑通整流测;PM 在已有 Node.js 缓存的环境下点开始使用,会快速跳过 download-node 跑到 npm-install,需要 PM 真机走一遍
18. **InstallFailureLogPreview 的真实日志**:我用 mock 文本测试 LogPreview 显示,但真实 git clone 失败 / pip 失败 / 网络断开等场景下 LogTextBox 末尾 8 行长什么样,我没法构造

---

## 已规避的已知陷阱

| 陷阱 | 规避动作 |
|------|---------|
| #1 WPF Dispatcher 异常 | 所有新 UI helper 全 try-catch |
| #4 UI 信息位置 | LaunchProgressCard / InstallFailureLogPreview / InstallStepTipBorder 全部紧贴用户视线焦点,不在边缘 |
| #5 跨框架 API 替换 | 通过 WPF Load 测试验证 119 个控件全部可 FindName(主) + 4 关键控件(关于) |
| #10 测试通过 ≠ 用户找得到 | 工程师产出报告里诚实声明 14 项盲区,绝不假装"全部测过" |
| #21 编码 | 不引入新写文件路径;沿用 011 的 UTF-8 无 BOM JSON 持久化 |

---

## 新发现的问题/陷阱

### 候选陷阱 #34:Google Fonts 全面切换到 Variable Font,没有 static 子目录可下

**触发条件**:从 `https://github.com/google/fonts/tree/main/ofl/<family>` 想下 Regular/SemiBold/Bold 静态字重

**坑的表现**:Google Fonts repo(2024 后)所有字体只发 Variable Font(`Family[wght].ttf`),没有 `static/` 子目录;jsDelivr 拒绝 50 MB 限制;ghproxy 经常超时;`@fontsource` v5+ 只发 woff/woff2(WPF 不支持)。

**预防动作**:工程师本地用 `fontTools.varLib.instancer` 把 VF 切静态,然后 commit 进 repo。具体命令:
```python
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
src = TTFont('Family-VF.ttf')
for name, w in {'Regular':400,'SemiBold':600,'Bold':700}.items():
    static = instancer.instantiateVariableFont(src, {'wght': w})
    static.save(f'Family-{name}.ttf')
```

如果团队不想引入构建期 Python 依赖,可改用 IBM Plex Sans / Source Sans 3 等仍发 static 的字体。

**踩过日期**:2026-05-02

### 候选陷阱 #35:WPF VF 默认 instance 不一定是 Regular

**触发条件**:WPF 直接加载 `Family[wght].ttf` Variable Font

**坑的表现**:WPF GlyphTypeface 只读 default named instance,Quicksand VF 的 default 是 Light(weight=300)而不是 Regular(400) — 用 `FontWeight="Bold"` 时 WPF 走 synthetic bold,实际看起来比 Static-Bold 字形细很多。

**预防动作**:不直接用 VF,先切静态字重再 bundle。如果必须用 VF,要在 PowerShell 里通过 `WebUI` 主题文件或 `<Typography.Variations>` 显式指定 axis 值(WPF 4.8+ 支持但写法繁琐)。

**踩过日期**:2026-05-02

---

## 提交给 QA Agent 的输入

### 1. 需要 QA 重点验证的部分

#### 必须 QA Agent 真机看的 7 个状态
对照 mockup HTML(`mockups/011-windows-ui/`)逐个比对:
1. 状态 1 → `04-not-installed.html` — 双列布局,左 hero 右 3 步指示器
2. 状态 6 → `05-preflight.html` — 左路径条目,右 step2 暖橙脉动
3. 状态 8 → `03-installing.html` — ProgressBar + 4 段子阶段 + 当前阶段文字 + 提示卡
4. 状态 9 → `06-install-failed.html` — 失败摘要 + 深色 monospace 日志末尾
5. 状态 11 → `01-main-ready.html` — 暖橙 badge + 大字标题
6. 状态 12 → `07-launching-webui.html` — 7 段 mini-step + 进度条 + spinner
7. 关于对话框 → `02-about-dialog.html` — 我们收集/不收集双列 + 暖橙 toggle

#### 必须 QA Agent 跑代码路径的:
- 跑 `powershell -ExecutionPolicy Bypass -File ./HermesGuiLauncher.ps1 -SelfTest` 看 JSON
- 用我贴的 test-xaml-load 思路验证 WPF Load(可在我留的 PowerShell 块基础上直接验)

#### QA Agent 重点核对的陷阱清单
对照 CLAUDE.md 已知陷阱 #1-#33,本次重点是 #1/#4/#5/#10/#21/#31。

### 2. 工程师认为的薄弱环节
- **真机渲染**:静态测试覆盖了 XAML 解析,但实际像素渲染我看不到
- **字体加载**:Quicksand ttf 切片是工程师本地用 fontTools 跑的,WPF 是否能 100% 识别需要 PM 真机
- **窗口尺寸 Install 1040×780 vs Home 920×560 切换**:`Set-LauncherWindowMode` 没改,但内容布局变了,可能在切换瞬间有跳动

---

## 给 PM 的真机验收指引

**预计 PM 投入**:5-10 分钟 + 真机看 7 状态截图

### 验收清单(逐条勾)

#### 必须验
1. [ ] 双击 `Start-HermesGuiLauncher.cmd` → 看到米色背景 + Quicksand 标题"Hermes Agent" + 暖橙圆角"关于"按钮(状态 1 默认)
2. [ ] 顶部"Hermes Agent"是不是圆润气球字(Quicksand)而不是直边几何字(Segoe UI)。**判定法**:看小写字母 a — 圆润如气球 = Quicksand,有衬线变化 = Segoe UI
3. [ ] 中文"开始使用"是 Microsoft YaHei UI 而不是 SimSun(后者是衬线宋体,看起来很粗)
4. [ ] 状态 11 已就绪页:暖橙圆形 badge + ✓ 勾号 + 大字"已就绪" + 黑色字 "点'开始使用'..." + 暖橙渐变按钮"开始使用"
5. [ ] 点"开始使用" → 主区域出现 LaunchProgressCard(暖橙 spinner + 标题"第一次启动需要装一些组件" + 7 段 mini-step + 进度条) — **这是任务核心修盲区**
6. [ ] 点"关于" → 580×660 米色对话框 + Hermes 启动器 + 我们收集/不收集双列 + 底部 toggle row
7. [ ] toggle 切换 → 下方状态条立即变 "✓ 已开启 · 感谢..." (绿色) / "已关闭 · ..." (红色)
8. [ ] 点"知道了"隐私 banner 消失 → 关掉启动器再开,banner 不再出现(持久化生效)

#### 高 DPI / 多分辨率(可选)
9. [ ] 在 Win11 150% 缩放屏上看,字体不模糊,卡片边距合理
10. [ ] 把窗口拖到 960×720(最小尺寸),双列还能看清

#### 状态 9 失败摘要(可选,需要复现失败)
11. [ ] 模拟一次安装失败(随便改个错的 Git 分支),退出码非 0 后:看左侧失败卡 + 深色 monospace 日志末尾 + 右侧 step3 红色×

### 不通过的反馈格式

按 CLAUDE.md "反馈结构化模板"贴症状 + 截图,**不要诊断原因**。

---

## 对 PM 的部署提示(发版前必读)

### 打包注意事项(陷阱 #31 防再踩)

发版前必须确保 `Hermes-Windows-Launcher-v2026.05.02.1.zip` **包含** 以下内容:

```powershell
# 必须打包的清单
- HermesGuiLauncher.ps1
- Start-HermesGuiLauncher.cmd
- assets\fonts\Quicksand-Regular.ttf
- assets\fonts\Quicksand-SemiBold.ttf
- assets\fonts\Quicksand-Bold.ttf
```

**打包命令(替代 README.md 那段单文件命令)**:
```powershell
$src = @(
    'HermesGuiLauncher.ps1',
    'Start-HermesGuiLauncher.cmd',
    'assets\fonts\Quicksand-Regular.ttf',
    'assets\fonts\Quicksand-SemiBold.ttf',
    'assets\fonts\Quicksand-Bold.ttf'
)
Compress-Archive -Path $src -DestinationPath .\downloads\Hermes-Windows-Launcher-v2026.05.02.1.zip -Force
Copy-Item .\downloads\Hermes-Windows-Launcher-v2026.05.02.1.zip .\downloads\Hermes-Windows-Launcher.zip -Force
```

**打完包必须 unzip 验证**:
```powershell
Expand-Archive .\downloads\Hermes-Windows-Launcher-v2026.05.02.1.zip -DestinationPath .\test-unzip -Force
Get-ChildItem .\test-unzip -Recurse | Select-Object FullName, Length
# 应该看到:
#   HermesGuiLauncher.ps1
#   Start-HermesGuiLauncher.cmd
#   assets\fonts\Quicksand-Regular.ttf
#   assets\fonts\Quicksand-SemiBold.ttf
#   assets\fonts\Quicksand-Bold.ttf
Remove-Item .\test-unzip -Recurse -Force
```

如果 zip 里没有 fonts 目录,用户拿到的启动器英文字体会回退到系统 Segoe UI(并非崩溃,但跟 Mac 视觉对齐就没了 — 任务核心目的失败)。

### Cloudflare Pages 部署(陷阱 #11 + #12)

发版部署时:
1. 先 `git diff main -- index.html` 看 main 分支 Mac 版本号是否需要 sync 过来
2. 用 `deploy.sh`(白名单方式)部署,**不要** `wrangler pages deploy .` 直接全量
3. 部署后 `curl https://hermes.aisuper.win/CLAUDE.md` 验证不返回真实内容
4. 部署后 `curl https://hermes.aisuper.win/` 看 index.html 版本号是 v2026.05.02.1

---

## 总结

完成度:**任务文档 11 项必须达成 + 决策 A-H 全部落地**(基于代码层验证,真机渲染由 PM 验收)。

PM 验收完通过后,这次工作的产出会成为后续所有 Windows UI 改动的基础(WindowsPalette token 系统、字体 fallback 链、卡片步骤指示器组件、ProgressBar Style)。下次做"更多设置面板"时,这些 Style 可以直接 reuse。

工作总耗时:约 7 小时(含字体下载/切片排坑 ~1 小时)。
