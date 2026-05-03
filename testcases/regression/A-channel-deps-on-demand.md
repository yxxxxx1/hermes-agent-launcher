# A: 渠道依赖按需安装 3 条触发链(Bug A 回归)

**触发的 Bug**:已配置 Telegram / 微信 / 飞书等渠道但发消息无回应
**引入版本**:v2026.05.02.0(任务 011 之前；按需依赖始终是按需路径,但触发链不全)
**修复版本**:v2026.05.02.3(任务 014)
**关联陷阱**:CLAUDE.md #18, #19, #20, #22, #23, #27, #29, #39
**优先级**:P0
**适用版本**:v2026.05.02.3 及以上

> 本文件包含 3 条独立用例:
> - **A.1**:`.env` watcher 失效时,polling 60 秒兜底
> - **A.2**:已运行的 Gateway 由前次会话启动,本次启动器要能自动接管并响应 .env 变化
> - **A.3**:`uv pip install` 失败时,UI 必须显式上报(横幅 + 详情 + 主按钮变灰)

---

## A.1: `.env` watcher 失效 → polling 兜底必须 60 秒内重启 Gateway

### 前置条件
- 操作系统:Win10 / Win11
- hermes 状态:已装,Gateway 当前正在运行
- .env 内容:**没有** `TELEGRAM_BOT_TOKEN`(或值为空)
- 网络环境:任意
- 其他:防病毒软件 / 安全策略 **可能** 拦截 FileSystemWatcher 通知(无法本地稳定模拟,可用 `Set-MpPreference` 模拟拦截或用网络盘测试)

### 测试步骤
1. 启动器进入 Home Mode,主面板显示"已就绪"
2. 用文件浏览器或文本编辑器**直接修改** `%USERPROFILE%\.hermes\.env`(模拟 watcher 失效场景):追加一行 `TELEGRAM_BOT_TOKEN=test_token_for_polling_fallback`
3. 立即记录当前 Gateway 进程 PID(任务管理器 / `Get-Process hermes`)
4. **等待 70 秒**(60 秒 polling + 10 秒缓冲)
5. 重新查 Gateway 进程 PID,与步骤 3 比较

### 预期结果
- 步骤 2 后:.env 文件被修改成功(文件大小 + LastWriteTime 都变了)
- 步骤 4 内(60 秒以内):启动器日志显示 `.env polling 兜底检测到变化(watcher 可能未触发),准备重启 Gateway...`
- 步骤 5:Gateway 进程 PID **不同于** 步骤 3 的 PID(已重启)
- `.env` watcher 即使失效,polling 在 60 秒内必能感知变化并触发重启

### 执行证据
- [ ] 步骤 2 截图(.env 修改前后):`testcases/regression/_evidence/A1-env-diff.png`
- [ ] 步骤 4 启动器日志 tail 30 行:`testcases/regression/_evidence/A1-launcher.log`(必须包含 "polling 兜底检测到变化")
- [ ] 步骤 5 PID 对比:旧 PID=______,新 PID=______
- [ ] 通过 / 未通过 / **无法本地验证(sandbox 没有 70 秒等待 + 真实文件 watcher 行为)**
- [ ] 备注:工程师 sandbox 没法模拟 watcher 失效,polling 路径需 PM 真机抽查

### 失败处理
- 步骤 5 PID 不变 → polling timer 未启动或未触发,检查 `Start-GatewayEnvWatcher` 中 `$script:EnvWatcherPollingTimer` 是否成功赋值并 `Start()`
- 日志没有 polling 提示 → 60 秒间隔可能被改;检查 `$polling.Interval = [TimeSpan]::FromSeconds(60)`
- 是否需要新建陷阱条目:**是**(如果是新症状)

---

## A.2: 已运行 Gateway 来自前次会话 → 本次启动器要能 derive `GatewayHermesExe` 并重启

### 前置条件
- 操作系统:Win10 / Win11
- hermes 状态:已装(`%LOCALAPPDATA%\hermes\hermes-agent\venv\Scripts\hermes.exe` 存在)
- Gateway:**前次启动器会话**已启动并仍在运行(PID 存在,/health 返回 200)
- .env 内容:**没有** `TELEGRAM_BOT_TOKEN`
- 启动器:**前次进程已关闭**(关窗口 / 任务管理器结束),本次会话刚启动

### 测试步骤
1. 关闭启动器窗口(确保前次会话结束)
2. 重新双击 `Start-HermesGuiLauncher.cmd`,启动新会话
3. 启动器进入 Home Mode,**不点击**"开始使用"(模拟 .env 直接被外部进程修改)
4. 用 webui 之外的方式编辑 `%USERPROFILE%\.hermes\.env`,加入 `TELEGRAM_BOT_TOKEN=test_a2`
5. 等 5-65 秒(覆盖 watcher + polling 路径)
6. 查 Gateway 进程 PID 是否变化

### 预期结果
- 步骤 3 后:启动器虽未点"开始使用",但 .env watcher 应已通过`Start-HermesWebUiRuntime` 之外的路径启动 - **本用例考察的是 watcher 触发后能否找到 hermes.exe**
- 步骤 5 内:启动器日志出现 `Gateway 可执行文件已从 InstallDir 推导:...`(说明 fast path 之外也能 derive `$script:GatewayHermesExe`)
- 步骤 6:Gateway PID 已变化(前次 PID 被杀,新 PID 接管)
- 不再出现陷阱 #27 的"silently skip"现象

