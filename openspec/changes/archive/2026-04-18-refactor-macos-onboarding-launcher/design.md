## Context

`HermesMacGuiLauncher.command` currently behaves like a thin action dispatcher over Hermes CLI commands. It derives some local state such as installation presence, model readiness, and gateway runtime, but it presents those signals as a technical status summary followed by a flat list of actions.

This is misaligned with the intended audience for the macOS launcher in this iteration: users who do not understand command-line workflows and need a guided path to first-time success. The launcher must therefore optimize for the first usable Hermes session instead of surfacing all maintenance operations at the top level.

Constraints:
- The launcher must remain a single macOS shell script using `osascript` dialogs and Terminal handoff.
- The launcher must preserve the existing Hermes install location, config scaffolding, and command execution model.
- The launcher must continue to work even when Hermes is not yet installed.

## Goals / Non-Goals

**Goals:**
- Replace the top-level flat action menu with a three-stage onboarding flow: install, configure model, start first chat.
- Compute the user's next primary action from detected local state instead of requiring them to understand Hermes concepts.
- Explain Terminal handoff before each main onboarding action so non-technical users are not surprised by shell windows.
- Surface explicit success and failure dialogs after onboarding stages, with recovery actions that do not require reading raw logs first.
- Move maintenance and advanced operations into a secondary menu without removing their underlying functionality.

**Non-Goals:**
- Rewriting the launcher as a native macOS application.
- Changing the Windows launcher or the website download page.
- Changing Hermes install commands, config file formats, or on-disk data layout.
- Adding new Hermes product features such as new providers or gateway integrations.

## Decisions

### 1. Use a derived onboarding state machine instead of a persistent wizard

The launcher will infer its current onboarding stage from existing runtime checks:
- Hermes installed: `resolve_hermes_command`
- Model ready: `test_model_ready`
- Optional advanced state: gateway configured/running

The script will keep only lightweight in-memory session markers for the last stage started, the last result, and the last log path so it can show completion or failure feedback on the next loop iteration.

Rationale:
- The launcher already has reliable environment probes.
- A derived state model avoids introducing new state files that can drift from the actual Hermes installation.

Alternative considered:
- Persisting wizard progress to disk. Rejected because it adds failure modes where recorded progress no longer matches the machine state.

### 2. Collapse the primary experience into one dynamic next-step action

The top-level menu will expose one primary action whose label depends on the derived state:
- Not installed -> `开始安装`
- Installed but model not ready -> `配置模型`
- Installed and model ready -> `开始第一次对话`

Advanced functions move under `高级选项`.

Rationale:
- Non-technical users need guidance, not tool discovery.
- One clear next step reduces the chance of opening gateway setup or maintenance commands before Hermes is usable.

Alternative considered:
- Keeping the current full menu and just reordering items. Rejected because it still forces users to interpret technical choices too early.

### 3. Keep Terminal execution, but wrap it in expectation-setting dialogs

The launcher will continue to open Terminal for install, model configuration, chat launch, and advanced Hermes actions. Before install, model setup, and first chat, the launcher will show short dialogs that explain:
- Terminal will open
- This is normal
- The user should not close it during execution
- Logs can be opened if something fails

Rationale:
- Reusing the current execution model avoids a risky platform rewrite.
- The main UX problem is surprise and ambiguity, not the existence of Terminal itself.

Alternative considered:
- Hiding Terminal or embedding command output in AppleScript dialogs. Rejected because it is much more complex and unnecessary for this iteration.

### 4. Separate onboarding flows from maintenance flows

The script will group existing secondary actions into an advanced menu:
- doctor
- update
- tools
- full setup
- gateway configuration and launch
- file and log access
- uninstall

Rationale:
- These actions remain useful for support and power users.
- They should not compete with first-time install and chat onboarding.

Alternative considered:
- Removing advanced actions entirely. Rejected because the launcher still needs a practical support path.

### 5. Standardize stage completion and failure handling

Each onboarding stage will have a matching completion check and feedback rule:
- Install succeeds when Hermes can be resolved locally after the action returns.
- Model setup succeeds when model/provider readiness is detected.
- Chat launch succeeds when the command is handed off successfully; the launcher will not attempt to introspect conversation content.

Failures will map to a common recovery dialog with actions such as retry, open logs, and return home.

Rationale:
- Users need a consistent definition of success and a predictable recovery path.
- Chat success cannot be fully verified from the launcher without coupling to Hermes internals.

Alternative considered:
- Relying only on command exit code. Rejected because the launcher already has stronger post-checks for install and model readiness.

## Risks / Trade-offs

- [Derived state can miss edge cases] -> Keep the state machine based on existing, conservative probes and allow users to re-enter advanced tools if needed.
- [AppleScript dialog UI is limited] -> Optimize information architecture and wording instead of attempting a fake rich UI.
- [Terminal commands can outlive the launcher loop] -> Use stage markers and post-checks only for steps with deterministic readiness checks.
- [Users may still need advanced features early] -> Keep advanced actions accessible from the top level, but secondary to the primary action.

## Migration Plan

1. Add onboarding state helpers and next-action derivation without removing existing command helpers.
2. Replace the top-level menu and status summary with the new dashboard prompt and advanced menu entry.
3. Wrap install, model, and chat entry points with intro dialogs and stage result tracking.
4. Add stage completion and failure dialogs that evaluate state on the next loop iteration.
5. Move maintenance and gateway actions into the advanced menu and verify all previous actions remain reachable.

Rollback strategy:
- Revert `HermesMacGuiLauncher.command` to the previous menu-driven flow. No data migration is required because on-disk Hermes state is unchanged.

## Open Questions

- Whether the first-chat success dialog should appear immediately after launching Terminal or only after the user returns to the launcher.
- Whether gateway actions should remain fully available in the first iteration of the advanced menu or be partially deferred.
