## MODIFIED Requirements

### Requirement: Successful first-chat handoff MUST be described conservatively

The macOS launcher MUST describe first-chat success as a successful WebUI browser handoff, not as a verified conversation session.

#### Scenario: First chat handoff succeeds

- Given the last recorded stage is first chat
- And the WebUI server became healthy
- When the launcher shows completion feedback
- Then it tells the user the Hermes WebUI browser chat has been opened
- And it instructs the user to confirm the Hermes interface in the browser

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
