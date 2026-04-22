# 任务：修复 Windows 端自定义模型配置的 4 个 bug

## 背景
用户反馈在 Windows 启动器里配置自定义模型（custom provider）有两个症状：
1. "自定义配置无效" —— 保存后实际用不上
2. "已配置的自定义识别不了" —— 打开启动器发现它不认识现有配置

我已经做了代码诊断，定位到 4 个具体 bug。这次任务就是修掉这 4 个。
不重构，不顺手优化别的，不改 UI 流程，只修 bug。

## 必读：项目上下文
开始前请先读项目根目录的 `CLAUDE.md`。遵守里面的开发原则。
特别注意："中文文案优先"、"不重构"、"一次只做一件事"。

## 文件范围
本次只改 **一个文件**：`HermesGuiLauncher.ps1`

涉及的函数（以下是目前所在行号，改动后行号会变动，请以函数名为准）：
- `Test-HermesModelConfigured` — 当前约 128-204 行
- `Get-HermesModelSnapshot` — 当前约 684-714 行
- `Save-HermesModelDialogConfig` — 当前约 748-772 行
- `Save-HermesProviderConfigOnly` — 当前约 776-800 行（与 Save-HermesModelDialogConfig 结构一致，也要一并修）

## Bug 清单与修复方案

### Bug 1：保存自定义配置时，api_key 没写入 config.yaml

**现状**：
`Save-HermesModelDialogConfig` 只把 api_key 写到了 `.env` 的 `OPENAI_API_KEY`。
但上游 hermes-agent 官方文档规定 custom provider 的 api_key 可以也**应该**直接写在 config.yaml 的 `model.api_key` 字段里。
官方示例：
```yaml
model:
  provider: custom
  default: qwen-plus
  base_url: https://api.xxx.com/v1
  api_key: sk-xxx
```

**修复思路**：
- **仅当** `$Provider.ConfigProvider -eq 'custom'` 时（也就是 Id 为 `openai`/`custom`/`local-*` 这几个 ConfigProvider 为 custom 的条目），
  在写 config.yaml 的 `model:` 块时，**多加一行 `api_key: xxx`**（当用户填了 api_key 时）。
- 非 custom 的 provider（如 deepseek、openrouter 等）**保持现状**，继续只写 env。不要动它们的逻辑。
- 如果用户填的 api_key 是空字符串（本地模型场景），不要写 api_key 这一行。
- **同时保留写入 .env 的 OPENAI_API_KEY 逻辑**（兼容老用户，用户决定选项 A 的兼容策略）。
  也就是：custom provider 下，**api_key 双写**—— config.yaml 和 .env 里都写。

**注意**：`Save-HermesProviderConfigOnly` 也需要同样的修复（这个函数只改 provider 不改 apikey，保持它不写 api_key 但也不要破坏现有 api_key，具体见下面的"不破坏原则"）。

### Bug 2：识别 API Key 时，没看 config.yaml 的 api_key 字段

**现状**：
`Test-HermesModelConfigured` 里只检查 `.env` 里有没有 `*_API_KEY`，完全没看 config.yaml。
结果：用户如果把 api_key 写在 config.yaml（上游推荐的做法），启动器会说"没 API Key"。

**修复思路**：
在现有 `$hasApiKey` 的判断基础上，**追加一条判断**：
- 如果 config.yaml 的 `model:` 块下有 `api_key` 字段且非空，则 `$hasApiKey = $true`。
- 原有判断保留（从 .env 读、从 auth.json 读、localhost 例外等）。
- 新旧判断是"或"的关系，任何一个通过就认为有 API Key。

### Bug 3：读取配置回显时，没提取 config.yaml 的 api_key

**现状**：
`Get-HermesModelSnapshot` 只提取了 provider / model / base_url 三个字段，没读 api_key。
结果：用户再次打开"模型配置"对话框时，API Key 输入框是空的，即使 config.yaml 里有。

