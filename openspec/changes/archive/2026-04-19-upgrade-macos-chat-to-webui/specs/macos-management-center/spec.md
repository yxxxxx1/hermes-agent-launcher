## MODIFIED Requirements

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
