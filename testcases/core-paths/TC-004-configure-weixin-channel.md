# TC-004: webui 配微信(QR 登录)

**优先级**:P0
**关联陷阱**:CLAUDE.md #20(api 端口)、#22(WebUI GatewayManager 30s 杀)、#27(快速路径)
**适用版本**:v2026.05.02.2 及以上

## 前置条件
- 操作系统:Win10 / Win11 任意版本
- hermes 状态:**已装**,gateway 在跑
- .env 内容:无微信相关配置
- 网络环境:国内网络可达(微信扫码服务可用)
- 其他:用户有可登录微信 PC 端的微信号

## 测试步骤
1. 启动器 Home Mode → 点"开始使用" → 浏览器打开 webui
2. webui 渠道配置 → 选"微信"
3. 点"启动微信渠道",webui 显示二维码
4. 用手机微信扫描该二维码 → 在手机上确认登录
5. 等待 webui 切换到"已登录"状态
6. 在另一个微信账号给登录的微信发"hi"
7. 等待 hermes 返回的回复

## 预期结果
- 步骤 3 后:webui 显示二维码图片清晰可扫(不是空白 / 不是 broken image)
- 步骤 4 后:30 秒内 webui 状态变为"已登录"
- 步骤 5 后:gateway 日志中出现 `weixin connected` 或类似条目
- 步骤 7 后:hermes 必须有回复(回复内容因配置而异,但**不能无响应**)
- 启动器主面板**不出现**"未连接"等异常状态

## 执行证据(发版前由 agent / PM 填)
- [ ] 步骤 3 截图(二维码):`testcases/core-paths/_evidence/TC-004-qr.png`
- [ ] 步骤 5 截图(已登录状态):`testcases/core-paths/_evidence/TC-004-logged-in.png`
- [ ] 步骤 7 截图(微信对话):`testcases/core-paths/_evidence/TC-004-reply.png`
- [ ] gateway 日志(`weixin connected` 段):`testcases/core-paths/_evidence/TC-004-gateway.log`
- [ ] 通过 / 未通过 / 无法本地验证(如 sandbox 无微信账号,声明盲区)
- [ ] 备注:_______________

## 失败处理
- 二维码空白:webui 无法连接 gateway → 陷阱 #20 端口不匹配 / 陷阱 #22 GatewayManager 杀进程
- 扫码后无反应:微信渠道初始化失败,看 gateway 日志找根因
- 主面板"未连接":陷阱 #27 快速路径未做 health check
- 是否需要新建陷阱条目:**是**(如果发现微信特有的卡点)
