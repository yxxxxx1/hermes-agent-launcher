## Why

The current macOS launcher UI improved the visual presentation of onboarding, but it still carries too much repeated status information across install and management states. The result is a launcher that looks richer than before while still forcing users to scan multiple panels that restate the same thing in different ways.

This is a poor fit for the intended audience: non-technical users who need one clear next action, not a dashboard full of system-oriented status summaries. The install stage should behave like a guided flow, and the management center should behave like a simple action hub with obvious high-frequency tasks.

## What Changes

- Simplify the install stage into a single-column guided flow centered on the current step, primary action, and a compact progress summary.
- Remove install-stage status panels that expose provider, model, gateway, filesystem paths, or other system internals before they are useful.
- Replace the install-stage advanced tools card with a lightweight, collapsed help/recovery entry that only exposes user-understandable recovery actions.
- Simplify the management center by promoting only high-frequency, user-facing actions to the first level.
- Move low-frequency maintenance, file access, diagnostic, and destructive actions behind a secondary "more maintenance" surface.
- Rewrite launcher-facing labels and helper text in plain language aimed at users who do not understand logs, config files, directories, or environment variables.

## Capabilities

### Modified Capabilities
- `macos-guided-onboarding`: The onboarding UI becomes a low-noise guided flow instead of a multi-panel status dashboard.

### New Capabilities
- `macos-management-center`: The post-setup launcher surface prioritizes high-frequency actions and hides low-frequency maintenance behind a secondary layer.

## Impact

- Affected code: `macos-app/Sources/LauncherRootView.swift`, `macos-app/Sources/LauncherModels.swift`, and any related launcher copy definitions
- Affected UX surface: install-stage layout, management-center layout, action grouping, and user-facing copy
- Affected users: first-time macOS users and non-technical daily users of the launcher
- Dependencies: no new runtime dependencies required
