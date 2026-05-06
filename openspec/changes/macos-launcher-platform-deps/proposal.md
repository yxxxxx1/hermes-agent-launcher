## Why

User v2026.05.06.5 acceptance test surfaced two bugs that affect every macOS install — not just this user's box. **Both fixes must be structural** (the launcher self-repairs / detects on every install + run), not "go install python-telegram-bot once on this user's machine."

| # | Bug | Symptom | Severity |
|---|---|---|---|
| **A** | Messaging platform deps missing | User configures Telegram (or any channel) in WebUI, gateway logs `Telegram: python-telegram-bot not installed`, no Telegram adapter registers, messages never get a reply | High — silently breaks every messaging channel on macOS |
| **B** | tools.registry import errors | `gateway.error.log` reports 11 tool modules failing to import (`base_url_host_matches`, `atomic_replace`, `cfg_get`); agent processes can crash with `ImportError` mid-run | Medium — transient, self-heals on re-install but breaks tool calls until then |

Bug A has a known Windows analog already fixed in commit `141b0f3` (Windows v2026.05.04.8); the fix has not been ported to macOS. Bug B is harder to attribute — the symbols *are* on disk now and import cleanly; the failure must have been a transient state during install. Lower confidence root-cause but still worth a structural guard, plus pinning the agent commit to a known-good revision (Track D) eliminates the moving-target version skew that produces it.

## Investigation findings

### Windows fix (commit `141b0f3`)

`HermesGuiLauncher.ps1` introduced two pieces:

1. **`Install-GatewayPlatformDeps`** — pre-existing, refined further in this commit. Strategy:
   - Read `~/.hermes/.env`, find which platform env-vars are set (uncommented + non-empty)
   - For each platform, run a Python script that does a **strict** `import <module>` AND verifies `module.__file__` is inside the venv `site-packages` (defends against cwd-shadowed modules)
   - If the strict check fails: `uv pip install <package>` (or fallback `python -m pip install`), then re-run the strict check (post-verify; defends against `uv exit 0 but nothing installed`)
   - Auto-write `GATEWAY_ALLOW_ALL_USERS=true` to `.env` if any platform is configured but the flag is missing
   - On install failure, write `$script:LastDepInstallFailure` for the UI to render an error banner with channel name + last 50 lines of pip stderr
2. **`Test-GatewayConnectedPlatformsMatchEnv`** — *new in `141b0f3`*. Reads `.env` count of messaging platforms vs. `gateway.log` last `Gateway running with N platform(s)` line. Mismatch → caller (`Restart-HermesGateway`) sleeps 5s, retries restart 1 time. Catches "lock held" / "install fail" / "race during .env watcher" classes of bugs without hardcoding any of them.

### Channel coverage matrix

After auditing `gateway/platforms/*.py`:

| env var | adapter file | extra deps needed | source of truth |
|---|---|---|---|
| `TELEGRAM_BOT_TOKEN` | `telegram.py` | **`python-telegram-bot[webhooks]`** | `check_telegram_requirements()` reads `TELEGRAM_AVAILABLE` |
| `FEISHU_APP_ID` | `feishu.py` | **`lark-oapi`** | `check_feishu_requirements()` reads `FEISHU_AVAILABLE` |
| `DISCORD_BOT_TOKEN` | `discord.py` | `discord.py[voice]` | `check_discord_requirements()` reads `DISCORD_AVAILABLE` |
| `SLACK_BOT_TOKEN` | `slack.py` | `slack-bolt`, `slack-sdk` | `check_slack_requirements()` reads `SLACK_AVAILABLE` |
| `DINGTALK_CLIENT_ID` | `dingtalk.py` | `dingtalk-stream`, `alibabacloud-dingtalk` | `check_dingtalk_requirements()` reads `DINGTALK_STREAM_AVAILABLE` |
| `WEIXIN_ACCOUNT_ID` / `WEIXIN_TOKEN` | `weixin.py` | **none** (only `aiohttp` + `cryptography`, both in base) | `check_weixin_requirements()` reads `AIOHTTP_AVAILABLE and CRYPTO_AVAILABLE` |
| `WECOM_BOT_ID` | `wecom.py` | **none** (only `aiohttp` + `httpx`, both in base) | `check_wecom_requirements()` reads `AIOHTTP_AVAILABLE and HTTPX_AVAILABLE` |

**Crucial:** WeChat (personal weixin + enterprise wecom) is supported out-of-the-box — no extra pip install needed. Just env vars. Windows's `Install-GatewayPlatformDeps` doesn't list them either. They DO count toward the platform-mismatch verifier, though.

