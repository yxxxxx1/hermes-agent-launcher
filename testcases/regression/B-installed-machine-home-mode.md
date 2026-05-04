# B: 已装机器开启动器必须直接 Home Mode(Bug B 回归)

**触发的 Bug**:已装 Hermes 的用户每次重开启动器仍看到 "安装/更新 Hermes" 安装流程
**引入版本**:v2026.04.24 起(OpenClaw 迁移逻辑加进 Refresh-Status)
**修复版本**:**待 PM 决定**(任务 014 修复 commit `effe9b7` + QA Patch round 1;PM 决定是否 bump 到 v2026.05.02.3 或后续版本)
**关联陷阱**:CLAUDE.md #10(找得到≠信息存在)、#27、Bug B
**优先级**:P0
**适用版本**:任务 014 commit `effe9b7` 及以上(发版后追加版本号)

> 根因:`Refresh-Status` 在 L6145 的判断 `((-not $isInstalled) -or $pendingOpenClaw)` 把已装 + 残留 OpenClaw 目录的机器误判为"需要 Install Mode"。本任务把条件简化成 `(-not $isInstalled)`,OpenClaw 迁移功能改为 Home Mode 内的横幅(保留迁移按钮)。

---

## B.1: 已装机器(无 OpenClaw 残留)→ 直接 Home Mode

### 前置条件
- 操作系统:Win10 / Win11
- hermes 状态:已装(`%LOCALAPPDATA%\hermes\hermes-agent\venv\Scripts\hermes.exe` 存在)
- .env 内容:任意
- OpenClaw 残留:**没有**(`%USERPROFILE%\.openclaw`、`.clawdbot`、`.moldbot` 都不存在)
- 启动器状态:之前已成功运行至少一次

### 测试步骤
1. 确认无 OpenClaw 残留:`Test-Path $env:USERPROFILE\.openclaw, $env:USERPROFILE\.clawdbot, $env:USERPROFILE\.moldbot` 全部 False
2. 关闭启动器(任务管理器确保无 `pwsh.exe -File HermesGuiLauncher.ps1` 进程)
3. 双击 `Start-HermesGuiLauncher.cmd` 启动启动器
4. 等启动器主窗口完全渲染(< 5 秒)
5. 观察主面板内容

### 预期结果
- 步骤 4 后:**HomeModePanel.Visibility = Visible**,InstallModePanel.Visibility = Collapsed
- 主按钮文案 = "开始使用",可点击
- 不出现:"安装/更新 Hermes"、"正在检测环境"、3 阶段步骤指示器、Install 进度卡、LogSectionBorder
- 不出现:OpenClaw 横幅(因为没有残留)
- 不出现:渠道依赖失败横幅(因为没有失败)

### 执行证据
- [ ] 步骤 5 截图:`testcases/regression/_evidence/B1-home.png`
- [ ] 启动器日志(确认无 install 路径相关行):`testcases/regression/_evidence/B1-launcher.log`
- [ ] 通过 / 未通过 / **无法本地验证(sandbox 没法跑 GUI)**
- [ ] 备注:工程师对照代码改动验证了 `Refresh-Status` 在 `$isInstalled = true` 时直接走 else 分支(Home Mode)。需 PM 真机抽查。

### 失败处理
- 仍出现 Install Mode → Bug B 复发,检查 `Refresh-Status` L6145 附近的 `if (-not $isInstalled)`(应**没有** `-or $pendingOpenClaw` 部分)
- 是否需要新建陷阱条目:**是**(如果是新场景)

---

## B.2: 已装机器 + OpenClaw 残留(常见的 Bug B 真实触发场景)→ Home Mode + 横幅

### 前置条件
- 操作系统:Win10 / Win11
- hermes 状态:已装
- OpenClaw 残留:**存在**(`%USERPROFILE%\.openclaw` 是个目录)
- launcher-state.json:`openclaw_imported=false` 且 `openclaw_skipped=false`(默认值)
- 启动器:之前已成功运行(产生过 launcher-state.json)

### 制造前置条件(测试人员准备步骤)
```powershell
New-Item -ItemType Directory -Path "$env:USERPROFILE\.openclaw" -Force | Out-Null
# 写一些假数据让目录看起来像旧版残留
New-Item -ItemType File -Path "$env:USERPROFILE\.openclaw\config.yaml" -Force | Out-Null
# 删掉 launcher-state.json(让 OpenClawImported / OpenClawSkipped 都回到 false)
Remove-Item "$env:USERPROFILE\.hermes\launcher-state.json" -Force -ErrorAction SilentlyContinue
```

