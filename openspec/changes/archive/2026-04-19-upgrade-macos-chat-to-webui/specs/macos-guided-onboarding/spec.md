## MODIFIED Requirements

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