Out-of-scope adapters (have requirements but not in this proposal): `signal`, `whatsapp` (needs Node bridge), `mattermost`, `homeassistant`, `yuanbao`. Future work.

### hermes-agent packaging

`pyproject.toml` defines per-platform extras: `[messaging]`, `[slack]`, `[matrix]`, `[dingtalk]`, `[feishu]`. The aggregated `[all]` extra includes all of them.

The launcher's macOS install path tries `[all]` first (via `scripts/install.sh` line 1006), falls back to base install on any failure (line 1010). **The fallback is silent** — `ALL_INSTALL_LOG=$(mktemp)` is captured then `rm -f`'d after extracting `tail -5 | head -3` for the user-facing message. The full diagnostic is unrecoverable.

On the bug-report user's machine, `[all]` failed (`~/.hermes/logs/launcher/20260506-193647-install.log:37` says `⚠ Full install (.[all]) failed, trying base install...`). After fallback to base install, **zero messaging extras are present in the venv**. This is the structural hole behind Bug A.

### Bug B — tool import errors (transient)

`~/.hermes/logs/errors.log` shows `tools.registry: Could not import tool module ... cannot import name 'cfg_get' from 'hermes_cli.config'` etc. for 11 tool modules at `2026-05-06 21:11:23-24`. The next gateway start at `21:14:02` is clean. Symbols exist on disk *now* and import cleanly when invoked manually. Cannot reliably reproduce.

Working hypothesis: a transient state during install / restart — most likely **stale `__pycache__/*.pyc` files** that referenced an older symbol set, OR a `pip install -e .` that didn't fully complete linkage before a gateway start raced into the import. Track D (pinning) eliminates the moving-target dimension; Track E (smoke test) catches whatever residual state slips through.

### Reproducibility on a clean Mac

Bug A: **100% reproducible** — every macOS user whose `uv pip install -e ".[all]"` fails for *any* reason ends up with no messaging extras. The launcher does not currently detect this state.

Bug B: **intermittent**. Pinning the agent commit eliminates the upstream-symbol-rename failure mode; smoke test catches the rest.

---

## Decisions (recorded 2026-05-06)

| # | Decision | Note |
|---|---|---|
| **D1** *(rewritten 2026-05-06, see D8)* | **Pure on-demand installation.** Launcher reads `~/.hermes/.env` before each gateway start; installs only the pip packages whose triggering env-var is uncommented and non-empty. Zero-config users (no channels configured) install **zero** messaging extras. | Aligns with "小白零配置即用" target: most users won't configure any channel; previously paying ~30 MB venv + install latency for every fresh install was wrong. The .env scan is sub-50ms; running it on each launch makes WebUI-side channel changes "just work" on next restart. |
| ~~**D2**~~ *(superseded by D8 / merged into D1)* | ~~Discord / Slack / Dingtalk install on demand when the matching env var first appears in `.env`.~~ | Distinction between "default-install set" (D1) and "on-demand set" (D2) collapses now that **all** channels are on-demand. Single code path covers everything. |
| **D3** | WeChat (personal weixin + enterprise wecom): **no pip install**, only verify env vars + count toward the mismatch check. | Adapters are aiohttp/httpx/cryptography only — all in base install. |
| **D4** *(updated 2026-05-06)* | Drop the `[all]` retry idea (Track C v1). The new install path: base install → `ensure_gateway_platform_deps` (which is now a pure on-demand routine, see D1). Keep `ALL_INSTALL_LOG` persistence so any future failures of base install or `[all]` are diagnosable. | Replaces the original D4 wording that referenced "default-install the 2 packages from D1". No packages are default-installed anymore. |
| **D5** | Smoke test: **post-install (full)** + **pre-launch (fast)**. Post-install runs the full importlib check (~1s); pre-launch only checks 3 hot symbols (`utils.cfg_get` etc.) (<200ms). | Cheap to keep both. |
| **D6** | UI scope: implement E1 (platform-deps install rows in launch checklist) + E2 (mismatch warning banner). E3 (smoke-test failure card) deferred — error hero already covers it well enough until we have data. **UI design is frozen** — the 8 audited screens (post P0+P1+P2 jargon cleanup) are the final mockups; no further UI iteration before implementation. | Implementation will follow the existing snapshots; any visual refinement happens during Swift integration only if a layout constraint forces a change. |
| **D7** | Pin hermes-agent to a known-good commit via `HERMES_AGENT_PINNED_COMMIT` constant in `HermesMacGuiLauncher.command`. Add a "检查更新" entry to the footer popover that bumps the pin and reinstalls. | Eliminates the rolling-`main` skew (Bug B class). User opts in to updates explicitly. |
| **D8** *(new 2026-05-06)* | **Abandon any default-install policy.** Channel configuration is **not a required step** for using Hermes — most launcher users will never configure a messaging channel. Forcing a default install of `lark-oapi` + `python-telegram-bot[webhooks]` (~30 MB + 5–15s install latency on every fresh install) burns time/network/disk for no reason and violates "小白零配置即用". Replaces D1's original "default-install the two highest-traffic channels" stance. | Triggers the rewrite of D1, the supersede of D2, and the simplification of E1's stage-2 visual (see "Same-PR impact" below). |