**修复思路**：
- 在 `Get-HermesModelSnapshot` 的返回对象里，**新增一个字段 `ApiKey`**。
- 提取逻辑：从 config.yaml 的 `model:` 块下读 api_key 字段。
- 如果 config.yaml 里没有，回退到从 .env 读 `OPENAI_API_KEY`（但**只在 provider 是 custom 时**回退，避免把其他 provider 的 key 串到 custom）。
- 调用 `Get-HermesModelSnapshot` 的代码可能要用到新字段做 UI 回显。请你搜索一下所有调用点，如果某个调用点是"模型配置对话框的初始化"，就把新字段也回显到 API Key 输入框。
  - 如果找不到明确的回显代码，**告诉我**，不要硬改 UI。

### Bug 4：YAML 正则在真实 config 下会误匹配或漏匹配

**现状**：
现有正则 `(?m)^\s+provider\s*:\s*(\S+)` 等存在问题：
- 提取带引号的值时会把引号一起吃进去（如 `"custom"`）
- 一个正则配上所有 `provider:` 字段，可能匹配到 `auxiliary.provider` 或 `fallback_model.provider`，而不是 `model.provider`

**修复思路（最小改动，不换解析器）**：

为了只拿 `model:` 块里的字段，需要**先定位 model: 块，再在块内找字段**。实现方式：

1. 新增一个辅助函数 `Get-YamlTopLevelBlockText`，输入 config 全文 + 块名（如 `model`），返回该块的原文内容（从 `model:` 下一行开始，到下一个顶层键或文件结尾为止）。
2. 所有需要读 `model.xxx` 字段的地方，先调这个函数拿到 `model:` 块的文本，再在**块文本内部**用正则提取 provider/default/base_url/api_key。
3. 字段提取正则要去掉值两侧的引号：
   - 改进后提取逻辑示意（伪代码）：
```
     匹配：^\s+(字段名)\s*:\s*(值)\s*(?:#.*)?$
     取到值之后，若两端是 "..." 或 '...'，去掉引号
     若值里有 # 后的注释（但 base_url 这种不能一刀切，因为 https:// 里也有类似字符），
       更稳妥的做法是：从匹配到的值开始，按 " 或 ' 或 空白 或 # 截断
```
4. 多个字段复用同一个块文本，避免每个字段都扫全文。

**不换 YAML 解析器的原因**：引入 `powershell-yaml` 模块会增加分发依赖，是 CLAUDE.md 明确不做的"重构"范围。本次只用正则做**最小程度的兼容性提升**，覆盖以下真实场景：
- 值带双引号 `"custom"` → 去掉引号后得到 `custom`
- 值带单引号 `'custom'` → 去掉引号后得到 `custom`
- 行内注释 `base_url: https://x.com/v1  # 注释` → 得到 `https://x.com/v1`
- `model:` 块之外的同名字段（`auxiliary.provider` 等）→ 不干扰 `model.provider` 的读取

**不需要覆盖的极端场景**（不在本次范围内）：
- 多行字符串值（`|-` 或 `>-`）
- 数组形式的值
- tab 缩进（上游文档用空格，用户手改出 tab 概率低，以后再说）

## 不破坏原则（非常重要）

1. **非 custom provider 的行为完全不变**。
   deepseek / openrouter / gemini / anthropic 等的保存和读取逻辑不要动。
   只改 custom（ConfigProvider 为 'custom' 的那几个：`openai`、`local-ollama`、`local-vllm`、`local-sglang`、`local-lmstudio`、`local-model`、`custom`）。

2. **老用户的老配置不要自动迁移**。
   如果老用户之前配置的 api_key 在 .env 的 OPENAI_API_KEY，**不要启动时自动把它搬到 config.yaml**。
   按照 PM 的决定（选项 A），新配置按正确格式写，老配置保持能读就行。

3. **Save 时的 api_key 双写策略**：
   custom provider 下，保存时 config.yaml 和 .env 两边都写 api_key。
   这样新老读取逻辑都能命中，最大程度兼容。
   但如果用户填的 api_key 是空（本地模型），两边都不写。

