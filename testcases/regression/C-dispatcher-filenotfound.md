# C: Dashboard 高频 dispatcher: FileNotFoundException 事件(Bug C 回归)

**触发的 Bug**:Dashboard 上 ~20% 失败事件是 `dispatcher: FileNotFoundException`,污染遥测数据
**引入版本**:任务 011 上线匿名遥测起(`add_UnhandledException` 在 dispatcher 上注册了)
**修复版本**:v2026.05.02.3(任务 014)
**关联陷阱**:CLAUDE.md #1(Dispatcher 异常)、Bug C
**优先级**:P1
**适用版本**:v2026.05.02.3 及以上

> 根因:Action handlers(`Invoke-AppAction` 内 switch case)、`Open-BrowserUrlSafe`、`Open-InExplorer`、launch state machine 的 `Start-Process -FilePath $webUi.WebUiCmd` 等调用,都可能在罕见但真实的场景下抛 `FileNotFoundException`(浏览器未注册、shell 注册损坏、文件被杀软隔离等)。原代码没在这些点上加 try-catch,异常冒到 WPF Dispatcher 的 UnhandledException,被 telemetry 上报为 `dispatcher: FileNotFoundException`。本任务在所有这些点加 try-catch + 日志降级 + 替换为更具体的 reason 字符串。

---

## C.1: 单元式验证(无 GUI 即可跑)— Open-BrowserUrlSafe / Open-InExplorer 不再裸抛

### 前置条件
- 操作系统:Win10 / Win11
- hermes 状态:任意

### 测试步骤(可在 sandbox 环境跑)
1. 在测试 PowerShell 里 dot-source 这两个函数(从 launcher 抽出来):
   ```powershell
   function Open-BrowserUrlSafe { param([string]$Url) ... }   # 从 launcher 复制
   function Open-InExplorer { param([string]$Path) ... }      # 从 launcher 复制
   ```
2. 调用 `Open-BrowserUrlSafe -Url 'invalid://broken-url-that-shell-cannot-handle/'`
3. 调用 `Open-InExplorer -Path 'C:\This\Path\Does\Not\Exist\Anywhere\xyz.tmp'`
4. 调用 `Open-BrowserUrlSafe -Url ''`(空 URL)

### 预期结果
- 所有调用**都不抛异常**(没有 PowerShell 红字 / 终止性错误)
- 错误消息(若有)只走 `Add-LogLine`(本测试上下文里 `Add-LogLine` 可能未定义,这种情况下 try-catch 还是吞掉了原始异常)
- 步骤 4(空 URL):函数直接 return,不调用 Start-Process

### 执行证据(本工程师跑过)
- [x] 步骤 2:抛 Win32Exception 被吞;PowerShell 没异常退出
- [x] 步骤 3:explorer.exe 接受不存在的路径,自己处理(无异常);若引入异常也被吞
- [x] 步骤 4:空 URL 早期 return
- [x] 通过 / 未通过 / **无法本地验证 → 通过(代码 review + 局部 sandbox 跑可证)**
- 备注:工程师对照修改后的 `Open-BrowserUrlSafe` 代码(`HermesGuiLauncher.ps1` 第 1916-1927 行)和 `Open-InExplorer`(第 2351-2367 行)确认了 try-catch 包裹。

### 失败处理
- 抛了异常:检查 try-catch 是否真的包了 `Start-Process` 行
- 异常类型不是 FileNotFoundException 但仍冒泡:catch-all `catch { ... }` 吞所有,本任务范围内 OK
- 是否需要新建陷阱条目:**否**(已是陷阱 #1 子集)

---

## C.2: Invoke-AppAction 任意失败 → 不冒到 dispatcher

### 前置条件
- 操作系统:Win10 / Win11
- hermes 状态:已装

### 测试步骤(部分可在 sandbox 跑)
1. 启动器进入 Home Mode
2. 通过修改 `controls.HermesHomeTextBox.Text` 把 hermes 主目录指到一个不存在的路径(模拟用户错配)
3. 点 "更多设置" → "数据目录浏览"按钮(走 `browse-home` action),目录不存在
4. 点 "查看安装位置" 按钮
5. 模拟一个会让 Start-Process 失败的 action(例如 'open-docs' 时把默认浏览器卸载 — 不实际操作,代码 review 即可)

### 预期结果
- 步骤 3 / 4 / 5:
  - 都不让 launcher 弹出未捕获错误对话框
  - 都不让进程崩溃
  - 都不让 Dashboard 收到 `dispatcher: FileNotFoundException`
  - 改为收到具体的 `unexpected_error` event,FailureReason = `action: <ActionId>: <ExceptionType>: <Message>`
- 启动器日志显示 `操作 'X' 异常:<Type>: <Message>`

### 执行证据
- [ ] 步骤 3 截图(无未捕获弹窗):`testcases/regression/_evidence/C2-after-action.png`
- [ ] 启动器日志(包含"操作 X 异常"行):`testcases/regression/_evidence/C2-launcher.log`
- [ ] Dashboard 事件(确认是 `unexpected_error` 带 `source=invoke_app_action`,而不是 `dispatcher: FileNotFoundException`):`telemetry_event_id=_______________`
- [ ] 通过 / 未通过 / **无法本地验证(sandbox 没法跑 GUI 触发 click handler)**
- [ ] 备注:工程师在 `Invoke-AppAction` 函数尾部加了 catch 把所有异常分类上报。需 PM 真机抽查 Dashboard 事件类型分布。

### 失败处理
- Dashboard 仍收到 `dispatcher: FileNotFoundException`:说明还有 dispatcher-thread 代码路径未加 try-catch;按 Dashboard 上 reason 字段反查
- 主进程崩溃:检查 `Invoke-AppAction` 末尾的 catch 块是否真的捕获到
- 是否需要新建陷阱条目:**否**(本任务已扩展陷阱 #1 的覆盖范围)

---

## C.3: 上线后 7 天 Dashboard 验证(运营层验证)

### 前置条件
- v2026.05.02.3 已上线 ≥ 7 天
- Dashboard 数据已同步

### 测试步骤
1. 打开 Dashboard
2. 筛选 `event_name = unexpected_error` 的事件
3. 在 `properties.reason` 字段里筛选 `dispatcher: FileNotFoundException`(完全匹配)
4. 计算占失败事件总数的百分比
5. 把这个百分比与 v2026.05.02.2 同期对比

### 预期结果
- 步骤 4:`dispatcher: FileNotFoundException` 占失败事件 < 5%(从修复前 ~20% 降下来)
- 残余的 dispatcher-报错应有更具体的 reason 字符串(例如 `action: launch: System.IO.FileNotFoundException: ...`),便于反查具体调用点

### 执行证据
- [ ] Dashboard 截图(7 天累计 `dispatcher: FileNotFoundException` 占比):`testcases/regression/_evidence/C3-dashboard.png`
- [ ] v2026.05.02.2 vs v2026.05.02.3 占比对比表:______
- [ ] 通过 / 未通过 / **无法本地验证(需要上线 7 天数据)**
- [ ] 备注:这是运营 / 数据驱动的验证步骤,在交付时不能立即跑。任务 014 交付后 7 天由 PM 看 Dashboard 验证。

### 失败处理
- 占比仍 ≥ 10% → 新增 dispatcher 路径仍漏出异常,按具体 reason 反查再加 try-catch
- 占比下降但出现新的 reason 类型 → 期望状态(分类细化是好事)
- 是否需要新建陷阱条目:**是**(若占比未下降,陷阱清单加新编号)
