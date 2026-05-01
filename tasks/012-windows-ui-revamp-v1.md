# 任务:Windows 启动器 UI 视觉迁移 v1

**任务编号**: 012
**创建日期**: 2026-05-01
**预计耗时**: 8-14 小时(WPF XAML 重写 + 真机验收)
**优先级**: P1

---

## 1. 产品目的(Product Goal)

**让 Windows 启动器跟 Mac 端视觉对齐,从"深蓝黑技术风"切到"米色暖橙温暖系"**。

当前 Windows 视觉跟 Mac 端的 LauncherPalette 完全断层,用户感知层面像两个不同产品。同时 011 任务上线遥测后已经能看到漏斗数据,接下来产品迭代重点之一就是"让中国用户用得舒服",视觉是第一感知。

不追求 Windows/Mac 像素级一致,但**色调、圆角、字体、阴影**这套设计语言要对齐,让两端是同一个产品的两个 OS 实现。

## 2. 运营目的(Business Goal)

短期:
- 视觉一上来就让用户觉得"这个产品有人在用心做",降低"看着像草台班子"的退坑率
- 修复 Home Mode 启动 WebUI 没进度反馈这个隐性盲区(用户体验问题)

长期:
- 视觉系统化(WindowsPalette token)是后续所有 UI 改动的基础,这次种下,后面只是扩展
- Mac/Windows 视觉一致性是品牌的一部分,影响口碑传播

## 3. 用户视角(User View)

### 当前痛点
- 双击启动器 → 看到深蓝黑窗口,跟 Mac 端那种米色暖橙的"温暖工具"感截然不同
- 安装失败时,日志藏在底部独立区,用户得自己滚动找
- 安装中的进度只是"多行 ✓ 文字",没有可视化进度条,长等待时焦虑感强
- Home Mode 点完"开始使用"后,主界面什么反应都没有,用户不知道 WebUI 是不是真的在启动

### 期望状态
- 双击启动器 → 米色温暖背景 + 暖橙主按钮,**第一感觉就是"这是给我用的工具"**
- 安装中:大进度条 + 4 阶段步骤指示器 + 当前阶段文案,等待焦虑感最小化
- 安装失败:失败摘要直接显示日志末尾几行 + 重试 / 复制错误 / 查看完整日志三个明确动作
- Home Mode 启动 WebUI:中央有"启动进度卡"显示 7 段迷你步骤(下载 Node → 解压 → 装 WebUI → 启 Gateway → 等就绪 → 启 WebUI)

## 4. 成功标准(Success Criteria)

### 必须达成(阻塞条件)
- [ ] 引入 `WindowsPalette` XAML ResourceDictionary,定义 LauncherPalette 全套色 token(背景 / surface / text / accent / status / line)
- [ ] 7 个用户路径状态全部按 mockup 实现:
  - [ ] 状态 1 未安装(`04-not-installed.html`)
  - [ ] 状态 6 准备中(`05-preflight.html`)
  - [ ] 状态 8 安装中(`03-installing.html`)
  - [ ] 状态 9 安装失败(`06-install-failed.html`)
  - [ ] 状态 11 已就绪(`01-main-ready.html`)
  - [ ] 状态 12 启动 WebUI 中(`07-launching-webui.html`)—— **修复 Home Mode 进度反馈盲区**
  - [ ] 关于对话框(`02-about-dialog.html`)
- [ ] 决策 A:加 ProgressBar 控件,4 处使用(03/04/05/07)
- [ ] 决策 B:3 大步骤右栏升级成卡片式步骤指示器(03/04/05/06)
- [ ] 决策 C:WebUI 启动 7 段迷你步骤可视化(07)
- [ ] 决策 D:安装中 4 段子阶段(环境检查/下载/安装/启动)
- [ ] 决策 E:安装失败摘要直接显示日志末尾(06)
- [ ] 决策 F **不做**:关于对话框不加 4 个 pill 链接(GitHub/官网/文档/报告)
- [ ] 字体策略:bundle 一个圆体英文字体(Quicksand 或 Manrope),CJK 用 Microsoft YaHei UI;或退而用系统 `Segoe UI Variable` + CSS 字重适配(工程师选)
- [ ] 圆角:所有矩形 12-16px continuous
- [ ] 阴影:柔和,`0 8px 24px rgba(0,0,0,0.06)` 这一档,不要硬阴影
- [ ] 隐私 banner 行为:点"知道了"后用 LocalStorage / 本机配置文件存 `dismissed=true`,下次不显示
- [ ] 所有原有功能行为不变(toggle 状态、错误处理、安装流程、日志输出等)

### 验证条件(真机测试)
- [ ] Win10 / Win11 上肉眼看新 UI,确认温暖感、对比度、可读性都到位
- [ ] 安装漏斗 4 步走一遍,各状态能正确切换、进度条更新顺畅
- [ ] 关于对话框打开关闭,toggle 切换状态文字红绿正确
- [ ] Home Mode 点"开始使用"后,看到 WebUI 启动进度卡(7 段)
- [ ] 隐私 banner 点击"知道了"消失,下次启动不再显示
- [ ] 高 DPI 屏幕(150% / 175% / 200%)下视觉不变形
- [ ] 暗色模式(如果系统启用)兼容(本期统一用浅色,系统暗模式下不强制变暗)

