## Decision

Use `nesquena/hermes-webui` as an external local checkout managed by the launcher at `~/.hermes/hermes-webui`. The launcher starts it through `bootstrap.py --no-browser --skip-agent-install --host 127.0.0.1 8787`, waits for `http://127.0.0.1:8787/health`, then opens `http://localhost:8787`.

## Rationale

- Keeping WebUI as a checkout avoids vendoring a separate app into this launcher repository.
- Using the WebUI bootstrap keeps dependency setup owned by WebUI and follows its documented startup path.
- Binding to `127.0.0.1` preserves the safe local-only default.
- Opening the system browser is simpler and more robust than embedding the WebUI in SwiftUI for this iteration.

## Alternatives Considered

- Embed WebUI in the Swift app: rejected for this iteration because WebUI is already a browser application with its own server lifecycle.
- Keep Terminal chat and add WebUI as advanced action: rejected because the goal is to upgrade the primary conversation window away from Terminal.
- Use Docker: rejected for the default path because it introduces an extra dependency and is less friendly for first-time macOS users.

## Failure Handling

If WebUI cannot be cloned, bootstrapped, or made healthy, the launcher records a failed `chat` stage and stores the bootstrap log. The next dashboard refresh can offer retry, open log, or return home without claiming the chat is available.
