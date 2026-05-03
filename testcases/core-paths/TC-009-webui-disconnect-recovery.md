# TC-009: WebUI "未连接" → 启动器自动恢复

**优先级**:P0
**关联陷阱**:CLAUDE.md #18(--replace 必崩)、#20(api 端口 8642)、#21(Set-Content GBK)、#22(GatewayManager 30s 杀)、#23(Gateway 未就绪启 webui)、#27(快速路径)、#39(venv 进程过滤)
**适用版本**:v2026.05.02.2 及以上

## 前置条件
- 操作系统:Win10 / Win11 任意版本
- hermes 状态:**已装**,但**当前处于异常状态**(以下任一):
  1. `gateway.lock` 文件残留(上次进程未正常退出)
  2. `config.yaml` 中 api_server port 被改为非 8642(例:9999)
  3. 旧 hermes.exe 或 venv python.exe 残留进程占用 8642 端口
- .env 内容:任意
- 网络环境:任意
- 其他:启动器**当前未运行**

## 测试步骤
1. 制造异常状态(三选一即可,本用例可分 9.A / 9.B / 9.C 子用例分别跑):
   - 9.A:手动 `New-Item "$env:LOCALAPPDATA\hermes\hermes-agent\config\gateway.lock"` 创建假 lock
   - 9.B:用记事本打开 `config.yaml`,把 `port: 8642` 改成 `port: 9999`,保存
   - 9.C:任务管理器找到 hermes.exe / 含 venv 路径的 python.exe,**保留运行**(模拟旧进程没退)
2. 双击启动器
3. 主面板进入 Home Mode,主按钮"开始使用"
4. 点击"开始使用"
5. 等待启动器执行恢复流程(应自动跑 `Stop-ExistingGateway` + `Repair-GatewayApiPort` + 等 health)
6. 浏览器打开 webui
7. 观察 webui 是否显示"已连接"

## 预期结果
- 步骤 5 中:启动器日志显示自动恢复动作:
  - 9.A 场景:`gateway.lock removed`(可能伴随多次重试)
  - 9.B 场景:`Repair-GatewayApiPort: changed 9999 → 8642`,且 config.yaml 用 UTF-8 无 BOM 写回
  - 9.C 场景:`Stop-ExistingGateway: killed pid=XXX`(用 CommandLine 过滤命中 venv 路径)
- 步骤 5 后:gateway 在 8642 端口正常监听,health check 通过
- 步骤 6 后:webui 打开
- 步骤 7 后:webui **显示"已连接"**(不是"未连接")
- 整个恢复过程**< 30 秒**,**无人工介入**

## 执行证据(发版前由 agent / PM 填)
- [ ] 步骤 1 异常状态截图(选用的子用例):`testcases/core-paths/_evidence/TC-009-precondition.png`
- [ ] 步骤 5 启动器恢复日志:`testcases/core-paths/_evidence/TC-009-recovery.log`
- [ ] 步骤 7 webui 已连接截图:`testcases/core-paths/_evidence/TC-009-connected.png`
- [ ] 恢复总耗时:______ 秒
- [ ] 通过 / 未通过 / 无法本地验证
- [ ] 备注(选用了 9.A/9.B/9.C 中哪个):_______________

## 失败处理
- gateway.lock 没被删 → 陷阱 #39 复发(权限问题或重试逻辑漏)
- config.yaml 修改后中文 / emoji 乱码 → 陷阱 #21 复发(写入用了 Set-Content)
- 旧进程没杀干净 → 陷阱 #39 venv 进程过滤未走 CommandLine
- webui 仍显示"未连接" → 陷阱 #20 端口未修正 / 陷阱 #22 GatewayManager 抢管杀进程
- 是否需要新建陷阱条目:**是**(如果发现新的恢复卡点)