---

## What changes

This is a structural fix, not a one-shot script. The launcher learns to **detect** these classes of failure on every install + every launch + every channel-config change, and self-repairs where possible.

### Track A — auto-install messaging platform deps (port Windows Bug E/F)

**A1. New bash function `ensure_gateway_platform_deps()` in `HermesMacGuiLauncher.command`**

Direct port of Windows `Install-GatewayPlatformDeps`, **pure on-demand** policy (D1/D8):

- Read `~/.hermes/.env`. Build the set of configured platforms = env-var keys that are uncommented AND non-empty. **No fallback / default-install set.** A user who never configures a channel does not trigger any pip install.
- Trigger table (env-var → Python module → pip package):
  - `TELEGRAM_BOT_TOKEN` → `telegram` → `python-telegram-bot[webhooks]`
  - `FEISHU_APP_ID` → `lark_oapi` → `lark-oapi`
  - `DISCORD_BOT_TOKEN` → `discord` → `discord.py[voice]`
  - `SLACK_BOT_TOKEN` → `slack_bolt` → `slack-bolt`, `slack-sdk`
  - `DINGTALK_CLIENT_ID` → `dingtalk_stream` → `dingtalk-stream`, `alibabacloud-dingtalk`
  - `WEIXIN_ACCOUNT_ID` / `WEIXIN_TOKEN` → adapter is base-install only (D3) → no pip step, only verify env vars
  - `WECOM_BOT_ID` → adapter is base-install only (D3) → no pip step, only verify env vars
- For each platform with a pip package: run a Python strict-verify script (same template as Windows: `module.__file__` must contain venv site-packages path). Missing → `pip install <package>` via venv pip, post-verify. Persistent log at `~/.hermes/logs/launcher/<ts>-platform-deps.log` (no mktemp + rm; we keep failures around for triage).
- For zero-dep platforms (weixin/wecom): just verify env vars are present and well-formed.
- If `.env` lists at least one configured platform AND `GATEWAY_ALLOW_ALL_USERS=true` is missing, append it. Mirrors Windows.
- Emit `STAGE:install_platform_deps STATUS=running|ok|failed` events; emit a per-platform sub-event `STAGE:platform_dep_<name> STATUS=ok|skipped|failed DETAIL=<pkg-or-reason>` so the UI checklist (E1) can render one row per configured platform.
- **Zero-config short-circuit**: if no platforms are configured, the function exits immediately with `STAGE:install_platform_deps STATUS=skipped DETAIL=no_channels`, and the UI's stage-2 row marks itself "无需配置" (see Same-PR impact below).

