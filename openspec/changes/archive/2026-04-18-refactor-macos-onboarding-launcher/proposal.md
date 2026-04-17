## Why

The current macOS launcher exposes Hermes as a list of technical actions instead of a guided setup flow. Users who do not understand the command line or Hermes concepts cannot reliably tell what to do first, when installation is actually complete, or how to recover from a failed step.

This change is needed now because the launcher's target audience is non-technical macOS users. The launcher needs to optimize for first-time success, not for exposing every Hermes command up front.

## What Changes

- Replace the current top-level action menu with a stage-driven onboarding dashboard centered on three steps: install Hermes, configure a model, and start the first local chat.
- Introduce a single primary action that changes based on detected setup state, so users are always guided to the next required step.
- Add pre-flight intro dialogs before install, model configuration, and first chat launch to explain what will happen, especially when Terminal opens.
- Add explicit success and failure feedback after each main onboarding stage instead of relying on raw Terminal output and log paths alone.
- Move maintenance, gateway, file access, update, doctor, and uninstall actions into an advanced menu so they do not distract first-time users.
- Preserve the existing underlying Hermes command execution model and filesystem layout; this change is focused on macOS launcher UX and flow control.

## Capabilities

### New Capabilities
- `macos-guided-onboarding`: Guide macOS users through a three-stage Hermes setup flow with one clear next action at a time.
- `macos-stage-feedback`: Explain stage transitions, Terminal handoff, success states, and recovery paths in user-facing language.

### Modified Capabilities
- None.

## Impact

- Affected code: `HermesMacGuiLauncher.command`
- Affected UX surface: macOS launcher dialogs, menus, status text, and action routing
- Affected systems: AppleScript dialog flow, Terminal launch handoff, launcher state derivation
- Dependencies: no new runtime dependencies required; continues to use `osascript`, `open`, and Hermes CLI commands
