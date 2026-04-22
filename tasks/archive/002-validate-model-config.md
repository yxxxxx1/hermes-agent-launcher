# 任务 002：保存模型配置前增加连通性校验

## 背景

用户填了 API Key / Base URL 点保存，保存直接成功。但如果填的信息有误（key 失效、base_url 打错、余额不足等），hermes 会通过 fallback_model 静默切到备用模型。用户看到对话能通，以为配置正确，其实用的不是自己选的模型。

详见 `DECISIONS.md` 2026-04-22 条目。

## 目标

保存前自动校验一次"填的配置能不能真的用"，校验不通过时明确告知用户，避免"静默错误"。

---

## 一、技术方案

### 校验方式：发一次最小的 chat completion 请求

不用 `/models` 接口（原因：`/models` 只能验证 base_url 通不通、key 有没有权限，验证不了具体模型名是否可用，也验证不了余额）。

用 chat completion 请求：
```
POST {base_url}/chat/completions
{
  "model": "{用户填的模型名}",
  "messages": [{"role": "user", "content": "hi"}],
  "max_tokens": 1
}
```

- 请求成功（HTTP 200 + 返回了 choices）= 校验通过
- 只要求返回 1 个 token，开销极低

### 各 provider 类型的处理

| 类型 | 校验方式 | 说明 |
|---|---|---|
| custom（有 api_key） | chat completion | 标准 OpenAI 兼容接口 |
| custom（无 api_key，本地模型） | chat completion | 同上，不带 Authorization header |
| local-ollama/vllm/sglang/lmstudio | chat completion | 同上，base_url 用用户填的或默认值 |
| deepseek/openrouter 等标准 provider | chat completion | base_url 用 provider 的官方地址，带对应 API Key |
| anthropic（API Key 型） | **暂不校验** | 接口不是 OpenAI 兼容，UI 提示"暂不支持自动校验" |
| nous/copilot/anthropic-account 等账号登录型 | **不校验** | 走 auth.json 登录流，不经过本对话框保存 |

### Anthropic 特殊处理

选 Anthropic API Key provider 时：
- 保存按钮旁加一行小字：**"当前 provider 暂不支持自动校验，请确保 API Key 正确。"**
- 保存时跳过校验，直接保存（不弹警告）
- 已在 TODO.md 记录"未来补上 Anthropic Messages API 校验"，低优先级

### 超时

- **远程 API**（非 localhost）：5 秒超时
- **本地模型**（localhost/127.0.0.1）：3 秒超时（本地应该很快，超时说明服务没开）

### 防重复校验

- 维护一个 `$dialogState.LastValidation` 对象，记录上次校验的输入指纹（provider + model + apikey + baseurl 拼接后取哈希）和时间戳
- **10 秒内连续保存且配置未变**：直接复用上次校验结果，不重复请求
- 用户修改了任意字段 → 清空 `LastValidation`，下次保存重新校验

### 请求约束

- 请求内容最短：`messages` 只发 `"hi"`，`max_tokens: 1`
- **单次校验失败就算失败，不重试**（避免重复扣费、避免超时叠加）

### 实现位置

在现有 `$saveHandler`（约 3820 行）中，`Test-ModelDialogInput` 通过之后、`Save-HermesModelDialogConfig` 调用之前，插入校验步骤。

新增一个函数 `Test-ModelProviderConnectivity`：
```
参数：$Provider, $ModelName, $ApiKey, $BaseUrl
返回：[pscustomobject]@{
    Success    = [bool]
    ErrorType  = 'none' | 'timeout' | 'auth' | 'not_found' | 'connection' | 'unknown'
    Message    = [string]  # 中文提示（给 ValidationStatusText）
    Hint       = [string]  # 中文下一步建议（给 DialogFooterText）
    Detail     = [string]  # 原始错误信息（调试用）
}
```

用 PowerShell 原生的 `Invoke-RestMethod` 发请求，不依赖 Python。

### 请求构造

```powershell
$headers = @{ 'Content-Type' = 'application/json' }
if ($ApiKey) {
    $headers['Authorization'] = "Bearer $ApiKey"
}

$body = @{
    model = $ModelName
    messages = @(@{ role = 'user'; content = 'hi' })
    max_tokens = 1
} | ConvertTo-Json -Depth 3

$endpoint = if ($Provider.NeedsBaseUrl) { $BaseUrl.TrimEnd('/') } else { $Provider.BaseUrlDefault.TrimEnd('/') }
$url = "$endpoint/chat/completions"
$timeout = if ($endpoint -match 'localhost|127\.0\.0\.1|0\.0\.0\.0') { 3 } else { 5 }
```

### 各 provider 的 base_url 解析

标准 provider 需要在 catalog 条目里新增 `BaseUrlDefault` 字段：

| Provider | BaseUrlDefault |
|---|---|
| deepseek | `https://api.deepseek.com/v1` |
| openrouter | `https://openrouter.ai/api/v1` |
| gemini | `https://generativelanguage.googleapis.com/v1beta/openai` |
| openai / custom / local-* | 用户填的 base_url |
| 智谱 (glm) | `https://open.bigmodel.cn/api/paas/v4` |
| 月之暗面 (kimi) | `https://api.moonshot.cn/v1` |
| MiniMax | `https://api.minimax.chat/v1` |
| MiniMax 国内 | `https://api.minimax.chat/v1` |
| 通义千问 (dashscope) | `https://dashscope.aliyuncs.com/compatible-mode/v1` |

如果某个 provider 没有 `BaseUrlDefault` 且 `NeedsBaseUrl=false` → 跳过校验（安全兜底）。

---

## 二、用户体验方案

### 校验时 UI 流程

