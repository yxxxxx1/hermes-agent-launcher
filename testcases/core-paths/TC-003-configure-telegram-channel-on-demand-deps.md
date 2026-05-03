# TC-003: webui 配 Telegram → 自动装 python-telegram-bot

**优先级**:P0
**关联陷阱**:CLAUDE.md #18、#19(.env watcher 早退)、#20、#22、#23、#27、#39(venv 进程过滤)、Bug A(Task 014 修复中)
**适用版本**:v2026.05.02.2 及以上(Bug A 修复后才能稳定通过)

## 前置条件
- 操作系统:Win10 / Win11 任意版本
- hermes 状态:**已装**,gateway 当前**正在运行**(`gateway.pid` 存在 + 8642 端口监听)
- .env 内容:**没有** `TELEGRAM_BOT_TOKEN` 或值为空
- 网络环境:海外网络畅通(用户能正常访问 t.me 创建 bot)
- 其他:用户已通过 @BotFather 创建好一个 Telegram bot 并拿到 token

## 测试步骤
1. 启动器在 Home Mode,点"开始使用",等浏览器打开 webui(http://127.0.0.1:8643)
2. webui 显示已连接(右上角绿色或文案"已连接")
3. 进入"渠道配置" → 选 Telegram
4. 粘贴 bot token → 点"保存"
5. 等待 30-60 秒(此时启动器后台应自动:检测 .env 变化 → 装 python-telegram-bot → 重启 gateway)
6. 在 Telegram 中向自己的 bot 发送 "hi"
7. 等待 bot 回复(不超过 30 秒)

## 预期结果
- 步骤 4 后:webui 显示保存成功,`%LOCALAPPDATA%\hermes\hermes-agent\config\.env` 文件多出 `TELEGRAM_BOT_TOKEN=xxx`
- 步骤 5 内:启动器日志(或 Dashboard 上)出现:
  - `env_changed` 事件
  - `platform_dep_install_started`(可选)
  - `platform_dep_install_succeeded`(payload: 渠道=telegram, package=python-telegram-bot)
  - `gateway_restart_started` + `gateway_restart_succeeded`
- 步骤 5 后:gateway 进程 pid 变化(老进程被杀,新进程起来),`gateway.pid` 文件更新
- 步骤 7 后:**bot 必须有回复**(说明依赖装上 + gateway 加载到了 telegram 平台)
- **无任何**"消息发出去 bot 没回应"的现象

## 执行证据(发版前由 agent / PM 填)
- [ ] 步骤 4 截图(.env 修改前后):`testcases/core-paths/_evidence/TC-003-env-diff.png`(待 PM 真机验收时填)
- [ ] 步骤 5 启动器日志:`testcases/core-paths/_evidence/TC-003-launcher.log`(待 PM 真机验收时填)
- [ ] 步骤 7 Telegram 截图(bot 回复):`testcases/core-paths/_evidence/TC-003-bot-reply.png`(待 PM 真机验收时填)
- [ ] gateway 重启前后 pid 对比:旧 pid=______,新 pid=______(待 PM 真机验收时填)
- [x] Bug A.1 polling 兜底代码 review:**`Start-GatewayEnvWatcher` 末尾新增 `$polling = DispatcherTimer + 60s + Add_Tick { Get-EnvFileSignature 比较 }`**;`Stop-HermesWebUiRuntime` 同步加了 polling timer 清理
- [x] Bug A.2 derive `GatewayHermesExe` 代码 review:**`Restart-HermesGateway` 当 `$script:GatewayHermesExe` 为 null 时,从 `controls.InstallDirTextBox.Text` + LOCALAPPDATA 推导**(陷阱 #27 升级版)
- [x] Bug A.3 失败上报代码 review:**`Install-GatewayPlatformDeps` 失败分支写 `$script:LastDepInstallFailure` + 调用 `Send-Telemetry -EventName 'platform_dep_install_failed'`**;成功分支清除该字段
- [x] XAML `HomeDepFailureBanner` 加载验证:`testcases/regression/_evidence/M1-xaml-banner-relocation.txt` 显示 `HomeDepFailureBanner: True`
- **状态**:**部分通过(代码逻辑通过,真机渠道行为无法本地验证)**
- 备注:工程师 sandbox 没法构造真实 .env watcher 行为(60 秒 polling 等待 + 真实 .env 修改触发 watcher)+ 没法跑 `uv pip install` + 没有 Telegram 账号。**60 秒 polling 路径 + 真实 install 失败的 UI 显示 + bot 实际回复需 PM 真机验证**。

## 失败处理
- bot 不回应 + .env 没改:webui → .env 写入失败,陷阱 #21 GBK 编码可能命中
- bot 不回应 + .env 改了 + gateway 没重启:陷阱 #19 watcher 失效 / 陷阱 #27 GatewayHermesExe 为空 → Bug A 修复中的 polling 兜底没起作用
- bot 不回应 + gateway 重启了 + 没装 python-telegram-bot:`Install-GatewayPlatformDeps` 触发链漏点
- bot 不回应 + 装了依赖 + gateway 重启了:陷阱 #20 端口 / 陷阱 #22 GatewayManager 杀进程 / 陷阱 #39 venv 残留进程
- 是否需要新建陷阱条目:**是**(如果是新症状)
