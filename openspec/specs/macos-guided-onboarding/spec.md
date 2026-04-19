# macos-guided-onboarding

## Purpose

Define the macOS launcher onboarding flow as a guided, stage-driven experience for non-technical users.
## Requirements
### Requirement: The launcher MUST derive onboarding progress from local machine state

The macOS launcher MUST determine onboarding progress from the detected Hermes installation, model readiness, and optional gateway state instead of from a persisted wizard checkpoint.

#### Scenario: Hermes is not installed

- Given the launcher cannot resolve a local Hermes command
- When the launcher computes app state
- Then it marks installation as incomplete
- And it presents install as the next primary action

#### Scenario: Hermes is installed but model setup is incomplete

- Given the launcher can resolve a local Hermes command
- And the launcher does not detect a complete model configuration
- When the launcher computes app state
- Then it marks installation as complete
- And it marks model setup as pending
- And it presents model configuration as the next primary action

#### Scenario: Hermes is installed and model setup is complete

- Given the launcher can resolve a local Hermes command
- And the launcher detects a complete model configuration
- When the launcher computes app state
- Then it marks chat as available
- And it presents first chat launch as the next primary action

### Requirement: The top-level launcher menu MUST focus on one next step at a time

The macOS launcher MUST present onboarding as a low-noise guided flow with one clear next action, compact progress context, and no repeated system summaries that compete with the current step.

#### Scenario: Install-stage launcher shows a guided flow

- Given the launcher is in the install, model setup, or first-chat onboarding state
- When the onboarding screen is displayed
- Then it shows one primary onboarding action for the current step
- And it shows compact progress for install, model setup, and first chat
- And it does not show repeated stage summaries in multiple parallel cards

### Requirement: Install, model configuration, and first chat MUST use guided entry flows

The macOS launcher MUST wrap setup-oriented onboarding actions in short explanation dialogs, keep Terminal handoffs for install and model configuration, and launch the first chat in Hermes WebUI instead of Terminal.

#### Scenario: User starts installation

- Given install is the next primary action
- When the user chooses to continue
- Then the launcher explains that Terminal will open
- And it warns the user not to close Terminal during the process
- And it opens the install flow in Terminal

#### Scenario: User starts model configuration

- Given model configuration is the next primary action
- When the user chooses to continue
- Then the launcher explains that Terminal will open for model setup
- And it opens the model configuration flow in Terminal

#### Scenario: User starts the first chat

- Given first chat is the next primary action
- When the user chooses to continue
- Then the launcher explains that Hermes WebUI will open in the browser
- And it starts or reuses the local Hermes WebUI server
- And it opens the browser chat window without launching a Terminal chat session

### Requirement: Advanced maintenance actions MUST remain reachable

The macOS launcher MUST keep install-stage recovery available without exposing a full technical tools surface during onboarding.

#### Scenario: User needs help during onboarding

- Given the launcher is showing an onboarding step
- When the user looks for help with that step
- Then the launcher exposes a lightweight recovery entry
- And the recovery entry is collapsed by default
- And its first-level actions use plain language focused on what to try next
- And it does not present logs, config files, directories, or environment files as primary onboarding actions

