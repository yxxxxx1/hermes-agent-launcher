## Why

The Windows launcher currently sends users into a terminal for local Hermes conversations after installation. A browser-based WebUI gives non-technical users a more approachable default conversation surface while preserving the existing CLI path as a fallback.

The upstream `nesquena/hermes-webui` project has been verified to run on Windows when launched directly with the installed Hermes venv Python, so the launcher can manage a stable local WebUI without maintaining a fork.

## What Changes

- Add a launcher-managed Hermes WebUI installation sourced from a fixed upstream `nesquena/hermes-webui` commit archive.
- Change the primary "开始对话" path to start or reuse a local WebUI server, wait for `/health`, apply Chinese defaults, and open the browser.
- Preserve the existing Hermes CLI conversation flow as an explicit fallback action.
- Add WebUI runtime state tracking, logs, health checks, and retryable failure handling.
- Add WebUI management actions under the advanced/settings surface: open, restart, update to bundled stable version, open logs, open directory, and CLI fallback.
- Extend `-SelfTest` to report WebUI install/runtime readiness without starting the WebUI.
- Document the WebUI source commit, runtime paths, validation steps, and update policy.

## Capabilities

### New Capabilities

- `webui-launch`: Launcher-managed installation, startup, health checking, browser opening, Chinese defaults, CLI fallback, and status reporting for Hermes WebUI.

### Modified Capabilities

- None. There are no existing OpenSpec capabilities in this repository yet.

## Impact

- Affected files:
  - `HermesGuiLauncher.ps1`
  - `README.md`
  - Windows release ZIP contents remain the launcher script and `.cmd` wrapper unless the implementation later decides to bundle WebUI assets.
- New local runtime paths:
  - `%LOCALAPPDATA%\hermes\hermes-webui`
  - `%LOCALAPPDATA%\hermes\hermes-webui-staging`
  - `%LOCALAPPDATA%\hermes\hermes-webui-backup`
  - `%USERPROFILE%\.hermes\webui`
  - `%USERPROFILE%\.hermes\webui-launcher.json`
  - `%USERPROFILE%\HermesWorkspace`
- External dependency:
  - Fixed GitHub archive download from `nesquena/hermes-webui`.
  - Hermes venv Python runs WebUI `server.py`.
  - `pyyaml` must be available in the Hermes venv; install via `uv pip` or Python `pip` when missing.
- Security posture:
  - First version binds WebUI only to `127.0.0.1`.
  - No LAN/mobile exposure, password setup UI, Docker mode, or fork-maintained translation in this change.
