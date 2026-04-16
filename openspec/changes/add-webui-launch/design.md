## Context

The launcher is a Windows PowerShell WPF application that currently handles Hermes install/update, model setup, CLI launch, gateway setup, diagnostics, and local state. The home page primary action is `launch`, which opens a PowerShell terminal running `hermes`.

The target WebUI is upstream `nesquena/hermes-webui`. It has no releases or tags at the time of planning, so the stable source must be a fixed commit archive. The spike verified commit `a512f2020e01ef8c98989eb00c84a8d8cfc81ee1` can run on Windows when launched directly with:

```text
<HermesInstallDir>\venv\Scripts\python.exe <WebUiDir>\server.py
```

The spike also verified:

- `GET /health` returns `status: ok`.
- `POST /api/settings` can persist `language: zh`.
- WebUI can use the existing Hermes install directory and `~/.hermes/config.yaml`.
- The upstream bootstrap remains unsuitable for native Windows, so the launcher must not call `bootstrap.py`.

## Goals / Non-Goals

**Goals:**

- Make WebUI the default "开始对话" experience after Hermes and model configuration are ready.
- Install WebUI from a launcher-approved fixed upstream commit without maintaining a fork.
- Start or reuse a localhost-only WebUI server and open it in the user's browser.
- Apply Chinese WebUI defaults using upstream settings support.
- Keep the existing CLI conversation path available as a fallback.
- Provide enough status, logs, and self-test data to debug failed WebUI setup/start.

**Non-Goals:**

- No WebUI fork or launcher-side patching of upstream static files.
- No complete Chinese translation maintenance in this repository.
- No LAN/mobile exposure in the first version.
- No password/auth management UI in the first version.
- No Docker or WSL-based WebUI path.
- No automatic tracking of latest upstream `master`.
- No replacement of the existing launcher model configuration flow with WebUI onboarding.

## Decisions

### Use fixed commit archive instead of Git clone or latest master

Use a GitHub archive URL for a fixed commit:

```text
https://github.com/nesquena/hermes-webui/archive/<commit>.zip
```

Initial planned source:

```text
repo: nesquena/hermes-webui
version label: v0.50.63
commit: a512f2020e01ef8c98989eb00c84a8d8cfc81ee1
```

Rationale:

- Upstream currently has no releases or tags.
- Archive download does not require Git on the user's machine.
- A fixed commit makes installs reproducible and supportable.
- The launcher can later update its approved commit deliberately.

Alternative considered: clone `master`. Rejected because it makes the launcher's behavior change without a launcher release.

### Run `server.py` directly with Hermes venv Python

The launcher will set environment variables and start:

```text
<HermesPythonExe> <WebUiDir>\server.py
```

Required environment:

```text
HERMES_HOME=%USERPROFILE%\.hermes
HERMES_CONFIG_PATH=%USERPROFILE%\.hermes\config.yaml
HERMES_WEBUI_AGENT_DIR=%LOCALAPPDATA%\hermes\hermes-agent
HERMES_WEBUI_STATE_DIR=%USERPROFILE%\.hermes\webui
HERMES_WEBUI_DEFAULT_WORKSPACE=%USERPROFILE%\HermesWorkspace
HERMES_WEBUI_HOST=127.0.0.1
HERMES_WEBUI_PORT=<selected-port>
HERMES_WEBUI_BOT_NAME=Hermes
```

Rationale:

- Upstream `bootstrap.py` explicitly rejects native Windows.
- `server.py` itself can discover Windows venv Python and was verified to serve `/health`.

### Keep WebUI localhost-only

First version binds to `127.0.0.1` only.

Rationale:

- WebUI can read sessions, workspace files, and interact with the agent.
- Localhost-only avoids accidental LAN exposure.
- Remote/mobile access can be a separate security-focused change.

### Apply Chinese defaults via settings API

After `/health` succeeds, call:

```text
POST /api/settings
{
  "language": "zh",
  "default_workspace": "%USERPROFILE%\\HermesWorkspace",
  "theme": "dark",
  "send_key": "enter",
  "check_for_updates": false,
  "show_cli_sessions": false,
  "show_token_usage": false,
  "bot_name": "Hermes"
}
```

Rationale:

