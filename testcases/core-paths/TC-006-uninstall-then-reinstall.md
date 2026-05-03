# TC-006: 卸载 → 重装

**优先级**:P0
**关联陷阱**:CLAUDE.md #16(残留目录,robocopy 镜像清理)
**适用版本**:v2026.05.02.2 及以上

## 前置条件
- 操作系统:Win10 / Win11 任意版本
- hermes 状态:**已装且至少跑过一次**(产生过 venv / Node.js / web-ui 等完整文件树)
- .env 内容:任意
- 网络环境:海外网络畅通
- 其他:启动器版本 v2026.05.02.2

## 测试步骤
1. 启动器在 Home Mode,通过启动器内的卸载入口(具体位置待 UI 确认)触发卸载
2. 卸载流程跑完,看到提示"卸载完成"
3. 关闭启动器
4. 检查 `%LOCALAPPDATA%\hermes\` 目录是否被清理(预期:已清空或目录被删除)
5. 重新双击 `Start-HermesGuiLauncher.cmd`
6. 启动器进入 Install Mode
7. 点"安装/更新 Hermes",走完整安装流程
8. 安装完成,主面板进入 Home Mode

## 预期结果
- 步骤 2 后:卸载提示成功,**无报错**
- 步骤 4 后:`%LOCALAPPDATA%\hermes\hermes-agent\` 目录不存在(或仅有最小残留如 settings.json)
- 步骤 6 后:启动器**正确识别为未装状态**,显示 Install Mode
- 步骤 7 中:终端窗口安装过程中**不命中陷阱 #16**("MS-DOS 功能无效" / "目录非 git 仓库" 等错误)
- 步骤 8 后:Home Mode 出现,主按钮"开始使用"可点击
- 整个流程**无人工介入清理残留**

## 执行证据(发版前由 agent / PM 填)
- [ ] 步骤 4 后 `%LOCALAPPDATA%\hermes\` 目录树:`testcases/core-paths/_evidence/TC-006-after-uninstall.txt`
- [ ] 步骤 7 安装日志:`testcases/core-paths/_evidence/TC-006-reinstall.log`
- [ ] 步骤 8 截图(Home Mode):`testcases/core-paths/_evidence/TC-006-home.png`
- [ ] 通过 / 未通过 / 无法本地验证
- [ ] 备注:_______________

## 失败处理
- 卸载失败:权限问题 / 进程占用 / venv 深路径删不掉 → 陷阱 #16 复发
- 重装失败:残留目录未清理干净 → 陷阱 #16 robocopy 兜底未生效
- 是否需要新建陷阱条目:**是**(如果发现新的卸载链卡点)