4. **不要改模型配置对话框的 UI 布局 / 文案 / 按钮**。
   本次只修数据层逻辑，UI 不动。

5. **不要改任何你怀疑可能也有 bug 的其他代码**。
   看到就记到项目根目录的 `TODO.md` 里（如果不存在就创建），带上行号和一句话描述，不要现在改。

## 验收清单

改完后，**你自己先用手工构造的 config.yaml 过一遍这 13 个场景**，每个场景都写清楚预期行为。
如果你没法在本地跑启动器测试，就用 PowerShell 语法检查工具和函数单元验证来确认逻辑正确。

### 保存（Bug 1）
1. ✅ 在"模型配置"选 custom / openai / local-ollama 中任意一个，填 api_key 保存 → config.yaml 的 `model:` 块里应该有 `api_key: <用户填的>` 这一行
2. ✅ 同一个操作后，`.env` 里的 `OPENAI_API_KEY` 也应该被更新（双写）
3. ✅ 选 local-ollama，**不填 api_key**保存 → config.yaml 里**没有** `api_key:` 这一行，.env 里的 `OPENAI_API_KEY` 也没被写入（或被清空）
4. ✅ 选 deepseek 保存 → config.yaml 里**没有** `api_key:` 行（非 custom 不走新逻辑），.env 里 `DEEPSEEK_API_KEY` 被正常写入

### 识别（Bug 2）
5. ✅ config.yaml 里 `model.api_key: sk-xxx`，.env 里无任何 `*_API_KEY` → `Test-HermesModelConfigured` 应返回 `HasApiKey = true`
6. ✅ config.yaml 里无 api_key，.env 里有 `OPENAI_API_KEY=sk-xxx`，provider 是 custom → `HasApiKey = true`（老用户兼容）
7. ✅ config.yaml 里有 `api_key:` 但值是空字符串 → `HasApiKey = false`（空不算配置）

### 读取回显（Bug 3）
8. ✅ config.yaml 里 `model.api_key: sk-foo`，调用 `Get-HermesModelSnapshot` → 返回对象的 `ApiKey` 字段值为 `sk-foo`
9. ✅ config.yaml 里无 api_key，.env 里 `OPENAI_API_KEY=sk-bar`，provider 是 custom → `ApiKey` 字段值为 `sk-bar`（回退）
10. ✅ provider 是 deepseek，不管 env 里有啥 → `ApiKey` 字段是 null 或空（不跨 provider 串值）

### YAML 解析鲁棒性（Bug 4）
11. ✅ config.yaml 里 `provider: "custom"`（带引号）→ 读出来是 `custom`（没有引号）
12. ✅ config.yaml 里有 `model.provider: custom`、`auxiliary.vision.provider: openrouter`、`fallback_model.provider: openrouter` 三处 → 启动器读出来的 model.provider 准确是 `custom`
13. ✅ config.yaml 里 `base_url: https://api.xxx.com/v1  # 我的端点` → 读出来是 `https://api.xxx.com/v1`（不含注释和尾空格）

## 改完后请向我汇报以下内容

用中文简短说明，不要长篇大论：

1. **改动清单**：动了哪几个函数，每个函数大致改了什么（一句话）
2. **新增辅助函数**：如果你加了新函数（如 `Get-YamlTopLevelBlockText`），说明它放在哪、做什么
3. **验收结果**：13 条验收场景，每条写"通过 / 未通过 / 无法本地验证（原因）"
4. **发现的其他问题**：如果你发现了 TODO.md 里值得记的其他坑，列出来
5. **对 PM 的提示**：我需要手动测试的场景（比如"在启动器里点开模型配置对话框，按场景 X 操作，应该看到 Y"）—— 给我一个我能照着点的清单

## 最后

如果你执行过程中发现：
- 某个 bug 的修复会连带影响到我没预见的其他流程
- 某条验收场景实现起来比预期复杂
- 上游 hermes-agent 的 config 格式和我写的不一致

**停下来告诉我，不要自己拍板继续做**。
