# TC-010: config.yaml 端口被改成非 8642

**优先级**:P0
**关联陷阱**:CLAUDE.md #20(api 端口 8642)、#21(Set-Content GBK 破坏 UTF-8)
**适用版本**:v2026.05.02.2 及以上

## 前置条件
- 操作系统:Win10 / Win11 任意版本(中文版**最能暴露陷阱 #21**)
- hermes 状态:**已装**,gateway 当前**未运行**
- .env 内容:任意
- config.yaml 内容:用记事本打开 `%LOCALAPPDATA%\hermes\hermes-agent\config\config.yaml`,把 `platforms.api_server.extra.port` 改为 `9999`,保存(用记事本默认编码;中文 Windows 上记事本可能保存为 ANSI/GBK)
- 网络环境:任意
- 其他:config.yaml 中**包含中文注释或 emoji**(若没有,人工添一个测试用,例:`# 网关 ⚙️`),用于验证陷阱 #21 不复发

## 测试步骤
1. 备份当前 `config.yaml`(`copy config.yaml config.yaml.bak`)以便对比
2. 用记事本编辑 config.yaml,把 api_server port 改为 9999,**保留中文注释和 emoji 字符**
3. 保存(可选:测试 ANSI/UTF-8 两种编码各一次)
4. 双击启动器
5. 主面板 Home Mode,点"开始使用"
6. 启动器执行 `Repair-GatewayApiPort` 自动修正
7. Gateway 启动,8642 端口监听
8. webui 打开,显示已连接
9. 重新打开 config.yaml 检查内容

## 预期结果
- 步骤 6 中:启动器日志出现 `Repair-GatewayApiPort: changed 9999 → 8642`
- 步骤 7 后:8642 端口监听 gateway,9999 端口无监听
- 步骤 8 后:webui 显示已连接
- 步骤 9 后:config.yaml 检查:
  - port 已恢复为 8642
  - **中文注释完整**(无 `???` 乱码)
  - **emoji 完整**(`⚙️` 显示正常,无 `\\u26a8` 转义或乱码)
  - 文件用 hex viewer 检查:**无 BOM(开头无 `EF BB BF`),无 CRLF 转 LF 错误**

## 执行证据(发版前由 agent / PM 填)
- [ ] 步骤 1 备份的 config.yaml:`testcases/core-paths/_evidence/TC-010-before.yaml`
- [ ] 步骤 6 启动器日志:`testcases/core-paths/_evidence/TC-010-repair.log`
- [ ] 步骤 9 修复后的 config.yaml:`testcases/core-paths/_evidence/TC-010-after.yaml`
- [ ] hex 比对开头 16 字节(确认无 BOM):`testcases/core-paths/_evidence/TC-010-hex.txt`
- [ ] webui 已连接截图:`testcases/core-paths/_evidence/TC-010-webui.png`
- [ ] 通过 / 未通过 / 无法本地验证
- [ ] 备注:_______________

## 失败处理
- port 未自动修复:`Repair-GatewayApiPort` 未触发或读取失败,可能是 YAML 解析报错
- 中文 / emoji 乱码:陷阱 #21 复发,**Repair 函数用了 Set-Content / Out-File** 而不是 `[System.IO.File]::WriteAllText` + UTF8NoBom
- 文件开头出现 `EF BB BF`(BOM):写入用了带 BOM 的 UTF8Encoding
- webui 仍"未连接":陷阱 #20 修复链断裂,gateway 实际启动在 9999 但 webui 仍连 8642(或反之)
- 是否需要新建陷阱条目:**是**(如果发现新的写入编码卡点)