### 加分项(可选)
- [ ] WindowsPalette 在 Settings 里支持热重载(改 token 后窗口实时跟随,方便后续微调)
- [ ] 主区域加微动画(状态卡入场、进度条流光),按 LauncherPalette 的 spring 缓动

## 5. 边界(Boundaries)

### 这次做的
- 7 个核心状态 + 关于对话框
- WindowsPalette token 系统(只在 Top-3 范围内使用)
- 决策 A-F 的全部实现
- 隐私 banner 持久化"知道了"行为
- 字体策略落地

### 这次不做的
- ❌ 其他 8 类对话框(2.2-2.9)→ 下次迭代,已记 TODO
- ❌ 其他 6 个主窗口残余状态(检测阻塞 / 残留 / OpenClaw 等)→ TODO
- ❌ 错误 banner / 状态 banner / 版本更新 banner → TODO
- ❌ 死代码清扫(`InstallSettingsEditorBorder` / 0×0 隐藏按钮 / `Show-QuickCheckDialog`)→ 独立 v2 任务,已记 TODO
- ❌ 移动端 / 网页版任何东西
- ❌ Mac 端任何改动

### 不能动的范围
- 安装、运行、错误处理等业务逻辑全部保留,只动 UI 层
- 遥测代码不动(011 刚上线)
- deploy.sh 不动
- 任何已知陷阱清单里的修复点(避免回归)

## 6. 输入资源(Inputs)

### 设计稿
- 7 张 HTML mockup,绝对路径见任务交付文档(`mockups/011-windows-ui/01-07.html`)
- LauncherPalette 色 token:见 `git show a6807d0:macos-app/Sources/LauncherRootView.swift` 顶部 `private enum LauncherPalette`(本任务文档第 7.设计基线 节也有完整复制)
- UI-MAP:`mockups/011-windows-ui/UI-MAP.md` —— 现有 13 状态 + 9 对话框的真实代码地图

### 现有代码
- `HermesGuiLauncher.ps1`(5500+ 行 WPF)
- 现有 XAML 资源(在主 PowerShell 文件内嵌)

### 必须遵守的协作原则
- 工程师 Agent:走 5 层自检
- 质检员 Agent:重点验证"用户视角"——真机看一遍 7 个状态,vs mockup 对比;确认决策 A-F 全部到位
- 整合者 Agent:综合判定 + PM 真机验收清单
- **mockup 像素级对齐不是目标**,色调 / 圆角 / 字体 / 阴影 / 整体感觉对齐才是

### 已知相关陷阱(从 CLAUDE.md 摘录)
- **陷阱 #1**:WPF Dispatcher 异常处理 → UI 切换状态时所有 dispatch 必须 try-catch
- **陷阱 #2**:WPF ComboBox 内部 TextBox 事件绑定时机 → 用 Loaded 事件
- **陷阱 #4**:UI 信息位置错误 → 错误提示 / 进度反馈必须在用户视线焦点
- **陷阱 #5**:跨框架 API 替换需 UI 交互测试 → 这次大量 XAML 重写,必须真机点过
- **陷阱 #10**:测试通过 ≠ 用户找得到 → 主操作按钮、进度反馈、错误信息位置必须真机验证
- **陷阱 #21**:Set-Content 编码 → 任何写入持久化文件用 UTF-8 无 BOM

## 7. 设计基线 — LauncherPalette(完整色值,工程师直接用)

```
背景:
  bgApp           = #F2F0E8   (米色主背景)
  bgAppSecondary  = #EBE8E0
  bgGlow          = #F4C98A   (暖橙径向晕)

表面:
  surfacePrimary    = #FAF8F2  (卡片白米)
  surfaceSecondary  = #F4F0E8
  surfaceTertiary   = #F0E8DE
  surfaceHover      = #F2E6D6

文字:
  textPrimary    = #262621   (深棕黑)
  textSecondary  = #5E594F
  textTertiary   = #897F75
  textOnAccent   = #FCFCF7

强调:
  accentPrimary  = #D9772B   (主色暖橙)
  accentSoft     = #F2B56B
  accentDeep     = #A85420

状态:
  success     = #4F8F7A    successSoft = #DBEDE5
  warning     = #C78A3A    warningSoft = #F4E8D2
  danger      = #C25E52    dangerSoft  = #F7E0D8

线条:
  lineSoft   = rgba(0,0,0,0.06)
  lineSofter = rgba(0,0,0,0.04)

字体:
  英文 / 数字 → "SF Pro Rounded" 或 bundle 的 Quicksand / Manrope
  中文 → "Microsoft YaHei UI" / "PingFang SC"(Mac 上)
  代码 / 日志 → "JetBrains Mono" / "Consolas" / "Cascadia Code"

圆角:
  小元素(按钮、徽章) 8-10px
  中元素(卡片、对话框) 12-16px
  大元素(窗口、容器) 16-20px

阴影:
  柔和:0 8px 24px rgba(0,0,0,0.06) 或 0 4px 12px rgba(0,0,0,0.04)
  绝不要硬阴影
```

