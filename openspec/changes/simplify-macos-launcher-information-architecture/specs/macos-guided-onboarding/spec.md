## MODIFIED Requirements

### Requirement: The top-level launcher menu MUST focus on one next step at a time

The macOS launcher MUST present onboarding as a low-noise guided flow with one clear next action, compact progress context, and no repeated system summaries that compete with the current step.

#### Scenario: Install-stage launcher shows a guided flow

- Given the launcher is in the install, model setup, or first-chat onboarding state
- When the onboarding screen is displayed
- Then it shows one primary onboarding action for the current step
- And it shows compact progress for install, model setup, and first chat
- And it does not show repeated stage summaries in multiple parallel cards

### Requirement: Advanced maintenance actions MUST remain reachable

The macOS launcher MUST keep install-stage recovery available without exposing a full technical tools surface during onboarding.

#### Scenario: User needs help during onboarding

- Given the launcher is showing an onboarding step
- When the user looks for help with that step
- Then the launcher exposes a lightweight recovery entry
- And the recovery entry is collapsed by default
- And its first-level actions use plain language focused on what to try next
- And it does not present logs, config files, directories, or environment files as primary onboarding actions
