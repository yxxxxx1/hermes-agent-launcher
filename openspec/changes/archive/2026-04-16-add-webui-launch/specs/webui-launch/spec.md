## ADDED Requirements

### Requirement: Launcher installs WebUI from an approved stable source

The launcher SHALL install Hermes WebUI from a launcher-approved fixed upstream `nesquena/hermes-webui` commit archive instead of tracking upstream `master` dynamically.

#### Scenario: WebUI is missing

- **WHEN** the user starts conversation and the WebUI directory is missing or invalid
- **THEN** the launcher downloads the configured archive commit, extracts it to a staging directory, validates required files, and promotes it to the WebUI install directory

#### Scenario: WebUI archive validation fails

- **WHEN** the downloaded or extracted WebUI archive does not contain required files
- **THEN** the launcher does not replace the existing WebUI install and reports a retryable installation failure

#### Scenario: WebUI update target is the bundled stable version

- **WHEN** the user chooses to update WebUI in the first implementation
- **THEN** the launcher updates to the WebUI commit bundled with the launcher version, not an arbitrary latest upstream commit

### Requirement: Launcher starts WebUI on localhost and opens the browser

The launcher SHALL start WebUI with the Hermes venv Python, bind it to `127.0.0.1`, wait for a successful health check, and open the resulting local URL in the default browser.

#### Scenario: WebUI starts successfully

- **WHEN** Hermes is installed, model configuration is ready, and the user clicks "开始对话"
- **THEN** the launcher starts or reuses a local WebUI server, verifies `/health` returns ok, and opens the WebUI URL in the browser

#### Scenario: Default port is occupied

- **WHEN** the default WebUI port is unavailable or does not return valid WebUI health
- **THEN** the launcher tries the next configured localhost port before reporting failure

#### Scenario: WebUI startup fails

- **WHEN** WebUI does not become healthy before the startup timeout
- **THEN** the launcher reports the failed stage, keeps or records the relevant logs, and offers the CLI conversation fallback

### Requirement: Launcher applies Chinese WebUI defaults

The launcher SHALL configure WebUI to use upstream locale key `zh` and a safe default workspace before opening the browser.

#### Scenario: Settings API is available

- **WHEN** WebUI health succeeds
- **THEN** the launcher posts settings including `language=zh`, `default_workspace`, `theme=dark`, and `check_for_updates=false` to `/api/settings`

#### Scenario: Manual settings file write is required

- **WHEN** the launcher must write WebUI settings directly
- **THEN** it writes JSON as UTF-8 without BOM so WebUI can parse the file

### Requirement: Launcher preserves CLI conversation fallback

The launcher SHALL keep the existing terminal-based Hermes conversation path available when WebUI is unavailable or when the user explicitly selects it.

#### Scenario: Model is not ready

- **WHEN** the user clicks "开始对话" before model configuration is ready
- **THEN** the launcher sends the user through the existing model configuration flow instead of starting WebUI

#### Scenario: User chooses CLI fallback

- **WHEN** the user chooses the command-line conversation action
- **THEN** the launcher opens the existing Hermes CLI terminal flow

#### Scenario: WebUI fails

- **WHEN** WebUI installation or startup fails
- **THEN** the launcher provides an action to start the CLI conversation without requiring WebUI

### Requirement: Launcher records WebUI runtime state

The launcher SHALL persist WebUI runtime metadata so it can reuse, debug, restart, and report the local WebUI process.

#### Scenario: WebUI starts

- **WHEN** the launcher successfully starts WebUI
- **THEN** it records commit, install directory, state directory, workspace, PID, port, URL, logs, and start time in `%USERPROFILE%\.hermes\webui-launcher.json`

#### Scenario: Self-test runs

- **WHEN** the user runs `HermesGuiLauncher.ps1 -SelfTest`
- **THEN** the output includes WebUI install status, configured stable commit, runtime state, last known port, and log paths without starting WebUI

#### Scenario: Existing WebUI state is stale

- **WHEN** the runtime state file references a dead process or unhealthy port
- **THEN** the launcher treats WebUI as stopped and can start a fresh server
