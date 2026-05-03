# TC-008: 国内网络(无翻墙)首次安装

**优先级**:P0
**关联陷阱**:CLAUDE.md #13(依赖未就绪的外部资源上线)
**适用版本**:v2026.05.02.2 及以上

## 前置条件
- 操作系统:Win10 / Win11 中文版
- 网络环境:**国内 IP,无 VPN / 无翻墙**(可访问 baidu.com,**无法**访问 github.com / pypi.org / npmjs.com 主站)
- hermes 状态:未装
- .env 内容:不存在
- 其他:Windows DNS 默认(不动 hosts)

## 测试步骤
1. 确认网络环境:`curl https://github.com -m 5` 应超时或失败
2. 确认国内镜像可达:`curl https://pypi.tuna.tsinghua.edu.cn -m 5` 应正常返回
3. 双击 `Start-HermesGuiLauncher.cmd` 启动启动器
4. 走完首次安装流程
5. 安装过程中观察终端窗口里下载源(应使用清华 PyPI / npmmirror / ghproxy 等)
6. 安装完成,主面板进入 Home Mode
7. 点"开始使用",webui 正常打开

## 预期结果
- 步骤 5 中:终端日志里看到镜像源地址(例:`pypi.tuna.tsinghua.edu.cn`、`npmmirror.com`、`ghproxy.com`)
- 步骤 5 中:**不出现**长时间(> 30 秒)卡在 github.com / pypi.org 不动的情况
- 整个安装流程在 **~5-10 分钟**内完成(海外网络下大约 3-8 分钟,国内镜像可能略慢但应可接受)
- 步骤 6 后:Home Mode 出现,功能完整
- 步骤 7 后:webui 正常打开(8643 端口)

## 执行证据(发版前由 agent / PM 填)
- [ ] 步骤 1 网络确认截图:`testcases/core-paths/_evidence/TC-008-network.png`
- [ ] 步骤 5 安装日志(含镜像源 URL):`testcases/core-paths/_evidence/TC-008-install.log`
- [ ] 安装总耗时:______ 分钟
- [ ] 步骤 7 webui 截图:`testcases/core-paths/_evidence/TC-008-webui.png`
- [ ] 通过 / 未通过 / 无法本地验证(sandbox 通常无国内网络环境,大概率声明盲区)
- [ ] 备注:_______________

## 失败处理
- 安装卡在 github.com / pypi.org 超时:镜像 fallback 未生效或某个依赖跳过了镜像
- 某个依赖装不上(报 SSL / connection refused):该镜像未覆盖该包,需要扩充镜像清单
- 安装时间 > 20 分钟:某一步路径走了直连超时,需要工程师检查
- 是否需要新建陷阱条目:**是**(如果发现新的国内网络卡点)
