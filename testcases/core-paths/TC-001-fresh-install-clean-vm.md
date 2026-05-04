# TC-001: 首次安装在干净 Win VM

**优先级**:P0
**关联陷阱**:CLAUDE.md #16(残留目录)、#17(终端闪退)、#18(gateway --replace)、#20(api 端口)、#22(WebUI GatewayManager 30s 杀)、#23(gateway 未就绪启 webui)、#27(快速路径)
**适用版本**:v2026.05.02.2 及以上

## 前置条件
- 操作系统:Win10 22H2 或 Win11 26200,中文或英文均可
- 硬件:全新 VM 或刚装好系统的物理机,**`%LOCALAPPDATA%\hermes` 目录不存在**
- hermes 状态:**未装**(无 hermes-agent / hermes-web-ui 任何痕迹)
- .env 内容:不存在
- 网络环境:海外网络畅通(不走国内镜像)
- 其他:管理员账号,关闭杀毒软件实时防护(避免干扰首次测试)

## 测试步骤
1. 解压最新版 `Hermes-Windows-Launcher-v2026.05.02.2.zip` 到桌面
2. 双击 `Start-HermesGuiLauncher.cmd`,首次启动看到 EULA 时点"同意"
3. 主面板加载完成 → 看到 **Install Mode**(主按钮文案"安装/更新 Hermes")
4. 点击主按钮"安装/更新 Hermes"
5. 弹出"确认安装位置"对话框 → 保持默认 → 点"开始安装"
6. 终端窗口出现,自动跑安装脚本(预计 3-8 分钟)
7. 终端窗口正常关闭(无报错弹窗 / 无 5 秒缓冲提示"如有报错请截图")
8. 启动器主面板自动刷新到 **Home Mode**(主按钮"开始使用")

## 预期结果
- 步骤 2 后:看到 EULA 对话框,文案完整无乱码
- 步骤 3 后:Install Mode 显示完整 UI(背景米色 + 暖橙主按钮 + 进度卡)
- 步骤 6 中:终端窗口里看到"安装 hermes-agent"、"安装 hermes-web-ui"、"安装 Node.js"等阶段标题
- 步骤 7 后:终端**不闪退**,即使成功也保留 5 秒
- 步骤 8 后:主按钮变为"开始使用",可点击;主面板背景变浅米色
- `%LOCALAPPDATA%\hermes\hermes-agent\` 目录存在,内含 `Scripts\hermes.exe`、`config\config.yaml`
- 无任何"无法找到指定文件" / "WinError 267" / "GBK codec" 报错

## 执行证据(发版前由 agent / PM 填)
- [ ] 步骤 3 截图(Install Mode 主面板):`testcases/core-paths/_evidence/TC-001-step3.png`(待 PM 真机验收时填)
- [ ] 步骤 6 终端窗口截图:`testcases/core-paths/_evidence/TC-001-step6.png`(待 PM 真机验收时填)
- [ ] 步骤 8 截图(Home Mode):`testcases/core-paths/_evidence/TC-001-step8.png`(待 PM 真机验收时填)
- [ ] 安装日志全文:`testcases/core-paths/_evidence/TC-001-install.log`(待 PM 真机验收时填)
- **状态**:**无法本地验证(原因:sandbox 没有干净 Win VM,且当前已装 hermes)**
- 备注:任务 014 工程师在 sandbox 上无法重置到全新 Win 环境,且任务 014 修复点不触及 install 主路径(只动了 Refresh-Status 条件、watcher polling、Restart-HermesGateway fallback 与 try-catch 包裹)。Install 主路径的回归风险**理论上低**——`Test-HermesInstalled` / `Resolve-HermesCommand` / `Test-InstallPreflight` 全部未改;`Refresh-Status` 在 `(-not $isInstalled)` 分支(即未装)的 Install Mode 渲染逻辑保持原样。需 PM 真机抽查或下次 Phase 2 摸底任务覆盖。

## 失败处理
- 终端闪退:陷阱 #17 复发 → 检查 wrapper 脚本的 5 秒缓冲逻辑
- "无法找到指定文件":陷阱 #16 残留目录或陷阱 #24 WSL bash → 检查 robocopy 清理 + Git Bash PATH
- 安装完成但 Home Mode 没出来:Bug B 复发 → 见 TC-002 / 陷阱待补
- 是否需要新建陷阱条目:**是**(如果命中新症状),按 CLAUDE.md "经验沉淀强制流程"加入清单
