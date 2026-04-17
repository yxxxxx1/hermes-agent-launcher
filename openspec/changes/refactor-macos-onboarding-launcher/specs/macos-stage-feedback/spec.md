## ADDED Requirements

### Requirement: Launcher SHALL explain Terminal handoff before main onboarding actions
Before starting install, model configuration, or first chat launch, the macOS launcher SHALL show a short explanation that Terminal will open, that this is expected, and that the user should not close the window while the action is running.

#### Scenario: User starts installation
- **WHEN** the user chooses to begin installation
- **THEN** the launcher SHALL display a pre-install explanation before opening Terminal

#### Scenario: User starts model configuration
- **WHEN** the user chooses to configure a model
- **THEN** the launcher SHALL display a pre-configuration explanation before opening Terminal

#### Scenario: User starts first chat
- **WHEN** the user chooses to start the first local chat
- **THEN** the launcher SHALL display a pre-chat explanation before opening Terminal

### Requirement: Launcher SHALL show outcome-oriented feedback for onboarding stages
After install, model configuration, or first chat launch, the macOS launcher SHALL show a user-facing result dialog that describes whether the stage completed successfully and what the user should do next.

#### Scenario: Installation completes successfully
- **WHEN** the launcher returns from an install attempt and Hermes is now detectable
- **THEN** the launcher SHALL show that Hermes has been installed successfully
- **THEN** the launcher SHALL guide the user to the model configuration step

#### Scenario: Model configuration completes successfully
- **WHEN** the launcher returns from model configuration and model readiness is now detectable
- **THEN** the launcher SHALL show that model setup is complete
- **THEN** the launcher SHALL guide the user to start the first local chat

#### Scenario: A stage fails or remains incomplete
- **WHEN** the launcher returns from install or model configuration and the required readiness signal is still missing
- **THEN** the launcher SHALL show that the stage did not complete
- **THEN** the launcher SHALL offer recovery actions that include retrying or opening logs

#### Scenario: First chat is launched
- **WHEN** the launcher successfully hands off the first chat command to Terminal
- **THEN** the launcher SHALL show that the chat entry point has been opened
- **THEN** the launcher SHALL not claim that conversation content was validated
