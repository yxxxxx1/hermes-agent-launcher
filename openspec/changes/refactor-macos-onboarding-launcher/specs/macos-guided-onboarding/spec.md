## ADDED Requirements

### Requirement: Launcher SHALL guide users through the next required onboarding step
The macOS launcher SHALL present Hermes setup as a guided three-stage flow consisting of install Hermes, configure a model, and start a first local chat. The launcher SHALL determine the next primary action from detected local setup state instead of exposing all launcher actions as equal first-level choices.

#### Scenario: Hermes is not yet installed
- **WHEN** the launcher starts and no Hermes command can be resolved
- **THEN** the launcher SHALL show installation as the next required step
- **THEN** the launcher's primary action SHALL start the install flow

#### Scenario: Hermes is installed but model setup is incomplete
- **WHEN** the launcher starts and Hermes is installed but model readiness is not detected
- **THEN** the launcher SHALL show model configuration as the next required step
- **THEN** the launcher's primary action SHALL start the model configuration flow

#### Scenario: Hermes and model configuration are ready
- **WHEN** the launcher starts and both Hermes installation and model readiness are detected
- **THEN** the launcher SHALL show first chat as the next required step
- **THEN** the launcher's primary action SHALL launch the local chat flow

### Requirement: Launcher SHALL separate onboarding from advanced operations
The macOS launcher SHALL keep first-time onboarding actions at the top level and SHALL move maintenance, diagnostics, gateway, file access, and uninstall actions into an advanced menu.

#### Scenario: User needs the first-time setup path
- **WHEN** the launcher opens
- **THEN** the first-level menu SHALL prioritize the onboarding primary action
- **THEN** advanced operations SHALL be reachable through a secondary `高级选项` entry

#### Scenario: User opens advanced options
- **WHEN** the user selects `高级选项`
- **THEN** the launcher SHALL present maintenance and power-user actions without altering the onboarding state model

