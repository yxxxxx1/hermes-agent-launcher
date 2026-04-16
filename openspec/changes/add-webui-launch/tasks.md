## 1. WebUI Source And Install

- [x] 1.1 Add constants for WebUI source repo, version label, fixed commit, archive URL, and default runtime paths.
- [x] 1.2 Implement WebUI install detection that verifies `server.py`, `requirements.txt`, and `static/index.html`.
- [x] 1.3 Implement fixed-commit archive download to a staging directory.
- [x] 1.4 Implement safe extraction, validation, atomic replacement, and single-backup rollback for the WebUI directory.
- [x] 1.5 Install or verify `pyyaml` in the Hermes venv using `uv pip` first and Python `pip` as fallback.

## 2. Runtime Management

- [x] 2.1 Add WebUI runtime state read/write helpers for `%USERPROFILE%\.hermes\webui-launcher.json`.
- [x] 2.2 Add port selection for localhost, starting at 8787 and skipping ports that do not return WebUI health.
- [x] 2.3 Start WebUI `server.py` with Hermes venv Python, explicit environment variables, and separate stdout/stderr logs.
- [x] 2.4 Implement `/health` polling with timeout and clear failure states.
- [x] 2.5 Apply Chinese/default settings via `POST /api/settings` after health succeeds.
- [x] 2.6 Reuse an already healthy WebUI process when state points to a live server.

## 3. Launcher UX

- [x] 3.1 Split the existing conversation action into user intent `launch`, default `launch-webui`, and fallback `launch-cli`.
- [x] 3.2 Change "开始对话" to use the WebUI path when Hermes and model configuration are ready.
- [x] 3.3 Preserve the existing CLI terminal launch as "打开命令行对话" in advanced settings or a fallback dialog.
- [x] 3.4 Add WebUI management actions: open WebUI, restart WebUI, update WebUI to bundled stable version, open WebUI logs, and open WebUI directory.
- [x] 3.5 Add user-facing Chinese failure messages that include the failed stage and next action.

## 4. Validation And Documentation

- [x] 4.1 Extend `-SelfTest` with WebUI install status, configured commit, runtime state, last port, and log paths.
- [x] 4.2 Validate a clean WebUI install path on Windows with no existing WebUI directory.
- [x] 4.3 Validate reuse of an already running healthy WebUI server.
- [x] 4.4 Validate fallback when the WebUI port is occupied by another service.
- [x] 4.5 Validate fallback to CLI when WebUI install or startup fails.
- [x] 4.6 Update README with WebUI source commit, runtime paths, validation command, and update policy.