### 执行证据
- [ ] 步骤 4 .env 修改证据(LastWriteTime 截图):`testcases/regression/_evidence/A2-env-mtime.png`
- [ ] 步骤 5 启动器日志:`testcases/regression/_evidence/A2-launcher.log`
- [ ] 步骤 6 PID 对比:旧 PID=______,新 PID=______
- [ ] 通过 / 未通过 / **无法本地验证(sandbox 没有跨会话场景 + .env watcher 不触发)**
- [ ] 备注:工程师对照代码改动验证了 `Restart-HermesGateway` 的 fallback 逻辑(`$script:GatewayHermesExe` 为 null 时从 `$controls.InstallDirTextBox.Text` + 默认 LOCALAPPDATA 推导),需 PM 真机抽查实际 PID 变化

### 失败处理
- PID 没变化:`Restart-HermesGateway` 仍走 silent skip 路径,检查 fallback 推导 + `Test-Path` 是否对路径返回 true
- 日志中没有"已从 InstallDir 推导":可能 `$script:GatewayHermesExe` 在某条早期路径已经被赋值,本次走的是 happy path
- 是否需要新建陷阱条目:**是**(如果发现新的 silent skip 路径)

---

## A.3: `uv pip install` 失败 → 必须红色横幅 + 错误详情 + 主按钮变灰

### 前置条件
- 操作系统:Win10 / Win11
- hermes 状态:已装
- .env 内容:`TELEGRAM_BOT_TOKEN=test_a3`(配置了渠道但 Python 包未装)
- 网络环境:**断网 / 故意指向不可用的 PyPI 镜像**(模拟 install 失败)
  - 模拟方式:在 launcher 启动前临时把 `pip.conf` 的 index-url 改成 `http://127.0.0.1:65535/simple/`(确保连不上)
  - 或:断网卡 / 设防火墙拦截 pip
- Gateway:正在运行
- 其他:`python-telegram-bot` 未安装(`venv\Scripts\python.exe -c "import telegram"` 报 ModuleNotFoundError)

### 测试步骤
1. 启动启动器,进入 Home Mode
2. 模拟网络故障(见前置条件)
3. 触发 `Install-GatewayPlatformDeps`(任意一条触发链):
   - **方式 a**:点"开始使用"走 fast path
   - **方式 b**:用 webui 修改 .env(让 watcher 触发)
   - **方式 c**:等 60 秒让 polling 触发
4. 等 30-60 秒让 `uv pip install` 跑完(失败)
5. 观察主面板

### 预期结果
- 步骤 3 后:启动器日志出现 `正在安装渠道依赖:python-telegram-bot...` + 后续 `python-telegram-bot 安装失败(退出码 N)`
- 步骤 5 后:
  - 主面板顶部出现**红色横幅**:"渠道依赖安装失败:Telegram。点这里查看详情"(`HomeDepFailureBanner` 的 Visibility=Visible)
  - 主按钮"开始使用" → 文案变 "渠道依赖未就绪",IsEnabled=false
  - 横幅可点击(`Cursor=Hand`),点 "查看详情" → 弹窗显示错误尾部 50 行 + "复制错误内容"按钮
- Dashboard 应收到 `platform_dep_install_failed` 事件,payload 含 channel=`TELEGRAM_BOT_TOKEN`、package=`python-telegram-bot`、exit_code、error_tail

### 执行证据
- [ ] 步骤 5 主面板截图(横幅 + 灰色主按钮):`testcases/regression/_evidence/A3-banner.png`
- [ ] 详情弹窗截图(错误尾部):`testcases/regression/_evidence/A3-dialog.png`
- [ ] 复制按钮验证(剪贴板内容):`testcases/regression/_evidence/A3-clipboard.txt`
- [ ] Dashboard 事件 ID(`platform_dep_install_failed`):`telemetry_event_id=_______________`
- [ ] 通过 / 未通过 / **无法本地验证(sandbox 没法模拟 pip 失败 + 没法点 UI)**
- [ ] 备注:工程师在代码中验证了 `Install-GatewayPlatformDeps` 失败分支会写入 `$script:LastDepInstallFailure` + 调用 `Send-Telemetry -EventName 'platform_dep_install_failed'`;UI 显示逻辑在 `Refresh-Status` 的 Home Mode 块。横幅 XAML 已通过独立 XAML 加载测试(`D:\Temp\test_xaml3.ps1`)。需 PM 真机断网验证。

### 失败处理
- 步骤 5 没看到横幅:
  - 检查 `$script:LastDepInstallFailure` 是否被正确赋值(在 `Install-GatewayPlatformDeps` 失败分支)
  - 检查 `Refresh-Status` 是否在 Install 失败后被调用(`Restart-HermesGateway` 末尾应有 `Request-StatusRefresh`)
  - 检查 `$controls.HomeDepFailureBanner` 是否在 controls 字典里(检索注册名清单)
- 主按钮没变灰:检查 `Set-PrimaryAction -ActionId 'launch' -Label '渠道依赖未就绪' -Enabled $false` 这一行是否真的执行
- Dashboard 没收到事件:检查 telemetry endpoint 是否白名单了 `platform_dep_install_failed`(本任务新增事件,Worker 端可能要补白名单 — 但这超出启动器范围,记 TODO)
- 是否需要新建陷阱条目:**是**(如果 watcher 触发链 vs polling 触发链行为不一致)