- Upstream locale key is `zh`, not `zh-CN`.
- API persistence writes valid UTF-8 without BOM and merges current defaults.
- PowerShell 5 `Set-Content -Encoding UTF8` writes a BOM; Python `json.loads` rejected the manually written settings file during the spike.

Fallback: write `settings.json` with `[System.Text.UTF8Encoding]::new($false)` only when the API is unavailable and before startup.

### Preserve CLI as fallback

Split internal intent from implementation:

```text
launch       = user intent to start conversation
launch-webui = default WebUI path
launch-cli   = existing terminal path
```

Rationale:

- The launcher should keep a known working path if WebUI installation or runtime fails.
- Existing users and diagnostics still benefit from direct CLI access.

### Track WebUI runtime separately from Hermes gateway runtime

Create a launcher state file:

```text
%USERPROFILE%\.hermes\webui-launcher.json
```

Suggested fields:

```json
{
  "source_repo": "nesquena/hermes-webui",
  "version_label": "v0.50.63",
  "commit": "a512f2020e01ef8c98989eb00c84a8d8cfc81ee1",
  "webui_dir": "...",
  "state_dir": "...",
  "workspace": "...",
  "pid": 12345,
  "port": 8787,
  "url": "http://127.0.0.1:8787",
  "out_log": "...",
  "err_log": "...",
  "installed_at": "...",
  "started_at": "..."
}
```

Rationale:

- Enables reuse of an existing healthy WebUI process.
- Gives support/debugging enough information without scanning processes blindly.
- Allows future restart/update actions.

## Runtime Flow

```text
Start Conversation
  │
  ├─ Hermes missing/model not ready ──▶ use existing install/model guidance
  │
  └─ Hermes ready
       │
       ├─ WebUI missing ──▶ install fixed commit archive
       │
       ├─ pyyaml missing ─▶ install into Hermes venv
       │
       ├─ choose port: 8787, 8788, 8789, ...
       │
       ├─ start server.py hidden with stdout/stderr logs
       │
       ├─ wait for /health
       │    ├─ ok ───────▶ POST /api/settings language=zh
       │    │              open browser
       │    └─ timeout ──▶ show failure + logs + CLI fallback
       │
       └─ save webui-launcher.json
```

State machine:

```text
WebUIMissing
   │
   ▼
Installing
   │
   ▼
Stopped ── start ──▶ Starting ── /health ok ──▶ Running
   ▲                    │
   │                    └── error/timeout ───▶ Failed
   │
   └──── restart/stop ◀────────────────────── Running
```

## Risks / Trade-offs

- Upstream has no releases/tags → pin a commit and document the version label; update only in launcher releases.
- Upstream WebUI may change API shape → health/settings calls must fail gracefully and preserve CLI fallback.
- Windows compatibility warning `No module named 'fcntl'` appears for `tools.memory_tool` → do not treat stderr warnings as startup failure if `/health` is ok; surface logs for debugging.
- WebUI onboarding may not understand all launcher-supported OAuth/advanced providers → launcher remains the authority for model readiness and does not rely on WebUI onboarding for first-run setup.
- Port collision may point at a non-WebUI service → `/health` must return JSON with `status: ok`; otherwise try the next port.
- Hidden process can be orphaned → record PID/port/logs and provide restart/open-log actions.
- PowerShell UTF-8 BOM can break manual JSON files → prefer API settings write; when writing JSON directly, use `UTF8Encoding($false)`.

## Migration Plan

1. Add WebUI detection and self-test reporting without changing the primary launch action.
2. Add install/start/health/settings helpers and verify with the fixed commit.
3. Switch primary "开始对话" to WebUI after helpers are validated.
4. Add CLI fallback and WebUI management actions.
5. Update README and release notes.

Rollback:

- Revert the primary launch action to the existing CLI behavior.
- Leave installed WebUI files and `%USERPROFILE%\.hermes\webui` state in place; they are inert if not started.
- Users can still launch CLI through the existing command path.

## Open Questions

- Should the first implementation expose "Stop WebUI", or only "Restart WebUI" and "Open logs"?
- Should `check_for_updates` be forced to `false` forever, or only initialized to `false` on first setup?
- Should the default port range be `8787..8799`, or include the user-tested `18789` as a fallback/debug port?
- Should WebUI update keep one backup or multiple backups?
