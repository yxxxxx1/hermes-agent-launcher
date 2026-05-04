# TC-007: 中文用户名 / 路径

**优先级**:P0
**关联陷阱**:CLAUDE.md #16(残留目录 robocopy)、#21(Set-Content GBK 破坏 UTF-8)、#24(WSL bash POSIX 路径)、#25(Windows pipe select.select)、#26(node_modules .bin POSIX shell stub)
**适用版本**:v2026.05.02.2 及以上

## 前置条件
- 操作系统:Win10 / Win11 中文版 22H2/26200
- 用户名:**中文**(例:`张三` / `小明`,`%USERPROFILE%` 路径形如 `C:\Users\张三`)
- hermes 状态:未装(干净状态)
- .env 内容:不存在
- 网络环境:海外或国内均可(国内更接近真实用户)
- 其他:**未装** WSL,或 WSL 已禁用 PATH 中的 `bash.exe`

## 测试步骤
1. 在中文用户名账号下解压 launcher zip 到桌面(`C:\Users\张三\Desktop\Hermes-Windows-Launcher\`)
2. 双击 `Start-HermesGuiLauncher.cmd` 启动启动器
3. 走完首次安装流程(EULA → Install Mode → 点击安装 → 终端跑安装脚本)
4. 终端窗口安装完成,启动器主面板进入 Home Mode
5. 点"开始使用",等 webui 打开
6. 在 webui 配置一个 Telegram 渠道(粘贴 token,保存)
7. 给 bot 发消息,等待回复

## 预期结果
- 全程**无任何**以下报错(任何位置出现都算失败):
  - "无法找到指定文件" / "WinError 267" / "NotADirectoryError"(陷阱 #24 路径处理)
  - "GBK codec can't encode" / "UnicodeEncodeError" / YAML 解析错误(陷阱 #21 Set-Content)
  - "MS-DOS 功能无效"(陷阱 #16 残留目录)
  - "WinError 10093"(陷阱 #25 select.select)
  - "%1 不是有效的 Win32 应用程序"(陷阱 #26 .bin shell stub)
- 安装目录路径含中文(例:`C:\Users\张三\AppData\Local\hermes\hermes-agent`),但 hermes 内部所有文件读写都正常
- config.yaml 写入后用文本编辑器打开,中文 / emoji 都没乱码
- bot 能正常回复消息

## 执行证据(发版前由 agent / PM 填)
- [ ] `%USERPROFILE%` 路径截图(确认含中文):`testcases/core-paths/_evidence/TC-007-userprofile.png`(待 PM 真机验收时填)
- [ ] 安装完成截图:`testcases/core-paths/_evidence/TC-007-installed.png`(待 PM 真机验收时填)
- [ ] config.yaml 内容(确认 UTF-8 无 BOM,中文正常):`testcases/core-paths/_evidence/TC-007-config.yaml`(待 PM 真机验收时填)
- [ ] bot 回复截图:`testcases/core-paths/_evidence/TC-007-bot-reply.png`(待 PM 真机验收时填)
- [ ] 全程错误日志(应为空):`testcases/core-paths/_evidence/TC-007-errors.log`(待 PM 真机验收时填)
- [x] 任务 014 新增的文件 IO 全部用 UTF-8 NoBom:**`Send-Telemetry` 通过 ConvertTo-Json + StringContent UTF8(false) 编码;`Show-DepInstallFailureDialog` 不写文件;`Get-EnvFileSignature` 只读 mtime+length,不读全文**(陷阱 #21 已避免)
- **状态**:**无法本地验证(原因:sandbox 用户名 `74431` 是英文数字)**
- 备注:任务 014 不新增任何 .env / config.yaml / 仓库源码写入操作(只读)。新增的字符串如 `Show-DepInstallFailureDialog` 弹窗内容、telemetry payload 都通过 UTF-8 NoBom 路径或在 .NET String 层处理,不存在 GBK 编码风险。需 PM 真机抽查中文用户名机器。

## 失败处理
- "GBK codec":陷阱 #21 — 检查 `Set-Content` 调用,改为 `[System.IO.File]::WriteAllText` + UTF8NoBom
- "MS-DOS 功能无效":陷阱 #16 — 检查 robocopy 清理路径
- "NotADirectoryError" / "/mnt/c/...":陷阱 #24 — 检查上游 local.py 补丁是否还在
- "WinError 10093":陷阱 #25 — 检查上游 base.py 的 `_drain` 平台分支是否还在
- "%1 不是有效的 Win32":陷阱 #26 — 检查上游 browser_tool.py 的 `.cmd` 后缀是否还在
- 是否需要新建陷阱条目:**是**(如果发现新的中文环境卡点)
