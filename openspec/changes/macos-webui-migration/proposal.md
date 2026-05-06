## Why

The macOS launcher currently bootstraps Hermes WebUI by `git clone`-ing `nesquena/hermes-webui` into a Python venv on port 8787. Windows has migrated to the npm package `hermes-web-ui@0.5.x` on port 8648, which is the same WebUI both platforms should share going forward (`6183e5e Migrate web-ui from bundled Python to npm-based hermes-web-ui`). Two consequences:

1. The two platforms now run different WebUIs. Configuration, telemetry, and bug reports diverge unless macOS is brought onto the same package.
2. The npm package's `bin/hermes-web-ui.mjs` is itself a cross-platform daemon manager (`start | stop | restart | status`) with built-in PID tracking, `/health` polling, port-conflict resolution, token generation, and browser opening. The macOS launcher today reimplements all of these in shell against the Python WebUI; switching to npm lets us delete that whole layer.

Separately, this change retires the launcher's in-process model/channel/gateway management. The new WebUI owns provider, model, channel, and gateway configuration end-to-end; the launcher's job is reduced to "install runtime → start daemon → open browser → report stage state."

## What Changes

- Replace the `nesquena/hermes-webui` git+venv bootstrap with `npm install -g hermes-web-ui@0.5.9` into a launcher-managed npm prefix.
- Add a Node.js runtime layer: detect system Node ≥23 first; otherwise download the official `v23.11.0` portable tarball for the host arch (`darwin-arm64` or `darwin-x64`) into `~/.hermes/launcher-runtime/node/`.
- Switch the WebUI port from `8787` → `8648` and the data directory from `~/.hermes/hermes-webui/` → `~/.hermes-web-ui/` (controlled by the bin script's `homedir()`, matching Windows).
- Replace the launcher's self-managed Python subprocess + `urllib`-based `/health` poll with calls to `hermes-web-ui start | stop | status` and a one-line `curl http://127.0.0.1:8648/health`.
- Remove launcher-side model and channel/gateway configuration: WebUI owns provider/model/API-key/messaging-platform setup. The launcher no longer surfaces or validates `~/.hermes/auth.json` model state.
- Collapse the three-stage onboarding (`install → model → chat`) to two stages (`install → launch`). The "model" stage becomes a sub-step inside the WebUI; the launcher never blocks on it.
- Auto-clean the legacy `~/.hermes/hermes-webui/` Python checkout on first run of the new launcher (see §7 risks). The legacy port `8787` is no longer probed.
- Preserve the existing bash↔Swift IPC protocol (newline-delimited `key=value` lines on stdout). Existing keys repurposed; obsolete keys removed; new keys added.
- All UI changes are out of scope for this proposal — they are gated behind separate design-mockup approval. Only the Swift state model and store backing the UI are touched here.

## Capabilities

### Modified Capabilities

- `webui-launch` (currently Windows-only): macOS now participates in the same capability with platform-specific runtime bootstrap (portable Node download, POSIX bin path, HTTP `/health`).

### Removed Capabilities

- macOS-only "model configuration" and "gateway/channel configuration" stage flows in the launcher. These existed implicitly in `HermesMacGuiLauncher.command` (`configure_model`, `configure_gateway`, `start_model_flow`) and the three-stage `LauncherStage` enum.

## Impact

- Affected files:
  - `HermesMacGuiLauncher.command` — large rewrite of the WebUI lifecycle layer; deletions of model/channel/gateway functions
  - `macos-app/Sources/LauncherModels.swift` — `LauncherStage` enum trimmed; snapshot fields trimmed/added
  - `macos-app/Sources/LauncherStore.swift` — IPC field set updated; new async install/launch state machine; deleted model/gateway branches
  - `macos-app/Sources/LauncherRootView.swift` — **NOT touched in this change** (UI gated by design mockup)
  - `Package.swift` — no change
  - `scripts/package-macos-app.sh` — no change (portable Node downloaded on first run, not bundled)
  - `README.md`, `index.html` — copy refresh listed but deferred to UI-change tracking
- New on-disk paths (created on first launcher run):
  - `~/.hermes/launcher-runtime/` — launcher-managed runtime root
  - `~/.hermes/launcher-runtime/node/` — portable Node.js (only when system Node missing or <23)
  - `~/.hermes/launcher-runtime/npm-prefix/` — isolated npm global prefix
  - `~/.hermes/launcher-runtime/cache/` — download cache (Node tarball)
  - `~/.hermes-web-ui/` — WebUI state (managed by the npm package itself: `server.pid`, `server.log`, `.token`)
- Removed paths (cleaned on first run if present):
  - `~/.hermes/hermes-webui/` — old git checkout
  - `~/.hermes/webui/` — old launcher-managed WebUI state
- External dependencies:
  - npm registry (official `registry.npmjs.org`, China fallback `registry.npmmirror.com`)
  - `nodejs.org/dist/v23.11.0/` for the portable tarball
- Security posture: WebUI continues to bind `127.0.0.1` only. The bin script auto-generates a 32-byte hex auth token in `~/.hermes-web-ui/.token` (mode 0600); the launcher reads it to compose `http://localhost:8648/#/?token=...` for browser opening.

---

## 1. Directory Layout

| Path | Purpose | Aligned with Windows? |
|---|---|---|
| `~/.hermes/` | `HERMES_HOME` (gateway data, config.yaml, auth.json) | ✅ aligned (`%USERPROFILE%\.hermes` on Windows) |
| `~/.hermes/launcher-runtime/` | macOS-launcher-managed runtime root | macOS analogue of `%LOCALAPPDATA%\hermes\launcher-runtime\` |
| `~/.hermes/launcher-runtime/node/` | Portable Node.js (only created when system Node missing or `<23`) | analogue |
| `~/.hermes/launcher-runtime/npm-prefix/` | Isolated `npm config prefix` for `hermes-web-ui` install | analogue |
| `~/.hermes/launcher-runtime/npm-prefix/bin/hermes-web-ui` | npm bin entry point (POSIX layout, no `.cmd`) | **macOS-specific path shape** |
| `~/.hermes/launcher-runtime/npm-prefix/lib/node_modules/hermes-web-ui/` | Installed npm package contents | analogue |
| `~/.hermes/launcher-runtime/cache/` | Download cache (Node tarball) | analogue |
| `~/.hermes/launcher-runtime/install.log` | Append-only install/upgrade log | analogue |
| `~/.hermes-web-ui/` | WebUI state directory (managed by the npm package itself, `homedir()`-derived) | ✅ aligned (`%USERPROFILE%\.hermes-web-ui\`) |
| `~/.hermes-web-ui/server.pid` | WebUI PID | aligned |
| `~/.hermes-web-ui/server.log` | WebUI server log | aligned |
| `~/.hermes-web-ui/.token` | Auth token (auto-generated, mode 0600) | aligned |
| `~/.hermes/logs/launcher/` | Launcher-side bash logs | macOS-only (already exists) |
| `~/.hermes/logs/launcher/state.env` | Last-run launcher state cache | macOS-only (already exists) |

**Removed (cleaned on first run after migration)**:
- `~/.hermes/hermes-webui/` (legacy git checkout)
- `~/.hermes/webui/` (legacy state dir)

---

## 2. `HermesMacGuiLauncher.command` Changes

### 2.1 Node.js detection + portable download

**Strategy: two-phase**:

1. **Phase A — system Node**: try `command -v node` to get an absolute path (this bypasses `nvm` shell shims correctly because `command -v` returns the resolved binary, and we then call that absolute path with `-v` to avoid version reported by a shim wrapper). Parse the major version; if `>=23`, set `NODE_BIN=$(command -v node)` and `NPM_BIN=$(command -v npm)` (with a sanity check that the same dir contains both — i.e. `[[ -x "$(dirname "$NODE_BIN")/npm" ]]`). If they live in different dirs (rare but possible with custom setups), fall through to phase B.

2. **Phase B — portable download**: arch detection via `uname -m` (`arm64` → `darwin-arm64`, `x86_64` → `darwin-x64`; reject anything else with a clear error). Tarball URL `https://nodejs.org/dist/v23.11.0/node-v23.11.0-${ARCH_TAG}.tar.gz`. Download to `~/.hermes/launcher-runtime/cache/node-v23.11.0-${ARCH_TAG}.tar.gz` using `curl -fL --retry 3 --retry-delay 2`. Verify SHA256 against a hardcoded constant in the script. Extract via `tar -xzf` into `~/.hermes/launcher-runtime/node/v23.11.0-${ARCH_TAG}/`. Set `NODE_BIN=<extract_dir>/bin/node`, `NPM_BIN=<extract_dir>/bin/npm`.

**New constants** at the top of `HermesMacGuiLauncher.command` (~line 6 area):

```bash
NODE_REQUIRED_MAJOR=23
NODE_PORTABLE_VERSION="v23.11.0"
NODE_DIST_BASE="https://nodejs.org/dist/${NODE_PORTABLE_VERSION}"
WEBUI_NPM_PACKAGE="hermes-web-ui"
WEBUI_NPM_VERSION="0.5.9"
WEBUI_PORT=8648                          # was 8787
WEBUI_HOST="127.0.0.1"
WEBUI_HEALTH_URL="http://${WEBUI_HOST}:${WEBUI_PORT}/health"
LAUNCHER_RUNTIME_DIR="$HERMES_HOME/launcher-runtime"
NODE_INSTALL_DIR="$LAUNCHER_RUNTIME_DIR/node"
NPM_PREFIX="$LAUNCHER_RUNTIME_DIR/npm-prefix"
RUNTIME_CACHE_DIR="$LAUNCHER_RUNTIME_DIR/cache"
```

**New functions** (each ≤30 lines):

- `detect_node_runtime()` — phase A; sets `NODE_BIN` / `NPM_BIN` / `NODE_VERSION_OK` globals; idempotent.
- `download_portable_node()` — phase B; arch detection + download + SHA256 verify + extract.
- `ensure_node_runtime()` — orchestrator: tries A, falls back to B; emits `STAGE:` events.

**Validation rule**: before `npm install`, always re-`exec` `"$NODE_BIN" -v` and `"$NPM_BIN" -v` and verify both work. If broken, blow away the portable dir and redownload once.

### 2.2 Delete git clone + Python venv lineage

**Functions to delete** (with current line ranges):

| Line | Function | Why |
|---|---|---|
| 868–911 | `test_model_ready()` | model check moves into WebUI |
| 912–925 | `detect_gateway_configured()` | gateway check moves into WebUI |
| 926–933 | `detect_gateway_running()` | gateway check moves into WebUI |
| 942–973 | `find_webui_python()` | Python no longer involved |
| 1404–1408 | `configure_model()` | replaced by "open WebUI in browser" |
| 1414–1439 | `ensure_webui_checkout()` | git clone gone, replaced by §2.4 |
| 1440–1479 | `ensure_webui_default_language()` | npm package owns its own language defaults |
| 1480–1490 | `prepare_webui_checkout()` | wrapper of the deleted ones |
| 1491–1527 | `start_webui_server()` | replaced by `hermes-web-ui start` |
| 1602–1606 | `configure_gateway()` | gateway management moves to WebUI |
| 1607–1611 | `launch_gateway()` | bin script handles gateway start internally |
| 1748–1755 | `start_model_flow()` | model flow removed |

**Constants to remove**: `WEBUI_REPO_URL`, `DEFAULT_WEBUI_DIR`, `DEFAULT_WEBUI_STATE_DIR`, `WEBUI_DIR`, `WEBUI_STATE_DIR`, `WEBUI_LANGUAGE`, `WEBUI_URL` (the last is rebuilt from the new `WEBUI_PORT`), `BRANCH` (was used for git clone branch), `HERMES_WEBUI_PYTHON` env override.

### 2.3 npm prefix isolation + registry switching

**Strategy**: never touch the user's system npm config. All npm calls take `--prefix "$NPM_PREFIX"` and `--registry "$REG"`. Write a tiny shim:

```bash
npm_isolated() {
    "$NPM_BIN" --prefix "$NPM_PREFIX" --registry "$NPM_REGISTRY" "$@"
}
```

**Registry selection** (`select_npm_registry()`):

- Probe `https://registry.npmjs.org/-/ping?write=true` with `curl -fsS --max-time 4`. On success → `NPM_REGISTRY=https://registry.npmjs.org`.
- On failure (network blocked or slow) → fall back to `https://registry.npmmirror.com`.
- This mirrors `HermesGuiLauncher.ps1:6565` (`if ($networkEnvResult -eq 'china') { 'https://registry.npmmirror.com/' } else { 'https://registry.npmjs.org/' }`).

**No `~/.npmrc` modification.** Registry is always passed inline so two `hermes-web-ui` installs across users with different npm configs stay independent.

### 2.4 Idempotent global install of `hermes-web-ui`

**Function**: `ensure_hermes_web_ui_installed()`

Steps:
1. Compute expected bin path: `$NPM_PREFIX/bin/hermes-web-ui`. If it doesn't exist → install path.
2. If it exists, run `"$NPM_PREFIX/bin/hermes-web-ui" --version` to read installed version. If equal to `$WEBUI_NPM_VERSION` → skip (idempotent fast path).
3. If different (lower or higher) → upgrade by re-running `npm install`.
4. Install command:
   ```bash
   npm_isolated install -g "${WEBUI_NPM_PACKAGE}@${WEBUI_NPM_VERSION}"
   ```
5. After install, validate: `"$NPM_PREFIX/bin/hermes-web-ui" --version` returns `$WEBUI_NPM_VERSION`. On mismatch, write `install.log` and surface a stage failure.
6. The bin script's `ensureNativeModules()` already chmods node-pty's `spawn-helper`, so no extra step needed for that. The launcher does, however, do a defensive `chmod +x "$NPM_PREFIX/bin/hermes-web-ui"` once after install (covers edge cases where extraction loses the bit).

**Failure modes & messages**:
- npm exit non-zero → emit `STAGE:install_webui RESULT=failed REASON=npm_install_failed_<exit>` and persist the last 80 lines of `install.log` for telemetry.
- bin missing after install → `STAGE:install_webui RESULT=failed REASON=bin_missing`.
- version mismatch → `STAGE:install_webui RESULT=failed REASON=version_mismatch_<got>`.

### 2.5 Start / stop / status via bin subcommands

**Functions** (replace deleted `start_webui_server()`):

- `start_hermes_web_ui()`:
  ```bash
  HERMES_HOME="$HERMES_HOME" \
  GATEWAY_ALLOW_ALL_USERS=true \
  API_SERVER_PORT=8642 \
  PORT="$WEBUI_PORT" \
  "$NPM_PREFIX/bin/hermes-web-ui" start "$WEBUI_PORT"
  ```
  The bin script: kills port-stealers, daemonizes (detached fork), writes `~/.hermes-web-ui/server.pid`, polls `/health` for 30s, prints success/failure. The launcher captures stdout to a temp file and forwards selected lines as `STAGE:` events.

- `stop_hermes_web_ui()`: `"$NPM_PREFIX/bin/hermes-web-ui" stop`. Idempotent (the bin script handles "not running" cleanly).

- `status_hermes_web_ui()`: `"$NPM_PREFIX/bin/hermes-web-ui" status`; parse stdout for "is running"/"is not running"; combine with §2.6 health probe to report `webui_running=true|false`.

**Important — env propagation**:
- `HERMES_HOME` already set as a global in the script (line 19), reuse.
- `GATEWAY_ALLOW_ALL_USERS=true` and `API_SERVER_PORT=8642` are set inline only on the `start` invocation, not exported globally, to avoid leaking into other child processes the launcher spawns (e.g. installer, doctor).
- `PYTHONIOENCODING=utf-8` is **NOT** set on macOS (Windows-only need; macOS shells default to UTF-8).
- `PATH` is *not* prepended with `$NPM_PREFIX/bin`; the launcher always invokes `hermes-web-ui` by absolute path so the user's shell PATH is unaffected.

### 2.6 Health check via HTTP `/health`

**Replace** `webui_health_check()` (line 974, currently Python urllib) with:

```bash
webui_health_check() {
    curl -fsS --max-time 3 "$WEBUI_HEALTH_URL" >/dev/null 2>&1
}
```

That's it. No retry loop here — `wait_for_webui_health()` (line 1033, kept) remains the retry wrapper but its inner call becomes `curl`-based. The bin script already polls health for 30s during `start`, so most of the time the launcher's wait loop is a no-op verification.

**Delete** `find_webui_python()` (line 942) — Python is no longer in the picture.

### 2.7 Token reading

**New function** `read_webui_token()`:

```bash
read_webui_token() {
    local token_file="$HOME/.hermes-web-ui/.token"
    [[ -f "$token_file" ]] || return 1
    tr -d '[:space:]' <"$token_file"
}
```

**Use site**: `open_webui_browser()` (line 1528). Build URL as `http://localhost:8648/#/?token=$TOKEN` if token readable; otherwise fall back to `http://localhost:8648`. The bin script also opens a browser on its own during `start`, so the launcher's `open_webui_browser` becomes a recovery/secondary entry — only invoked on the management-center "open WebUI again" action.

### 2.8 Stage event protocol updates

The bash↔Swift IPC is `compute_app_state()` (line 1053) emitting `key=value` lines on stdout, which `LauncherStore.swift:106` parses into `fields[key] = value`.

**Field changes** to `compute_app_state()`:

| Field | Before | After |
|---|---|---|
| `installed` | true/false | unchanged |
| `model_ready` | true/false | **REMOVED** |
| `gateway_configured` | true/false | **REMOVED** |
| `gateway_running` | true/false | **REMOVED** |
| `webui_installed` | true/false | unchanged (semantics: npm package present at `$NPM_PREFIX/bin/hermes-web-ui`) |
| `webui_running` | true/false | unchanged (semantics: `/health` 200) |
| `webui_url` | `http://localhost:8787` | `http://localhost:8648` |
| `node_runtime_kind` | — | **NEW**: `system` \| `portable` \| `missing` |
| `node_runtime_version` | — | **NEW**: e.g. `v23.11.0` |
| `webui_version` | — | **NEW**: e.g. `0.5.9` (read from package.json after install) |
| `webui_pid` | — | **NEW**: integer or empty |

Also keep emitting `webui_url` as an absolute URL so Swift can use it as-is.

**Stage progress events** (NEW, separate from `compute_app_state`): the launch action emits per-step `STAGE:` lines while running, mirroring the Windows 7-step model. Format on a separate line, parsed differently from the snapshot:

```
STAGE:check_node          STATUS=running
STAGE:check_node          STATUS=ok      DETAIL=system_v23.11.0
STAGE:download_node       STATUS=running PROGRESS=42
STAGE:download_node       STATUS=ok
STAGE:install_webui       STATUS=running
STAGE:install_webui       STATUS=ok      DETAIL=v0.5.9
STAGE:start_gateway       STATUS=running
STAGE:start_gateway       STATUS=ok
STAGE:start_webui         STATUS=running
STAGE:wait_healthy        STATUS=running
STAGE:wait_healthy        STATUS=ok      URL=http://localhost:8648
```

Phase identifiers chosen to align with Windows phases: `check_node`, `download_node`, `extract_node`, `install_webui`, `start_gateway`, `wait_gateway_healthy`, `start_webui`, `wait_healthy` (skipping phases that don't apply, e.g. when system Node ≥23 we go `check_node:ok` directly to `install_webui`).

### 2.9 Functions to delete from `HermesMacGuiLauncher.command` (model/channel removal)

In addition to the WebUI-related deletions in §2.2, the following are removed because they implement the in-launcher model/channel/gateway management that WebUI now owns:

| Line | Function | Replacement |
|---|---|---|
| 1404–1408 | `configure_model()` | (none) — user opens WebUI to configure |
| 1602–1606 | `configure_gateway()` | (none) — same |
| 1607–1611 | `launch_gateway()` | (none) — bin script + WebUI manage gateway |
| 1748–1755 | `start_model_flow()` | (none) — stage flow eliminated |

The action dispatcher `handle_action()` (line 1781) loses the `configure-model`, `configure-gateway`, `launch-gateway`, `start-model-flow` cases. Whatever calls these from the Swift side (see `LauncherStore.swift` action mapping) is also removed in §4.

`run_full_setup()` (line 1655) currently chains install → model setup → chat. After this change it becomes install → start_webui (if user explicitly wants the chained flow). Default path is the new launch state machine in §4.

`build_dashboard_prompt()` (line 1093) currently composes a 3-step textual summary including the "model" line. It is **NOT deleted in this change** because the UI work is gated; it stays compiled but unused, or its 3-line summary is regenerated as a 2-line summary when §3 lands. Mark it as a TODO pointing at the design-mockup change.

---

## 3. `macos-app/Sources/LauncherModels.swift` Changes

### 3.1 `LauncherStage` enum: 3 cases → 2 cases

**Before** (`LauncherModels.swift:4-29`):
```swift
enum LauncherStage: Int, CaseIterable, Identifiable {
    case install = 1
    case model = 2
    case chat = 3
    // ...
}
```

**After**:
```swift
enum LauncherStage: Int, CaseIterable, Identifiable {
    case install = 1
    case launch = 2

    var title: String {
        switch self {
        case .install: return "安装 Hermes"
        case .launch: return "启动浏览器对话"
        }
    }

    var detail: String {
        switch self {
        case .install: return "把 Hermes 装到这台 Mac 上，装好后才能继续。"
        case .launch: return "启动浏览器对话界面，并在浏览器里完成模型配置。"
        }
    }
}
```

`StageStatus` enum unchanged. `StageCardModel` unchanged (its `shortTitle`, `symbolName`, `accentColor` switches need to drop the `.model` arm and update `.chat` to `.launch`).

### 3.2 `LauncherSnapshot` field changes

**Remove** (currently lines 81–95):
- `var aiProvider = "未配置"`
- `var aiModel = "未配置"`
- `var chatAvailability = "暂不可用"`
- `var gatewayStatus = "暂未配置"`
- `var gatewayChannel = "未配置"`
- `var supportSummary = "日常使用暂不需要"`

**Modify**:
- `var webuiURL = "http://localhost:8787"` → `"http://localhost:8648"`
- `var webuiStatus = "未准备"` — keep, but state literals change ("等待安装" → "等待启动" etc.)
- `var stages: [StageCardModel]` initial value: drop the middle `.model` element; rename `.chat` to `.launch`.
- `var version = "macOS v2026.04.19.2"` — bumped during release, no structural change.

**Add**:
- `var nodeRuntimeKind: String = "未检测"` — values: `系统 Node`, `便携 Node`, `未安装`.
- `var nodeRuntimeVersion: String = ""` — e.g. `v23.11.0`.
- `var webuiVersion: String = ""` — e.g. `0.5.9` (empty until install completes).
- `var launchProgress: LaunchProgress?` — optional struct describing in-flight launch state machine (nil when idle).

**New struct** `LaunchProgress`:
```swift
struct LaunchProgress {
    enum Phase: String {
        case checkNode = "check_node"
        case downloadNode = "download_node"
        case extractNode = "extract_node"
        case installWebUI = "install_webui"
        case startGateway = "start_gateway"
        case waitGatewayHealthy = "wait_gateway_healthy"
        case startWebUI = "start_webui"
        case waitHealthy = "wait_healthy"
    }
    enum Status { case running, ok, failed }
    var phase: Phase
    var status: Status
    var detail: String?       // version string, URL, error reason
    var progressPercent: Int? // when downloadable
    var startedAt: Date
}
```

`LauncherResultCard` and `LauncherResultTone` enums: unchanged.

---

## 4. `macos-app/Sources/LauncherStore.swift` Changes

`LauncherStore` is the macOS-side state store + bash invoker. It needs to (a) drop deleted snapshot fields, (b) update IPC parsing to the new field set, (c) replace the synchronous chat-launch path with an async state machine driven by `STAGE:` events.

### 4.1 IPC parsing — drop deleted keys, add new ones

`LauncherStore.swift:106-130` (the `compute_app_state` snapshot parser):

**Remove the reads**: `model_ready`, `gateway_configured`, `gateway_running` and the corresponding `snapshot.aiProvider` / `aiModel` / `gatewayStatus` / `gatewayChannel` / `supportSummary` assignments throughout this method.

**Add reads**: `node_runtime_kind`, `node_runtime_version`, `webui_version`, `webui_pid` → corresponding new snapshot fields.

**Stage card construction** (`LauncherStore.swift:163`): rewrite the `[StageCardModel]` builder to produce 2 cards (`.install`, `.launch`) based on the boolean ladder `installed → webui_installed → webui_running`.

### 4.2 New async launch state machine

Add a method `launch()` on `LauncherStore` (replaces the existing `launch-cli` / `launch-webui` binary path).

**Mechanism** (mirrors Windows `27b984b` async pattern):
- Spawn `HermesMacGuiLauncher.command --start-webui` as a `Process`, with `Pipe` on stdout.
- Read stdout line-by-line on a background queue; for each line:
  - `STAGE:<phase> STATUS=<s> [DETAIL=...] [PROGRESS=N] [URL=...]` → update `snapshot.launchProgress` on the main actor.
  - `<key>=<value>` → buffer into a snapshot delta, applied when stdout closes (final state).
- On process exit:
  - Exit 0 → `launchProgress` cleared; refresh snapshot via `compute_app_state`; if successful, surface a result card.
  - Non-zero → `launchProgress.status = .failed`, build a `LauncherResultCard` with the failure phase + reason.
- No 800ms `DispatcherTimer` — Swift Concurrency / `FileHandle.readabilityHandler` gives push-based updates instead of polling. (The user's Step-2 brief mentioned the Windows 800ms pattern as a reference; on macOS we don't replicate it because Swift has push-based stream IO.)

**Cancellation**: a "Cancel" button (UI, deferred) → calls `launch()`'s `Task.cancel()` → terminate the bash subprocess via SIGTERM → emit a result card "已取消".

### 4.3 Error reason mapping

`STAGE:<phase> STATUS=failed REASON=<code>` → user-facing message via a static map:

| REASON code | User message |
|---|---|
| `node_not_found` | "未找到 Node.js，准备下载便携版本…" (auto-recover, not a fatal) |
| `node_download_failed` | "Node.js 下载失败，请检查网络后重试" |
| `node_extract_failed` | "Node.js 安装包解压失败，已清理临时文件，请重试" |
| `npm_install_failed_<exit>` | "WebUI 安装失败（npm 退出码 \<exit\>），可查看日志后重试" |
| `bin_missing` | "WebUI 安装完成但找不到启动入口，请重试" |
| `version_mismatch_<got>` | "WebUI 版本不匹配（实际 \<got\>），请重试" |
| `gateway_failed` | "Hermes 网关启动失败，可在浏览器中查看详情" |
| `webui_failed` | "浏览器对话界面启动失败，可查看日志或改用终端对话" |
| `health_timeout` | "WebUI 已启动但健康检查超时，可重试或查看日志" |
| (other) | "出现未知错误：\<reason\>" |

These map to `LauncherResultCard` fields. The `secondaryActionID` for most failures is `"open-webui-log"` (opens `~/.hermes-web-ui/server.log`); the secondaryActionID for npm failures is `"open-install-log"` (opens `~/.hermes/launcher-runtime/install.log`).

### 4.4 Action dispatcher pruning

The current dispatcher (around `LauncherStore.swift:260`) routes Swift action IDs to `HermesMacGuiLauncher.command --action=<id>`. Remove these IDs:
- `configure-model`
- `configure-gateway`
- `launch-gateway`
- `start-model-flow`
- `model` (any stage-key-as-action mapping)

Add:
- `launch` (new — drives the §4.2 state machine)
- `stop-webui`
- `restart-webui`

Repurpose:
- `chat` was the legacy chat action; now alias to `launch`.

### 4.5 `LauncherRootView.swift` is NOT touched

This file (`macos-app/Sources/LauncherRootView.swift`, 1210 lines) is the SwiftUI surface. UI changes are gated behind separate design-mockup approval and are out of scope for this proposal.

To keep the build green during this change without touching the view:
- The view currently reads `snapshot.aiProvider`, `aiModel`, `gatewayStatus` etc. (deleted in §3.2). To avoid view breakage, keep these fields in `LauncherSnapshot` as `@available(*, deprecated)` no-op stored properties seeded with placeholder strings (`"已迁移至 WebUI"`) until the UI change lands. The view continues to render those placeholders harmlessly. Once the UI design-mockup is approved and `LauncherRootView.swift` is updated, the deprecated stubs are removed in a follow-up commit.
- The `.model` enum case is not directly referenced by name in the view (it iterates `LauncherStage.allCases` and reads `stages: [StageCardModel]`), so dropping it from `allCases` and from the snapshot's `stages` array is enough for the view to render two cards instead of three.

This compatibility shim is the only deliberate temporary code in the change. It costs ~10 LOC and is removed in the UI follow-up.

---

## 5. Other Configuration

### 5.1 `Package.swift`

No change. Swift Package Manager target stays at `macos-app/Sources/`. No new dependencies — networking / process / file IO use Foundation only.

### 5.2 `scripts/package-macos-app.sh`

No change. Specifically: **the portable Node tarball is NOT bundled into the `.app`.** Reasoning:
- Bundling would push the `.app` ZIP from ~5 MB to ~40 MB (Node tarball is ~30–35 MB compressed).
- Most users who already have Node ≥23 wouldn't need it.
- First-run download is one-time, ~20–30 s on a typical connection, gated behind a clear stage event (`STAGE:download_node`).
- Notarization-friendliness: Apple notary doesn't love arbitrary unsigned executables in the bundle; downloading at runtime keeps the bundle minimal.

The portable Node lives in `~/.hermes/launcher-runtime/node/` (user data, not bundle), so an app reinstall does not redownload it.

### 5.3 README and `index.html`

Copy refresh listed for tracking but **not part of this change**:
- README: replace the "Hermes WebUI is cloned from `nesquena/hermes-webui`" sentence with the new flow.
- `index.html`: update the "Mac 端使用 Python WebUI" tooltip if any.

These are bundled with the UI design-mockup change.

---

## 6. Execution Order and Verifiable Milestones

| # | Milestone | Verification command(s) | Stop condition |
|---|---|---|---|
| **M1** | Node detection works (system path) | Run script with `node` on PATH at v23+: `./HermesMacGuiLauncher.command --probe-node`. Expected stdout: `node_runtime_kind=system`, `node_runtime_version=v23.x.x`. | NODE_BIN+NPM_BIN absolute paths printed; both `-v` succeed. |
| **M2** | Portable Node download + extract | Force phase B: rename system node away, rerun `--probe-node`. Verify `~/.hermes/launcher-runtime/node/v23.11.0-darwin-arm64/bin/node -v` prints `v23.11.0`. SHA256 logged. | Re-run idempotent (no redownload). |
| **M3** | npm install of `hermes-web-ui@0.5.9` | `./HermesMacGuiLauncher.command --install-webui`. Expected: `~/.hermes/launcher-runtime/npm-prefix/bin/hermes-web-ui` exists, `--version` prints `hermes-web-ui v0.5.9`. Re-run is no-op. | `STAGE:install_webui STATUS=ok DETAIL=v0.5.9` emitted. |
| **M4** | `hermes-web-ui start` launches and `/health` responds | Run start; in another shell: `curl http://127.0.0.1:8648/health` → 200; `~/.hermes-web-ui/server.pid` populated; `.token` exists with mode 0600. | `STAGE:wait_healthy STATUS=ok` emitted. |
| **M5** | `hermes-web-ui stop` clean shutdown | Run stop; verify port 8648 freed (`lsof -ti:8648` empty), PID file removed. | Re-running stop on already-stopped daemon is idempotent. |
| **M6** | End-to-end stage flow drives Swift store | Run launcher app, click launch action; `LauncherStore.snapshot.launchProgress` walks through phases and clears on success. The 2-card stage list renders without compile errors. Snapshot emits `webui_url=http://localhost:8648`. | No references to `aiProvider`/`gatewayStatus` etc. in compiled output. |
| **M7** | Legacy cleanup safe | First run on a machine with `~/.hermes/hermes-webui/` populated: directory is moved to `~/.hermes/hermes-webui.legacy-<timestamp>` (not deleted) and a one-time `STAGE:cleanup_legacy STATUS=ok` event fired. | User can recover the legacy dir manually if needed. |

Each milestone is independently merge-able — none of them require UI to land first. M1–M5 operate purely on bash and can be tested via dummy CLI flags before any Swift changes. M6 wires Swift to the new IPC. M7 is a guard.

---

## 7. Known Risks and Rollback

### 7.1 Network failure during portable Node download

- Download retried 3× with `curl --retry 3 --retry-delay 2`. Total max wait ~12s.
- On final failure: `STAGE:download_node STATUS=failed REASON=<curl_exit>`. User sees "Node.js 下载失败，请检查网络后重试" and a "重试" button. The launcher does **not** auto-retry on the next run unless the user explicitly retries.
- Download cache file is partial → unlinked on failure to avoid corrupt resume attempts.

### 7.2 npm install network or mirror failure

- Try official `registry.npmjs.org` first (4s timeout). On failure or slow → fall back to `registry.npmmirror.com`.
- If both fail: `STAGE:install_webui STATUS=failed REASON=registry_unreachable`. User sees a clear message; offered option: "查看安装日志" → opens `~/.hermes/launcher-runtime/install.log` in TextEdit.
- A successful install on either registry is final — we do not auto-switch later.

### 7.3 `hermes-web-ui` health check timeout

- The bin script polls `/health` for 30s during `start`. If 30s elapse with no 200, the bin script returns non-zero but the daemon may still be alive.
- Launcher response: `STAGE:wait_healthy STATUS=failed REASON=health_timeout`. Surface a result card with two actions: "查看 WebUI 日志" (`~/.hermes-web-ui/server.log`), "停止并重试" (`hermes-web-ui stop` then re-launch).
- We do **not** auto-fall-back to a CLI/terminal chat path. The user has explicitly chosen the launch action; if it fails, they get a recovery surface, not a silent downgrade.

### 7.4 Legacy Python WebUI cleanup

**Decision**: do **not** preserve the old Python WebUI.

- On first run after migration, if `~/.hermes/hermes-webui/` exists:
  - Rename it to `~/.hermes/hermes-webui.legacy-<YYYYMMDDHHMMSS>` (atomic `mv`).
  - Emit `STAGE:cleanup_legacy STATUS=ok`.
  - Append a note to `~/.hermes/logs/launcher/state.env` recording the rename.
- We do **not** `rm -rf` it. The user can manually restore (it's just a git checkout) or delete after they're confident the new flow works.
- After 3 successful launches via the new flow (counter persisted in `state.env`), display a one-time toast offering "永久清理旧 WebUI 备份目录" — user must explicitly opt in.
- We also kill any process holding port 8787 (`lsof -ti:8787 | xargs kill`) to prevent stale Python servers from confusing the user, but only after first verifying the process is the legacy WebUI (its command line contains `bootstrap.py` or `server.py` from the legacy path).

### 7.5 Gatekeeper / quarantine

- Confirmed via investigation: Node.js tarball downloaded via `curl` does **not** receive the `com.apple.quarantine` xattr (that's set only by browser/AirDrop transfers). node-pty prebuilds inside the tarball are extracted intact. No Gatekeeper prompt expected in normal flow.
- Defensive: after extracting the Node tarball, run `xattr -dr com.apple.quarantine "$NODE_INSTALL_DIR"` (no-op if no xattr present, harmless if some are).

### 7.6 Rollback path

If the migration must be reverted on a deployed machine:
- Remove `~/.hermes/launcher-runtime/` and `~/.hermes-web-ui/`.
- Move `~/.hermes/hermes-webui.legacy-<ts>/` back to `~/.hermes/hermes-webui/`.
- Reinstall the previous launcher version (we keep `Hermes-macOS-Launcher-v2026.04.19.2.zip` in `downloads/` for this purpose).
- This is documented in the rollback section of the release note that ships with this change, not in user-visible launcher UI.

### 7.7 Cross-version coexistence (during user-base rollout)

- The npm package version (`0.5.9`) is shared with Windows. If Windows bumps the pinned version (e.g. to `0.5.11`), macOS can adopt the same bump in a follow-up release. The launchers are independent processes; there is no cross-platform runtime coupling beyond the npm package version string and the on-disk WebUI state at `~/.hermes-web-ui/`. A user with both Mac and Windows wouldn't normally share `~/.hermes-web-ui/` (different machines), so version-skew is not a runtime concern.

---

## 8. Out of Scope

- Any change to `macos-app/Sources/LauncherRootView.swift` or to user-visible copy/layout/interaction in the launcher UI. Those go through a separate design-mockup approval cycle.
- Telemetry / data reporting (Step 2 goal #2). That is a separate proposal (`macos-launcher-telemetry`) — this proposal only sets up the lifecycle events that telemetry will later observe.
- Updating the Windows launcher in any way.
- Changing `hermes-web-ui` itself (it's an upstream npm package; we consume it as-is).
- Bundling the portable Node tarball into the `.app` bundle.