**A2. Hook points** (where `ensure_gateway_platform_deps` runs):
1. Beginning of `--start-webui` flow, after `ensure_hermes_web_ui_installed` and *before* `start_hermes_web_ui`. **Primary hook.** Re-running on every launch makes "user adds Telegram in WebUI → restarts → Telegram works" the natural flow without a separate `.env` watcher.
2. End of `--install-webui` flow becomes a no-op for fresh installs (no `.env` yet) — it just runs and emits `skipped`. Kept for symmetry, costs nothing.
3. New CLI flag `--install-platform-deps` for verification + Swift dispatch (e.g. when the WebUI footer's "重启 Hermes" action wants to re-trigger detection without going through a full launch).
4. Future: `.env` watcher hook (still out of scope; the per-launch hook covers the user-facing flow).

**A3. Swift wiring**
- `LauncherStore.swift`: parse new STAGE events; map `package_failed_<exit>` reasons to user-facing messages per Windows precedent.
- `LauncherRootView.swift`: per E1 design, the launch progress checklist gains dynamic platform rows between "安装 hermes-web-ui" and "启动 Hermes 网关" — see UI section below.

### Track B — post-verify "gateway platforms == .env channels"

**B1. New bash function `verify_gateway_platforms_match_env()`**

Direct port of Windows `Test-GatewayConnectedPlatformsMatchEnv`, with D3 nuance:

- Parse `.env` for messaging-platform env vars; build a HashSet of unique platform names. **Includes** weixin/wecom (D3) — they don't need pip but they DO count toward the mismatch number.
- Tail `~/.hermes/logs/gateway.log` for the most recent `Gateway running with N platform(s)` line.
- `expected = 1 (api_server) + |configuredSet|`. If `N < expected` → mismatch → return non-zero.
- "No info" cases (no .env, no gateway.log, no Running line) → return zero (don't block).
- Emit `STAGE:verify_platforms STATUS=ok|mismatch DETAIL=actual=N expected=M missing=telegram,feishu`.

**B2. Hook into `--start-webui` flow** as the final step after the existing `wait_healthy` event. On mismatch:
- Sleep 5s (let any laggy adapter finish connecting).
- Re-run the check; if still mismatched → 1 retry of `start_hermes_web_ui`.
- After the single retry, mismatch becomes a non-fatal warning — emit `STAGE:verify_platforms STATUS=mismatch_persistent DETAIL=...` and the Swift store flips on the E2 warning banner above the running hero.

### Track C — retain install logs (no [all] auto-retry)

**C1. Change `launch_install`'s install handling**

Before this proposal, `launch_install` runs `bash install.sh ... --skip-setup`, falls back to a manual `git clone + venv + uv pip install -e '.[all]'`. The Windows-style "redo `[all]`" is dropped (D4). What we keep / change:

- After install.sh finishes, the launcher copies whatever output the install left in `~/.hermes/logs/install*` (or its mktemp tail, if recoverable) into `~/.hermes/logs/launcher/<ts>-install-extras-tail.log`. If install.sh's `[all]` failed silently, this is the only forensic crumb left.
- The launcher then runs `ensure_gateway_platform_deps`. On a brand-new install with no `.env` yet, this emits `skipped` and exits in milliseconds. As the user later configures channels in WebUI, subsequent `--start-webui` invocations install the matching pip packages on demand. **This is the new actual install path for messaging deps** — we don't trust install.sh's `[all]` anymore.

**C2. Upstream issue** (file-and-track-not-block)

Open `hermes-agent` issue requesting: persist the `ALL_INSTALL_LOG` to `~/.hermes/logs/install-extras-<timestamp>.log` instead of `mktemp + rm`. Reference this proposal in the issue body. Don't block our launcher fix on upstream merging.

### Track D — pin hermes-agent to a known-good commit

**D1 (proposal Track D, not D1 from decisions). New constant `HERMES_AGENT_PINNED_COMMIT="<sha>"` at the top of `HermesMacGuiLauncher.command`.**

- During install, after `git clone`, the launcher does `git -C "$INSTALL_DIR" reset --hard "$HERMES_AGENT_PINNED_COMMIT"`. This locks every macOS user onto the same revision, eliminating the "main shifted while installing" race that produced Bug B.
- The pinned commit starts as `76074d9ee` (the user's current install — verified to have all the symbols and import cleanly). We bump it manually after smoke-testing each upgrade.
- New CLI flag `--check-agent-update` reads upstream `main` HEAD and compares against the pin; if newer, prints `agent_update_available=true latest=<sha> latest_subject=...`.
- New footer-popover entry "检查更新" calls `--check-agent-update`. If newer → confirm dialog → `git fetch + reset --hard <sha>` + re-run `pip install -e .` + restart gateway. Otherwise → "已是最新".

This consolidates two related concerns: (1) a determinism guarantee for fresh installs, (2) a user-controlled upgrade ramp instead of "every install pulls a different snapshot".

**Trade-off note:** users on the pinned commit miss upstream fixes until we bump. Mitigation: monthly review cadence; the "检查更新" UI lets impatient users opt into a newer pin without waiting for us.

### Track E — post-install + pre-launch smoke test

**E1. New bash function `verify_install_smoke_test()`**

Run a single Python `-c` script that does:
```python
import importlib
for mod in ("utils", "hermes_cli.config", "tools.registry", "tools.approval", "gateway.run"):
    importlib.import_module(mod)
import utils, hermes_cli.config
assert all(hasattr(utils, s) for s in ("atomic_replace", "base_url_host_matches"))
assert hasattr(hermes_cli.config, "cfg_get")
```

Run modes:
- **Post-install** (full): right after `pip install -e .` and `ensure_gateway_platform_deps` complete, in the install Terminal flow's final stage. Also imports `tools.registry` and `gateway.run` — exercises the tool-load chain that produced Bug B.
- **Pre-launch** (fast): right before `start_hermes_web_ui` in the launch flow. Only checks 3 hot symbols + `tools.registry`. Sub-200ms target.

On failure: emit `STAGE:install_smoke_test STATUS=failed REASON=missing_<symbol>` (post-install) or `STAGE:smoke_pre_launch STATUS=failed` (pre-launch).

**E2. Stale `__pycache__` self-heal**

If the smoke test fails due to a missing symbol that *does* exist in the on-disk source, the launcher does one defensive `find ~/.hermes/hermes-agent -name "__pycache__" -type d -exec rm -rf {} +` then re-runs the smoke test. If still fails → real version-mismatch problem → user banner. If passes after pyc nuke → log a one-time event (we'll know if this is happening in the wild).

### Track F — UI work (E1 + E2 designed in this PR; E3 deferred)

| Surface | Trigger | Visual |
|---|---|---|
| **E1** Platform-deps stage row | `STAGE:platform_dep_<name>` events during launch | The simplified 3-stage checklist (per the audited mockup `state-progress-simple-*.png`) keeps stage 2 as a single "配置聊天工具" row. Behavior depends on .env: zero-config users see ✓ `已跳过 / 未启用任何聊天平台`; configured users see spinner with detail "正在配置：飞书、Telegram"; on success "已配置 N 个聊天平台"; on failure ✗ "Telegram 配置失败 [查看详情]". The detailed per-platform 11-row variant (§2c) stays as the power-user "查看技术日志" reveal. |
| **E2** Platforms-mismatch warning banner | `STAGE:verify_platforms STATUS=mismatch_persistent` | Banner above the running hero (state-3): `⚠ Hermes 网关只连接了 ${N}/${M} 个已配置平台`, sub-line `已连接：飞书；未连接：Telegram (查看安装日志)`. ~52px tall, warning-soft background. |

**E3 deferred** — when smoke test fails, reuse the existing error hero with title "安装可能不完整，请重试". No new UI surface.

#### Same-PR impact (D8 ripple effects on E1 / E2)

- **E1 stage 2 row is now data-driven on `.env`**:
  - 0 platforms configured (zero-config user) → row state = `step-skipped`, icon `—`, name "配置聊天工具", detail "未启用任何聊天平台". Stage 2 finishes in ~50 ms (a single .env read).
  - 1+ platforms configured → row state = `step-active` while `pip install` runs, detail "正在配置：飞书、Telegram" (Chinese names from a fixed map). On completion → `step-done` with detail "已配置 N 个聊天平台". On failure → `step-failed` with detail "Telegram 配置失败 [查看详情]".
- **E2 mismatch banner** triggers ONLY when `.env` lists ≥1 messaging platform AND gateway's `Gateway running with N platform(s)` line shows `N - 1 < |configured|`. Zero-config users never see the banner.
- **No new UI surfaces are introduced by this rewrite.** D6 still gates the design — the audited 8 screens are final. The runtime behavior of E1 stage 2 + E2 banner is what changes; the visual cells they render into are already approved.

### Track G — rejected alternatives

| Alt | Reason rejected |
|---|---|
| Auto-retry `[all]` (Track C v1) | Slow, flaky, opaque — replaced with pure on-demand `ensure_gateway_platform_deps` (D1 / D8) |
| Default-install telegram + feishu on every fresh install (D1 v1) | Wastes ~30 MB venv + 5–15s install latency for the majority of users who never configure a channel — see D8 |
| Bundle messaging packages into the `.app` | License + size concerns; modifies the "no Python in .app" invariant set by §5.1 of the previous proposal |
| Replace `pip` with `uv` everywhere on macOS | `uv` may not be on user PATH; the venv's bundled `pip` is always available |
| Not pinning the agent commit | Bug B's transient nature is exactly the kind of thing pinning prevents; cost is "users wait until we bump" which the UI 检查更新 entry handles |

---

## Capabilities

### Modified Capabilities

- **`webui-launch`** — gains pre-start "ensure platform deps" + post-start "verify platforms match" steps.
- **`hermes-install`** (new implicit capability surfaced by the install flow) — gains pinned-commit reset, "smoke test" + "platform deps install" sub-stages.

### New Capabilities

- **`platform-deps-management`** — declarative: ".env declares which channels exist, launcher ensures their Python deps are present." Self-heals on every gateway start. Default-installs the two highest-traffic channels (telegram + feishu) regardless of config to skip the "first-restart-after-config-change" round trip.
- **`agent-pin-management`** — launcher pins agent to a known-good commit, surfaces an opt-in "检查更新" UI for user-controlled updates.

---

## Impact

- **Affected files:**
  - `HermesMacGuiLauncher.command` — add ~200 lines: `ensure_gateway_platform_deps`, `verify_gateway_platforms_match_env`, `verify_install_smoke_test`, glue to `--start-webui` / `--install-webui` / `--dispatch-action check_update`, `HERMES_AGENT_PINNED_COMMIT` constant + reset logic in `launch_install`.
  - `macos-app/Sources/LauncherModels.swift` — extend `LaunchProgress.Phase` with new phases (`installPlatformDeps`, `platformDepRow`, `verifyPlatforms`, `installSmokeTest`); rework `LaunchProgress.rowStatus` from fixed-7 to dynamic to accommodate per-platform rows; add a `mismatchWarning: PlatformMismatch?` snapshot field for E2.
  - `macos-app/Sources/LauncherStore.swift` — handle new STAGE events; new reason mappings; new actions for "重新安装渠道依赖" / "清理 pyc 重试" / "检查 hermes-agent 更新".
  - `macos-app/Sources/LauncherRootView.swift` — `HeroInProgress` checklist becomes data-driven (variable rows from the parsed STAGE events); new banner component above `HeroRunning` for E2; footer popover gains "检查更新".
- **No new external dependencies.** Uses venv pip (already there) + git (already required for clone).
- **Performance**: smoke test is one Python `-c` invocation — sub-second. Platform-deps verify is one Python `-c` per configured + default platform — sub-second total. Total added latency on cold launch: ~1-2s. On warm launch (everything already installed): one strict-verify pass per platform — well under 1s combined.
- **Failure surfaces**: 4 new STAGE event types + per-platform sub-events, ~6 new reason codes, 2 new UI surfaces (E1 dynamic checklist rows + E2 warning banner).

---

## Out of scope

- Patching upstream `hermes-agent/scripts/install.sh` directly (Track C2 is a request, not a launcher change).
- Adding signal/whatsapp/mattermost/homeassistant/yuanbao platforms — future work.
- Telemetry for install / mismatch failures — separate `macos-launcher-telemetry` proposal.
- E3 (smoke-test failure dedicated card) — uses existing error hero until data shows we need a richer surface.
- Auto-bumping `HERMES_AGENT_PINNED_COMMIT` — user manually bumps after smoke-testing each upgrade.

---

## Decision log

- **2026-05-06 (this proposal v2)**: replaced v1's open questions with the 7 decisions above. Locked: telegram + feishu default-install; weixin/wecom zero-dep; discord/slack/dingtalk on-demand; drop `[all]` auto-retry; pin agent commit + 检查更新 UI; E1+E2 in scope, E3 deferred; smoke test post-install (full) + pre-launch (fast).
- **2026-05-06 (D8 — channels are non-essential, UI is frozen)**: walked back the "default-install telegram + feishu" stance.
  - **D1 rewritten** to "pure on-demand: scan `.env` before each gateway start, install only matching pip packages." Zero-config users install zero messaging extras.
  - **D2 superseded** — its "discord/slack/dingtalk on-demand" carve-out collapses into D1 (everything is on-demand now).
  - **D4 updated** — the new install path is base install + `ensure_gateway_platform_deps` (no default packages); `ALL_INSTALL_LOG` persistence retained for diagnostics.
  - **D6 reinforced** — the 8 audited mockups (post P0+P1+P2 jargon cleanup) are the final UI; no further iteration before implementation. E1's stage-2 row becomes `.env`-driven (skipped vs active vs done vs failed); E2 banner triggers only when ≥1 channel is configured AND gateway under-counts. No new UI surfaces.
  - Rationale: most launcher users will never configure a messaging channel; forcing a 30 MB / 5–15 s default install on every fresh install for a feature they don't use violates "小白零配置即用".

UI mockups for E1 (platform-deps rows) and E2 (mismatch banner) accompany this proposal as 3 new snapshots in `design/snapshots/v2/`. Implementation Phase 3 starts only after the user signs off on this v2 + the mockups.
