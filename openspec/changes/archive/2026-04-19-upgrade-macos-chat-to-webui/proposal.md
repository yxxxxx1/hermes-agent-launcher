## Why

The current macOS launcher still treats Hermes conversation as a Terminal handoff. That is acceptable for setup and maintenance, but it makes the daily conversation path feel technical and fragile for non-technical users.

Hermes WebUI provides a browser-based chat interface backed by the same local Hermes installation. The launcher should promote WebUI as the normal conversation surface while keeping Terminal-based setup and maintenance available when needed.

## What Changes

- Change the macOS first-chat and management chat action from `hermes chat` in Terminal to a browser-based Hermes WebUI launch.
- Add launcher-managed WebUI bootstrap on first chat: clone `nesquena/hermes-webui` into `~/.hermes/hermes-webui`, set Chinese defaults, start the local server, wait for `/health`, and open the browser.
- Track WebUI status in launcher state so the UI can describe whether the browser chat is installed, starting, or already running.
- Default the WebUI language to Chinese (`zh`) on launcher-managed first chat while preserving any existing non-default user language choice.
- Keep Terminal for installation, model setup, diagnostics, updates, gateway, and other maintenance actions.
- Preserve recovery behavior by writing WebUI bootstrap logs and offering retry/log access if browser chat cannot start.
- Provide a Terminal chat fallback when WebUI cannot be prepared or started, especially when Python dependencies fail.

## Impact

- Affected code: `HermesMacGuiLauncher.command`, `macos-app/Sources/LauncherModels.swift`, `macos-app/Sources/LauncherStore.swift`, `macos-app/Sources/LauncherRootView.swift`
- Affected specs: `macos-guided-onboarding`, `macos-stage-feedback`, `macos-management-center`
- Runtime dependency: Git and Python are required to fetch and bootstrap Hermes WebUI when it is not already installed.
