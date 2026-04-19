## 1. WebUI Launch Flow

- [x] 1.1 Add macOS launcher constants for the Hermes WebUI repository, install directory, localhost URL, and default port.
- [x] 1.2 Detect whether Hermes WebUI is installed and whether its `/health` endpoint is running.
- [x] 1.3 Replace the `chat` action with a WebUI bootstrap/open flow that avoids opening Terminal.
- [x] 1.4 Record WebUI bootstrap logs and stage state for success and failure recovery.
- [x] 1.5 Add a Terminal chat fallback action for WebUI dependency/startup failures.

## 2. Launcher UX

- [x] 2.1 Update onboarding copy so the third step describes browser chat instead of Terminal chat.
- [x] 2.2 Update management-center primary chat copy to launch WebUI.
- [x] 2.3 Surface WebUI status in state snapshots without exposing unnecessary technical details.
- [x] 2.4 Default launcher-managed Hermes WebUI sessions to Chinese while preserving explicit user language choices.
- [x] 2.5 Keep the model configuration terminal flow readable by forcing the Hermes model picker into a plain numbered display.
- [x] 2.6 Expose Terminal chat as a secondary maintenance/recovery entry without making it the primary daily-use path.

## 3. Validation

- [x] 3.1 Validate the OpenSpec change with `openspec validate upgrade-macos-chat-to-webui --strict`.
- [x] 3.2 Build the Swift launcher with `swift build`.
- [x] 3.3 Run launcher state/self tests where possible without requiring network installation.