1. 用户点"保存配置" →
2. 字段检查通过（现有 `Test-ModelDialogInput` 逻辑） →
3. 检查是否命中缓存（10 秒内、配置未变 → 直接用上次结果） →
4. 未命中缓存：
   - `ValidationStatusText` 显示 **"正在验证配置…保存时会进行一次小额 API 调用（通常不到 0.01 元）。"**
   - 保存按钮灰掉（`IsEnabled = $false`）
5. 发校验请求 →
6. 成功：正常保存，流程不变
7. 失败：进入失败状态（见下方）

### 校验失败的视觉反馈

**输入框变红**：根据错误类型，把对应的输入框边框改为红色（`#EF4444`）

| 错误类型 | 变红的输入框 |
|---|---|
| 401 / 403（key 问题） | ApiKeyPasswordBox |
| 404（模型名问题） | ModelNameTextBox |
| 连接失败 / 超时 | BaseUrlTextBox |
| 其他 | 不变红 |

用户修改了变红的输入框后 → 边框恢复原色。

### 校验失败的文字提示

| 错误类型 | `ValidationStatusText` | `DialogFooterText` |
|---|---|---|
| 401 Unauthorized | API Key 无效或已过期。 | 请检查 API Key 是否正确，或到平台官网重新生成。 |
| 403 Forbidden | API Key 没有权限访问该模型。 | 请确认账号权限或余额是否充足。 |
| 404 Not Found | 模型名 "{model}" 不存在。 | 请确认模型名拼写正确，或点"检查填写"查看可用列表。 |
| 连接失败 | 无法连接到 {base_url}。 | 请检查 Base URL 是否正确，或确认网络可以访问该地址。 |
| 超时 | 连接 {base_url} 超时。 | 本地模型请确认服务已启动；远程 API 请检查网络。 |
| 其他 | 校验失败：{简要错误}。 | （见下方保存按钮） |

### "跳过校验"的交互

校验失败后：

1. **保存按钮文案改为** **"保留错误设置保存"**
2. **按钮颜色改为警告色**：背景 `#92400E`（深琥珀），前景 `#FEF3C7`（浅黄）
3. **按钮下方加一行小字**（用 `DialogFooterText`）：**"配置未通过校验，保存后可能无法正常使用。"**
4. 用户点击 → 跳过校验，直接保存
5. 用户修改了任意字段 → 按钮恢复为"保存配置"原始样式，重新走校验流程

### 保存+启动 按钮（DialogSaveLaunchButton）

- 校验失败时，"保存并开始对话"按钮**直接隐藏**（不提供"跳过校验并启动"选项）
- 理由：配置都没通过校验就启动对话，一定会走 fallback，和不校验没区别

---

## 三、边界场景

### 1. 本地 Ollama 没开端口

- 校验结果：连接失败（TCP connection refused）
- 提示："无法连接到 http://localhost:11434/v1。请确认 Ollama 已启动。"
- BaseUrlTextBox 变红
- 允许"保留错误设置保存"（用户可能打算先保存配置、之后再启动 Ollama）

### 2. 校验通过但模型名填了个不存在的

- 如果 API 返回 404 → 按"模型名不存在"处理，ModelNameTextBox 变红
- 如果 API 接受任意模型名（某些代理服务会这样）→ 校验通过，这种情况无法检测，可接受

### 3. 已保存过的配置，再次保存时是否也校验

- **是的，每次保存都校验**
- 但 10 秒内配置未变 → 复用上次结果，不重复请求

### 4. 账号登录型 provider（nous/copilot/anthropic-account）

- 不经过本对话框的保存按钮，走右侧登录卡片流程
- **不受本次改动影响**

### 5. Anthropic API Key 型

- 保存按钮旁显示：**"当前 provider 暂不支持自动校验，请确保 API Key 正确。"**
- 直接保存，不校验，不弹警告

### 6. 网络环境特殊（代理、VPN）

- PowerShell 的 `Invoke-RestMethod` 默认走系统代理
- 校验结果和 hermes 实际使用一致，不需要特殊处理

### 7. 10 秒内连续点保存

- 配置未变 → 复用上次校验结果，秒过
- 配置变了 → 重新校验

---

## 四、改动估算

| 改动 | 位置 | 预估行数 |
|---|---|---|
| 新增 `Test-ModelProviderConnectivity` 函数 | `Save-HermesModelDialogConfig` 附近 | ~55 行 |
| provider catalog 加 `BaseUrlDefault` 字段 | `Get-ModelProviderCatalog` | ~15 行 |
| 修改 `$saveHandler` 插入校验步骤 | `Show-ModelConfigDialog` 内部 | ~30 行 |
| 校验失败视觉状态（输入框变红 + 按钮变色 + 恢复） | `$saveHandler` + `$refreshDialog` | ~25 行 |
| 防重复校验缓存逻辑 | `$dialogState` + `$saveHandler` | ~10 行 |
| Anthropic 跳过校验 + 提示文字 | `$refreshDialog` | ~5 行 |
| **合计** | | **~140 行** |

只改一个文件：`HermesGuiLauncher.ps1`。
不新增 UI 元素：复用 `ValidationStatusText` / `DialogFooterText` / `DialogSaveButton`，只改文案和颜色。

---

## 五、已确认的决策

1. **Anthropic API Key 型**：本次跳过校验，UI 提示"暂不支持自动校验"。TODO.md 已记录后续补上。 ✅ PM 已同意
2. **"跳过校验"交互**：按钮文案改为"保留错误设置保存"，按钮变警告色（深琥珀 + 浅黄），下方加风险提示小字。 ✅ PM 已同意
3. **1 token 开销**：可接受。UI 显示费用说明。不重试，10 秒内不重复校验。 ✅ PM 已同意
