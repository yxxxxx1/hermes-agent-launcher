## Context

The current macOS app already separates setup and management states, but both screens still rely on multiple cards that repeat the same facts:

- the current stage is shown in the top banner, hero text, spotlight card, and progress card
- management state is shown in the hero, overview metrics, and a separate status card
- install-stage side panels expose system data that is not needed to complete the current step

This structure creates visual activity without increasing decision quality. For non-technical users, the launcher must reduce reading load and keep the interface answer-oriented:

- What should I do now?
- Did it work?
- If it did not work, what is the next safe thing to try?

## Goals / Non-Goals

**Goals**

- Make the install stage read as a guided wizard, not a dashboard.
- Remove repeated status summaries from the install stage.
- Keep install-stage support available, but demote it to a lightweight recovery affordance.
- Make the management center read as an action hub, not a technical control panel.
- Separate high-frequency actions from low-frequency maintenance actions.
- Use plain-language labels that describe outcomes instead of system internals.

**Non-Goals**

- Changing launcher state derivation logic.
- Changing install, model, chat, or gateway command execution semantics.
- Removing advanced maintenance capabilities entirely.
- Redesigning the app into a different navigation model such as tabs or sidebars.

## Decisions

### 1. Install stage will become a single-column guided flow

The install stage will keep only:

- the current-step title and explanation
- the primary action
- a compact progress summary
- a lightweight help/recovery entry

The install-stage side panel will be removed.

Rationale:

- The user only needs to complete the current step.
- Provider, model, chat, gateway, and path details do not help that decision.

### 2. Install-stage recovery will be inline, not a standalone tools module

The current install-stage help/tools card will be replaced with a collapsed inline recovery affordance near the bottom of the main flow. It will expose only user-readable recovery actions such as:

- try this step again
- check whether this step already finished
- get help

Technical entries such as logs, config files, directories, and environment files will not be first-level install-stage actions.

Rationale:

- Non-technical users need next-step recovery, not system introspection.
- A large secondary panel competes with the main onboarding action.

### 3. Management center will prioritize high-frequency actions

The first level of the management center will emphasize only the actions a typical user is likely to need regularly, for example:

- start using Hermes
- check whether Hermes is working
- change the model
- connect messaging notifications
- rerun setup

Low-frequency operations will move into a secondary maintenance area.

Rationale:

- The management center should optimize for common intent, not feature completeness on the first screen.
- Non-technical users think in outcomes, not implementation surfaces.

### 4. Low-frequency maintenance actions will move behind a second level

Actions such as the following will be demoted into a secondary maintenance area:

- diagnostics and records
- config and file access
- data/install directories
- official docs and repository links
- uninstall

These actions remain available but should not dominate the default management view.

Rationale:

- These are valuable support tools, but they are not high-frequency tasks for the primary audience.

### 5. User-facing copy will describe outcomes, not internals

The launcher will prefer user language such as:

- "Start using"
- "Check whether everything is working"
- "Change model"
- "Connect message notifications"
- "Run setup again"

It will avoid first-level wording that assumes technical literacy, such as:

- view logs
- open config
- open install directory
- open environment file

Rationale:

- The product goal is confidence and completion, not system transparency for its own sake.

## Risks / Trade-offs

- [Less visible system state for power users] -> Keep low-frequency maintenance accessible under the secondary maintenance layer.
- [Support debugging becomes less discoverable] -> Preserve the recovery affordance in setup and the maintenance layer in management.
- [Some users may want direct file access] -> Keep file-level actions reachable, but not at the top level.

## Migration Plan

1. Reduce install-stage structure to a single-column flow.
2. Remove install-stage system status and filesystem panels.
3. Replace install-stage tools with inline recovery.
4. Rebuild management-center first-level actions around high-frequency intent.
5. Demote low-frequency maintenance and technical actions to a secondary layer.
6. Rewrite user-facing copy in plain language.

Rollback strategy:

- Restore the previous `macos-app` launcher layout while keeping the underlying launcher logic unchanged.
