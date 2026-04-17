## 1. State Model And Menu Restructure

- [x] 1.1 Add launcher session state fields for the last onboarding stage, last result, and last log path.
- [x] 1.2 Add a derived app-state helper that computes installation, model readiness, and gateway status from the local machine state.
- [x] 1.3 Replace the current top-level action list with a dashboard prompt and one dynamic primary action plus `高级选项`.

## 2. Guided Onboarding Flows

- [x] 2.1 Add intro dialogs for install, model configuration, and first local chat that explain Terminal handoff and expected behavior.
- [x] 2.2 Refactor install handling into a guided flow that records stage progress and evaluates success from Hermes detectability after the action returns.
- [x] 2.3 Refactor model configuration handling into a guided flow that evaluates success from model readiness after the action returns.
- [x] 2.4 Refactor first local chat launch into a guided flow that confirms command handoff without over-claiming runtime validation.

## 3. Advanced Actions And Feedback

- [x] 3.1 Move maintenance, diagnostics, gateway, file access, and uninstall actions into a dedicated advanced menu while preserving existing behaviors.
- [x] 3.2 Add consistent success dialogs for completed onboarding stages with clear next-step guidance.
- [x] 3.3 Add consistent failure dialogs for incomplete onboarding stages with retry and open-log recovery actions.

## 4. Validation

- [x] 4.1 Run launcher self-checks and review the new state transitions for fresh install, installed-without-model, and ready-for-chat paths.
- [x] 4.2 Validate that every previously supported maintenance action remains reachable from the advanced menu.
