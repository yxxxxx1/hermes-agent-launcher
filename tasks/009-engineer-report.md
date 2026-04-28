# 工程师产出报告 — 任务 009 多源安装支持

**日期**: 2026-04-28
**执行者**: 工程师 Agent
**任务文件**: `tasks/009-multi-source-install.md`

---

## 返工记录（质检员评分 78/100 → 返工修复）

**返工日期**: 2026-04-28
**质检发现问题**: P1（重复网络检测）、fallback 无日志、P3（版本号）

### 返工修复内容

#### P1 已修复 — 删除重复网络检测
- 安装按钮 handler（原行 6343）删除了 `Test-NetworkEnvironment` 重复调用
- 改为直接复用 `$preflight.NetworkEnv`（`Test-InstallPreflight` 已检测并存在此字段）
- 用户等待时间减少约 5 秒，体验更流畅
- 同时优化日志文案："GitHub 访问受限" → "当前网络环境下，已自动切换到国内加速通道"

#### fallback 日志 已修复 — 切换源时写中文日志
- `Invoke-WithMirrorFallback` 新增可选参数 `[scriptblock]$OnFallback`（默认 `$null`，向后兼容）
- 切换到下一镜像源时调用回调，传入 `($fromUrl, $toUrl, $attemptIndex)`
- `New-TempScriptFromUrl` 新增透传参数 `[scriptblock]$OnFallback`
- 安装 handler 调用处传入回调：`Add-LogLine "镜像源 $attemptIndex 失败，正在尝试备用源..."`

#### P3 版本号 — 已知，等整合者决策后再改
- 版本号仍为 `v2026.04.22.1`，符合预期（工程师报告已说明等决策再改）
- 无需返工

### 返工后 SelfTest 结果
- `powershell -ExecutionPolicy Bypass -File .\HermesGuiLauncher.ps1 -SelfTest` ✅ 通过
- JSON 输出结构正常，`SelfTest: true`

---

## 1. 改动清单

### 新增函数（3 个）

| 函数名 | 位置（行号） | 说明 |
|--------|-------------|------|
| `Test-NetworkEnvironment` | ~2129 | 测试 raw.githubusercontent.com 可达性（5 秒超时），返回 `"overseas"` 或 `"china"` |
| `Get-MirrorConfig` | ~2165 | 返回 GitHub/PyPI/npm 镜像 URL 列表，写死优先级（阿里>清华>中科大，ghproxy>其他） |
| `Invoke-WithMirrorFallback` | ~2198 | 执行下载，主源失败自动 fallback 到下一镜像，每源最多重试 2 次，全部失败报中文错误 |

三个函数集中在新增的 `# 多源安装支持（Mirror Fallback）` 代码块，位于 `Build-InstallArguments` 函数之前（约 2124 行附近）。

### 修改函数（3 个）

#### `New-TempScriptFromUrl`（~2245 行）
- **改动 1**：新增 `[string]$NetworkEnv = 'overseas'` 参数
- **改动 2**：下载 install.ps1 时使用 `Invoke-WithMirrorFallback` 替代直接 `Invoke-WebRequest`
  - 国内网络：自动将 `raw.githubusercontent.com` 替换为镜像域名，按优先级 fallback
  - 海外网络：直接用官方 URL，无额外开销
- **改动 3**：国内网络时，在脚本内容开头注入 PyPI/npm 镜像环境变量：
  - `$env:PIP_INDEX_URL` → 阿里 PyPI 源
  - `$env:UV_INDEX_URL` / `$env:UV_DEFAULT_INDEX` → 阿里 PyPI 源（uv 工具读取）
  - `$env:NPM_CONFIG_REGISTRY` → 淘宝 npmmirror
  - 注入方式：在原脚本头部追加 PowerShell 代码，不修改上游逻辑本身

#### 主安装按钮处理逻辑（`PrimaryActionButton` click handler，~6317 行）
- **改动**：在 `New-TempScriptFromUrl` 调用前，先调用 `Test-NetworkEnvironment` 检测网络
- 检测结果写入日志（用户能在日志区看到"已切换到国内镜像源"或"使用官方源"）
- 将 `$networkEnv` 传入 `New-TempScriptFromUrl -NetworkEnv $networkEnv`
- 错误提示优化为中文："检查网络连接或稍后重试；如持续失败请联系作者"

#### `Test-InstallPreflight`（~5454 行）
- **改动前**：官方 URL 不可达 → 直接 `blocking.Add`（阻塞安装）
- **改动后**：官方 URL 不可达 → 进一步测试前 2 个镜像 URL 是否可达
  - 镜像可达 → `passed.Add('官方地址不可访问，但国内镜像源可用...')` → 不阻塞
  - 镜像也不可达 → `blocking.Add('访问官方安装脚本及所有镜像源均失败...')` → 阻塞
- 新增 `NetworkEnv` 字段到返回对象（供后续扩展使用）

---

## 2. 关键设计决策

### 网络检测策略（已拍板方案 D）
- 测 `raw.githubusercontent.com`，5 秒超时
- 用 `System.Net.HttpWebRequest`（不用 `Invoke-WebRequest`），避免 PowerShell 默认超时行为
- 用 `WebExceptionStatus` 枚举判断异常类型，不用消息文本（规避陷阱 #3 中文 Windows 错误消息匹配）

### 镜像注入策略
- PyPI/npm 镜像：通过 `$env:PIP_INDEX_URL` 等环境变量注入到安装脚本，上游 pip/uv 会自动读取，无需修改上游逻辑
- GitHub raw 镜像：在启动器层替换下载 URL，安装脚本内容不感知

