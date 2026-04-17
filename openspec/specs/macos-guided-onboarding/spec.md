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

The macOS launcher MUST replace the old flat action list with a dashboard that shows onboarding progress and one dynamic primary action.

#### Scenario: Launcher shows a guided dashboard

- Given the launcher opens on macOS
- When the top-level menu is displayed
- Then it shows stage progress for install, model setup, and first chat
- And it includes exactly one primary onboarding action
- And it keeps advanced functionality behind a separate advanced menu entry

### Requirement: Install, model configuration, and first chat MUST use guided entry flows

The macOS launcher MUST wrap each primary onboarding action in a short explanation dialog before opening Terminal.

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
- Then the launcher explains that Terminal will open for the local chat entrypoint
- And it opens the chat flow in Terminal

### Requirement: Advanced maintenance actions MUST remain reachable

The macOS launcher MUST preserve existing maintenance and support actions under an advanced menu.

#### Scenario: User opens advanced options

- Given the launcher is showing the top-level dashboard
- When the user chooses advanced options
- Then the launcher shows maintenance, diagnostics, gateway, file access, documentation, and uninstall actions
- And those actions remain callable without changing the onboarding flow