### 测试步骤
1. 制造前置条件(见上)
2. 确认 `Test-Path $env:USERPROFILE\.openclaw` = True
3. 关闭启动器,确保无残留进程
4. 双击 `Start-HermesGuiLauncher.cmd` 启动启动器
5. 等主窗口完全渲染
6. 观察主面板

### 预期结果
- 步骤 5 后:**HomeModePanel.Visibility = Visible**(不是 Install Mode!)
- 主按钮文案 = "开始使用",可点击
- 顶部出现 OpenClaw 横幅(`HomeOpenClawBanner`),文案 = "检测到旧版 OpenClaw 配置,可按需迁移;不影响继续使用。"
- 横幅右侧有 "立即迁移" 和 "稍后再说" 两个按钮
- 点 "稍后再说" → 横幅消失,主按钮"开始使用"仍可点
- 点 "立即迁移" → 触发 `openclaw-migrate` action(打开终端跑 `hermes claw migrate --preset full`)

### 执行证据
- [ ] 步骤 5 截图(Home Mode + OpenClaw 横幅):`testcases/regression/_evidence/B2-home-with-banner.png`
- [ ] 点"稍后再说"后截图(横幅消失):`testcases/regression/_evidence/B2-after-skip.png`
- [ ] launcher-state.json 内容(应显示 openclaw_skipped=true):`testcases/regression/_evidence/B2-state.json`
- [ ] 通过 / 未通过 / **无法本地验证(sandbox 没法跑 GUI)**
- [ ] 备注:工程师对照代码改动验证了:1)`Refresh-Status` 不再用 `pendingOpenClaw` 进 Install Mode;2)Home Mode 块在 `pendingOpenClaw=true` 时显示 `HomeOpenClawBanner`;3)`HomeOpenClawImportButton` / `HomeOpenClawSkipButton` 的 click handler 调用 `Invoke-AppAction 'openclaw-migrate' / 'openclaw-skip'`(同已有 InstallMode 内的按钮)。XAML 已通过独立 load 测试。需 PM 真机抽查。

### 失败处理
- 出现 Install Mode → Bug B 未修复,检查 `Refresh-Status` L6145 是否真的把 `pendingOpenClaw` 从条件里拿掉
- Home Mode 没看到 OpenClaw 横幅 → 检查 `$controls.HomeOpenClawBanner` 是否在 controls 字典里 + Refresh-Status Home Mode 块的 Visibility 设置
- "立即迁移" 按钮无反应 → 检查 `$controls.HomeOpenClawImportButton.Add_Click` 是否绑定到 `Invoke-AppAction 'openclaw-migrate'`
- 是否需要新建陷阱条目:**否**(本场景已纳入陷阱 #10 / #27 范畴)

---

## B.3:启动器关闭再开 ≠ 重新装(对 TC-005 的精确化)

### 前置条件
- 操作系统:Win10 / Win11
- hermes 状态:已装,webui 已配过模型,用过对话(`launcher-state.json` 中 `local_chat_verified=true`)
- OpenClaw 残留:**存在**(强化测试条件)
- launcher-state.json:`openclaw_imported=false`、`openclaw_skipped=false`

### 测试步骤
1. 启动器第一次:正常打开 webui 用了一段时间,关闭
2. 等 5 秒确保后台进程清理
3. 第二次双击启动器
4. 主窗口渲染完成后观察
5. 点"开始使用",观察是否需要重新装东西

### 预期结果
- 步骤 4 后:第二次开启与第一次完全一致 — 直接 Home Mode + OpenClaw 横幅(如有残留)
- 步骤 5 后:点"开始使用" → 直接打开 webui,不重新装 Node.js / web-ui
- 启动到 webui 打开 < 30 秒(快路径)

### 执行证据
- [ ] 步骤 4 第二次启动截图:`testcases/regression/_evidence/B3-second-open.png`
- [ ] 步骤 5 点击到 webui 打开的耗时:______ 秒
- [ ] 启动器日志确认无 install 路径调用:`testcases/regression/_evidence/B3-launcher.log`
- [ ] 通过 / 未通过 / **无法本地验证(sandbox 没法跑 GUI)**
- [ ] 备注:验证 Bug B 修复后多次开启行为一致。需 PM 真机抽查。

### 失败处理
- 第二次出现 Install Mode → Bug B 复发或新场景
- 重装 Node.js / web-ui → InstallDir 检测失败,陷阱 #16 残留目录或 settings.json 丢失
- 是否需要新建陷阱条目:**是**(如果是新场景)