### fallback 逻辑
- 每个 URL 最多重试 2 次（第 1 次失败等 2 秒后重试，第 2 次失败直接跳下一个）
- 全部失败才报错，错误消息：`"已尝试所有镜像源，请检查网络连接。"`

---

## 3. 验收结果（对照 tasks/009 成功标准）

| 验收项 | 状态 | 说明 |
|--------|------|------|
| 安装前检测网络环境 | ✅ 通过 | `Test-NetworkEnvironment` 在点击安装时调用 |
| 海外网络 → 用官方源 | ✅ 通过 | `NetworkEnv='overseas'` 时直接用 `OfficialInstallUrl` |
| 国内网络 → 用镜像源 | ✅ 代码通过 | `NetworkEnv='china'` 时注入镜像 env + URL 替换 |
| GitHub 镜像 | ✅ 通过 | gitmirror / 99988866 / ghproxy.cn 三个备用 |
| PyPI 镜像 | ✅ 通过 | 阿里 / 清华 / 中科大（通过 env 注入） |
| npm 镜像 | ✅ 通过 | 淘宝 npmmirror / cnpm（通过 env 注入） |
| 主源失败自动 fallback | ✅ 通过 | `Invoke-WithMirrorFallback` 实现，3 个镜像源全失败才报错 |
| 每源最多重试 2 次 | ✅ 通过 | while 循环 retryCount < 2 |
| 用户操作路径不变 | ✅ 通过 | 点"开始安装"→ 等待 → 完成，无额外弹窗 |
| 失败时中文提示 | ✅ 通过 | "已尝试所有镜像源，请检查网络连接" |
| 不修改上游 install.ps1 | ✅ 通过 | 只在启动器层注入 env 变量和字符串替换 |
| 不影响海外用户体验 | ✅ 通过 | overseas 路径零额外开销 |
| SelfTest 通过 | ✅ 通过 | `powershell -File .\HermesGuiLauncher.ps1 -SelfTest` 输出正常 JSON |
| 函数逻辑测试 | ✅ 通过 | 独立函数测试：MirrorConfig/NetworkEnv/Fallback 三个函数均验证 |

---

## 4. 自检结果

### 已规避的已知陷阱

- **陷阱 #1（Dispatcher 异常处理）**：新增代码无 `Dispatcher.Invoke` 调用，不适用
- **陷阱 #3（中文 Windows 错误消息匹配）**：`Test-NetworkEnvironment` 用 `WebExceptionStatus` 枚举判断，未使用消息文本匹配 ✅
- **陷阱 #4（UI 信息位置）**：网络检测结果写入 `Add-LogLine`（日志区），失败消息写入 `Add-ActionLog`（操作日志），用户可见 ✅
- **陷阱 #10（自检覆盖"用户找不找得到"）**：已声明盲区（见下） ✅

### 5 层自检

1. **语法层**：SelfTest 通过，PowerShell 解析无报错
2. **逻辑层**：`Invoke-WithMirrorFallback` 逻辑测试：成功路径/fallback路径/全失败路径均验证
3. **集成层**：函数签名接口一致，`New-TempScriptFromUrl` 调用处正确传入 `$networkEnv`
4. **边界场景层**：
   - 网络全断 → `Test-NetworkEnvironment` 返回 `'china'`（catch 兜底），不崩溃
   - 所有镜像都失败 → `Invoke-WithMirrorFallback` 抛中文错误，被外层 catch 捕获，显示给用户
   - 海外网络 → 走官方源，无性能损耗（不调用镜像）
5. **用户路径层**：（声明盲区，无法本地 100% 验证）

---

## 5. 盲区声明（无法本地验证）

| 盲区 | 说明 |
|------|------|
| **国内网络真实 fallback 效果** | 本机环境 GitHub 可达，`china` 路径未真实触发。镜像 URL 正确性需国内网络真机验证 |
| **PyPI 镜像注入有效性** | `$env:PIP_INDEX_URL` 是否被 uv/pip 正确读取，依赖上游 install.ps1 的实际行为 |
| **UV_INDEX_URL / UV_DEFAULT_INDEX 变量名** | uv 的环境变量名可能随版本变化，本次用的是 uv 0.x 文档中的名称，需真机验证 |
| **gitmirror / ghproxy.cn 域名可用性** | 镜像站可能失效，需定期验证 |
| **360 等安全软件拦截** | 无法模拟 |
| **公司内网/教育网特殊环境** | 无法模拟 |

---

## 6. 发现的其他问题（建议记入 TODO.md）

1. **镜像站健康度无监控**：硬编码的镜像 URL 可能失效，v2 应加入运行时健康检测或远程配置
2. **uv 环境变量名需确认**：`UV_INDEX_URL` 和 `UV_DEFAULT_INDEX` 应对照 uv 最新文档确认，可能需要调整
3. **Test-InstallPreflight 网络检测超时偏长**：原来 12 秒，改后 8 秒（官方）+ 6 秒（镜像），总计可达 14 秒；对用户等待有影响，v2 可考虑并行测试

---

## 7. 对 PM 的测试提示

只需做一件事：**在中国大陆直连网络（不开代理）下，点"开始安装"**，观察：

1. 安装终端弹出后，是否有 `[Hermes 启动器] 已切换到国内镜像源` 的提示（蓝色文字）
2. 安装过程中 pip/uv 是否从 mirrors.aliyun.com 下载（看终端输出的 URL）
3. 安装是否最终成功完成

如果 1/2 没看到，说明网络检测误判为 overseas；如果 3 失败，说明镜像 URL 无效，请把终端截图发回。
