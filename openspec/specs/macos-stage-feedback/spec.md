# macos-stage-feedback

## Purpose

Define consistent success and failure feedback for the macOS launcher onboarding stages.
## Requirements
### Requirement: The launcher MUST persist lightweight session markers for onboarding stages

The macOS launcher MUST record the last onboarding stage, the last stage result, and the last log path so it can evaluate completion when the user returns from Terminal.

#### Scenario: A stage is launched

- Given the user starts install, model setup, or first chat
- When the launcher hands the command off to Terminal
- Then it records the stage as running
- And it stores the log path associated with that launch

#### Scenario: The launcher loads a stale incomplete session marker

- Given the launcher state file contains a non-idle stage result
- And the state file does not contain a usable log path
- When the launcher loads session state
- Then it resets the session marker to an idle state
- And it avoids presenting a broken completion or recovery flow

### Requirement: Install and model setup MUST use post-check success criteria

The macOS launcher MUST confirm stage success with post-checks instead of trusting exit codes alone.

#### Scenario: Install completes successfully

- Given the last recorded stage is install
- And the Terminal flow reported success
- When the launcher next evaluates onboarding state
- Then it verifies that Hermes is now detectable locally
- And it shows an install success message with model setup as the next step

#### Scenario: Model setup completes successfully

- Given the last recorded stage is model setup
- And the Terminal flow reported success
- When the launcher next evaluates onboarding state
- Then it verifies that a usable model configuration is detectable
- And it shows a model success message with first chat as the next step

### Requirement: Failure feedback MUST include recovery paths

The macOS launcher MUST provide a consistent recovery dialog when an onboarding stage is incomplete or fails.

#### Scenario: Install or model setup is incomplete

- Given the last recorded stage is install or model setup
- And the required post-check still fails
- When the launcher returns to the dashboard loop
- Then it offers retry
- And it offers opening the stage log
- And it offers returning to the dashboard without forcing another action

#### Scenario: WebUI chat handoff fails

- Given the last recorded stage is first chat
- And the WebUI server did not become healthy
- When the launcher returns to the dashboard loop
- Then it offers retry
- And it offers opening the WebUI bootstrap log
- And it offers a Terminal chat fallback
- And it does not claim that browser chat is ready

### Requirement: Successful first-chat handoff MUST be described conservatively

The macOS launcher MUST describe first-chat success as a successful WebUI browser handoff, not as a verified conversation session.

#### Scenario: First chat handoff succeeds

- Given the last recorded stage is first chat
- And the WebUI server became healthy
- When the launcher shows completion feedback
- Then it tells the user the Hermes WebUI browser chat has been opened
- And it instructs the user to confirm the Hermes interface in the browser