## 8. 期望产出(Deliverables)

### 文件层
- 修改 `HermesGuiLauncher.ps1` —— 主战场,XAML 大量重写
- 新增可能的 ResourceDictionary 段(在主文件内或拆出)
- 字体文件(如 bundle Quicksand / Manrope) → `assets/fonts/` 目录
- 升级版本号到 `v2026.05.02.1` 或类似(发版前)
- 更新 `README.md` 简单提一下"v2 视觉迁移完成"
- 更新 `index.html` 同步版本号

### 验证层
- 工程师产出报告(标准格式)
- 质检员评估报告 —— 重点核对"7 个状态都对得上 mockup"
- 整合者决策报告 —— 通过 / 返工
- PM 真机验收记录(5-10 张截图,7 个状态各一张)

### 学习层
- DECISIONS.md 追加:"2026-05-XX:Windows 端视觉首次向 Mac 对齐,WindowsPalette token 系统建立"
- TODO.md 追加:扩展到下次未完成的对话框 / 状态(如有)
- 如踩到新陷阱:加入 CLAUDE.md(WPF + 圆体字体 + 跨 DPI 等领域大概率有新坑)

## 9. 决策点(Decision Points)

### 已 PM 决策(直接落地,不用再问)

#### 决策 A:进度条 → **加**
所有等待场景(03/04/05/07)用 ProgressBar 控件 + 暖橙渐变。

#### 决策 B:步骤指示器 → **升级成卡片式**
现有"多行 ✓ ✓ → ○ 纯文本"全部换成卡片式步骤,success 绿表示完成、accent 暖橙脉动表示进行中、tertiary 灰表示待开始。

#### 决策 C:WebUI 启动可视化 → **做(7 段迷你步骤)**
修复 Home Mode 进度反馈盲区。中央放启动进度卡,展示 7 段状态机:环境 → 下载 Node → 解压 → 装 WebUI → 启 Gateway → 等就绪 → 启 WebUI。每段切换时主区域跟随更新。

#### 决策 D:安装中 4 段子阶段 → **加**
环境检查 / 下载依赖 / 安装组件 / 启动服务。三态(完成 / 进行中 / 待开始)。

#### 决策 E:失败摘要日志预览 → **保留**
深色 monospace 显示日志末尾几行(约 5-8 行),用户失败时第一时间看到错误。底下三按钮:重新开始 / 复制错误 / 查看完整日志。

#### 决策 F:关于对话框 4 个 pill 链接 → **不加**
保持当前关于对话框的极简,不引入 GitHub / 官网 / 文档 / 报告问题链接。

### 工程师 Agent 在产出方案时给 PM 选

#### 决策 G:字体策略
- A. **Bundle Quicksand 或 Manrope**(免费圆体字体)——视觉效果最好,代价是启动器 zip 多 200-400 KB
- B. **用系统 Segoe UI Variable**——Win11 自带,不需 bundle,但圆度不如 SF Rounded
- C. **混合**:中英文混排时英文走 bundle 圆体,中文走 Microsoft YaHei UI

工程师推荐一个,PM 拍板。

#### 决策 H:WindowsPalette 实现方式
- A. **嵌入 PowerShell 主文件内的 XAML 段**(简单,但难维护)
- B. **独立 ResourceDictionary 文件**(`assets/styles/WindowsPalette.xaml`)+ XAML Include —— 维护好但 PowerShell 加载略复杂
- C. **PowerShell 全局变量**`$script:Palette = @{ ... }`,XAML 用 Binding —— 灵活但 binding 字符串模板繁琐

工程师推荐一个,PM 拍板。

### AI 自主决策(不打扰 PM)
- ProgressBar 的具体动画时长 / 缓动曲线
- 卡片式步骤指示器的具体 padding / 间距
- 阴影具体数值(柔和 + 不刺眼即可)
- WebUI 启动 7 段步骤的文案(贴近真实代码状态机)
- 隐私 banner LocalStorage key 名 / 持久化位置

---

## 备注

这是 011 任务结束后的第一个产品功能任务。

特别注意:
- **scope 不要扩散**(陷阱 #4 教训):本次只做 Top-3,死代码 / 其他状态 / 其他对话框都已记 TODO,**不要顺手优化**
- **真机验收必须真**(陷阱 #10 教训):工程师自检通过 ≠ 用户视角 OK,QA 必须真机看 7 个状态 vs mockup
- **回归测试必须全**(陷阱 #5 教训):大量 XAML 重写,所有原有功能(安装 / 配置 / 错误处理 / 日志)必须真机走一遍确认没坏
- **遥测不要碰**:011 刚上线,任何这次改动都不能影响埋点函数(`Send-Telemetry` / `Get-OrCreateAnonymousId` 等)的行为
