# macos-management-center Specification

## Purpose
TBD - created by archiving change simplify-macos-launcher-information-architecture. Update Purpose after archive.
## Requirements
### Requirement: The management center MUST prioritize high-frequency user actions

The macOS launcher MUST present the most common post-setup actions on the first level of the management center, with browser-based Hermes WebUI chat as the primary daily-use action.

#### Scenario: User opens the management center

- Given onboarding is complete
- When the management center is displayed
- Then the first visible action area emphasizes high-frequency user tasks
- And the primary conversation action opens Hermes WebUI in the browser
- And launcher-managed first-run WebUI settings default the interface language to Chinese
- And Terminal chat remains reachable as a secondary fallback for WebUI startup or dependency failures
- And those tasks are phrased in user language focused on outcomes
- And the user does not need to scan technical maintenance actions before finding common tasks

### Requirement: The management center MUST reduce repeated state summaries

The macOS launcher MUST avoid presenting the same management-state information in multiple competing cards.

#### Scenario: Management center shows current state

- Given onboarding is complete
- When the management center is displayed
- Then it provides a concise summary of the current Hermes state
- And it does not restate the same provider, model, or chat state across multiple parallel summary modules

### Requirement: Low-frequency maintenance actions MUST move to a secondary layer

The macOS launcher MUST keep low-frequency and technical maintenance actions reachable without presenting them as first-level management actions.

#### Scenario: User needs maintenance features

- Given onboarding is complete
- When the user opens the secondary maintenance area
- Then the launcher provides access to diagnostics, records, file-level access, official resources, and uninstall actions
- And those actions are separated from the first-level high-frequency actions

### Requirement: First-level management copy MUST use plain language

The macOS launcher MUST use wording that non-technical users can understand without knowing Hermes internals.

#### Scenario: User scans first-level management actions

- Given onboarding is complete
- When the user reads the first-level management actions
- Then the labels describe user goals and expected outcomes
- And they avoid technical file, log, directory, or environment terminology at the first level

