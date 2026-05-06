## 1. Node.js Runtime Layer (M1, M2)

- [ ] 1.1 Add runtime constants (`NODE_REQUIRED_MAJOR`, `NODE_PORTABLE_VERSION=v23.11.0`, `NODE_DIST_BASE`, `LAUNCHER_RUNTIME_DIR`, `NODE_INSTALL_DIR`, `NPM_PREFIX`, `RUNTIME_CACHE_DIR`) at the top of `HermesMacGuiLauncher.command`.
- [ ] 1.2 Implement `detect_node_runtime()` — phase A: `command -v node` to absolute path → call that absolute path with `-v` → parse major version → require `>=23`. Sanity-check that the same `bin/` directory contains `npm`. Emit `node_runtime_kind=system` on success.
- [ ] 1.3 Implement `download_portable_node()` — phase B: arch detection via `uname -m`, hardcoded SHA256 for the `v23.11.0` tarball (both `darwin-arm64` and `darwin-x64`), curl with `--retry 3 --retry-delay 2`, `tar -xzf` to `$NODE_INSTALL_DIR`, defensive `xattr -dr com.apple.quarantine`. Emit `STAGE:download_node STATUS=...` events.
- [ ] 1.4 Implement `ensure_node_runtime()` orchestrator — try phase A, fall back to phase B; final step re-execs `"$NODE_BIN" -v` and `"$NPM_BIN" -v` to confirm the chosen pair works.
- [ ] 1.5 Add bash CLI flag `--probe-node` for M1/M2 verification (prints `node_runtime_kind=...` / `node_runtime_version=...` lines and exits).

## 2. npm Package Lifecycle (M3)

- [ ] 2.1 Add WebUI constants (`WEBUI_NPM_PACKAGE`, `WEBUI_NPM_VERSION="0.5.9"`, `WEBUI_PORT=8648`, `WEBUI_HOST=127.0.0.1`, `WEBUI_HEALTH_URL`).
- [ ] 2.2 Implement `select_npm_registry()` — probe official registry with 4s timeout, fall back to `registry.npmmirror.com` on failure. Cache the choice for the rest of the run.
- [ ] 2.3 Implement `npm_isolated()` shim — `"$NPM_BIN" --prefix "$NPM_PREFIX" --registry "$NPM_REGISTRY" "$@"`.
- [ ] 2.4 Implement `ensure_hermes_web_ui_installed()` — idempotent: if `$NPM_PREFIX/bin/hermes-web-ui --version` reports the target version, skip; otherwise install. After install, defensive `chmod +x` on the bin path. Emit `STAGE:install_webui` events with `DETAIL=<version>` on success and `REASON=<code>` on failure.
- [ ] 2.5 Add bash CLI flag `--install-webui` for M3 verification.

## 3. WebUI Daemon Wrapping (M4, M5)

- [ ] 3.1 Implement `start_hermes_web_ui()` — invoke `"$NPM_PREFIX/bin/hermes-web-ui" start "$WEBUI_PORT"` with `HERMES_HOME` / `GATEWAY_ALLOW_ALL_USERS=true` / `API_SERVER_PORT=8642` / `PORT="$WEBUI_PORT"` set inline (not exported). Forward bin-script stdout into `STAGE:` events; capture full stdout to a temp log on failure.
- [ ] 3.2 Implement `stop_hermes_web_ui()` — invoke `"$NPM_PREFIX/bin/hermes-web-ui" stop`. Idempotent on "not running".
- [ ] 3.3 Implement `status_hermes_web_ui()` — invoke `"$NPM_PREFIX/bin/hermes-web-ui" status`; combine with `webui_health_check` for an authoritative `webui_running` value.
- [ ] 3.4 Replace `webui_health_check()` body with `curl -fsS --max-time 3 "$WEBUI_HEALTH_URL"` (HTTP, not Python urllib).
- [ ] 3.5 Implement `read_webui_token()` — `tr -d '[:space:]' <"$HOME/.hermes-web-ui/.token"`. Use to compose token-bearing browser URL when present.
- [ ] 3.6 Update `open_webui_browser()` (line 1528) to consume `read_webui_token()` and the new port.
- [ ] 3.7 Add bash CLI flags `--start-webui` / `--stop-webui` for M4/M5 verification.

## 4. Legacy Cleanup (M7)

- [ ] 4.1 Implement `cleanup_legacy_python_webui()` — if `~/.hermes/hermes-webui/` exists, atomic `mv` to `~/.hermes/hermes-webui.legacy-$(date +%Y%m%d%H%M%S)`. If port 8787 is occupied by a process whose command line contains `bootstrap.py` or the legacy path, kill it. Emit `STAGE:cleanup_legacy STATUS=ok`.
- [ ] 4.2 Persist a successful-launch counter in `state.env`. After 3 successful launches, set a flag that surfaces a one-time prompt for permanent legacy-dir removal (the prompt itself is UI work, not in this change).
- [ ] 4.3 Wire `cleanup_legacy_python_webui()` into the new launch flow's first phase (before `ensure_node_runtime`).

## 5. IPC Protocol Update

- [ ] 5.1 Update `compute_app_state()` (line 1053): drop `model_ready`, `gateway_configured`, `gateway_running` keys; add `node_runtime_kind`, `node_runtime_version`, `webui_version`, `webui_pid`; update `webui_url` to use the new port.
- [ ] 5.2 Define and document the `STAGE:<phase> STATUS=<s>` event line format alongside the snapshot key=value format. Keep them visually distinguishable (`STAGE:` prefix vs. plain `<key>=<value>`).
- [ ] 5.3 Adjust `build_dashboard_prompt()` (line 1093) to a 2-line summary skeleton (mark a TODO for the UI follow-up to finalize copy).

## 6. Removed Functions and Action Routes

- [ ] 6.1 Delete `test_model_ready()` (line 868–911), `detect_gateway_configured()` (912–925), `detect_gateway_running()` (926–933), `find_webui_python()` (942–973), `configure_model()` (1404–1408), `ensure_webui_checkout()` (1414–1439), `ensure_webui_default_language()` (1440–1479), `prepare_webui_checkout()` (1480–1490), `start_webui_server()` (1491–1527), `configure_gateway()` (1602–1606), `launch_gateway()` (1607–1611), `start_model_flow()` (1748–1755).
- [ ] 6.2 Remove obsolete constants: `WEBUI_REPO_URL`, `DEFAULT_WEBUI_DIR`, `DEFAULT_WEBUI_STATE_DIR`, `WEBUI_DIR`, `WEBUI_STATE_DIR`, `WEBUI_LANGUAGE`, `BRANCH`, `HERMES_WEBUI_PYTHON` env override.
- [ ] 6.3 Remove `configure-model` / `configure-gateway` / `launch-gateway` / `start-model-flow` / standalone `model` cases from `handle_action()` (line 1781).

## 7. Swift Models (`LauncherModels.swift`)

- [ ] 7.1 Reduce `LauncherStage` from `{install, model, chat}` to `{install, launch}`. Update `title` / `detail` / `shortTitle` / `symbolName` / `accentColor` switches.
- [ ] 7.2 In `LauncherSnapshot`, change `webuiURL` default to `"http://localhost:8648"`. Update `stages` initial array to two cards.
- [ ] 7.3 In `LauncherSnapshot`, mark `aiProvider`, `aiModel`, `chatAvailability`, `gatewayStatus`, `gatewayChannel`, `supportSummary` with `@available(*, deprecated, message: "moved to WebUI; will be removed when LauncherRootView migrates")` and seed them with placeholder strings ("已迁移至 WebUI") so the existing UI continues to compile and render harmlessly.
- [ ] 7.4 Add fields: `nodeRuntimeKind: String`, `nodeRuntimeVersion: String`, `webuiVersion: String`, `launchProgress: LaunchProgress?`.
- [ ] 7.5 Add `LaunchProgress` struct with `Phase` and `Status` enums per proposal §3.2.

## 8. Swift Store (`LauncherStore.swift`)

- [ ] 8.1 Update the `compute_app_state` snapshot parser (around line 106) — drop reads of `model_ready` / `gateway_configured` / `gateway_running`; add reads for `node_runtime_kind` / `node_runtime_version` / `webui_version` / `webui_pid`.
- [ ] 8.2 Rebuild the `[StageCardModel]` factory (line 163) to emit two cards based on `installed → webui_installed → webui_running`.
- [ ] 8.3 Implement `launch()` async method — spawn `HermesMacGuiLauncher.command --start-webui`, attach `Pipe` on stdout, parse `STAGE:` lines into `snapshot.launchProgress` updates on the main actor, parse `<key>=<value>` lines into a buffered snapshot delta committed on process exit.
- [ ] 8.4 Implement reason-code → user-message mapping per proposal §4.3. Wire failure events to `LauncherResultCard` construction with appropriate `secondaryActionID` (open WebUI log, open install log).
- [ ] 8.5 Update action dispatcher: remove `configure-model`, `configure-gateway`, `launch-gateway`, `start-model-flow`; add `launch`, `stop-webui`, `restart-webui`; alias `chat` → `launch`.
- [ ] 8.6 Implement cancellation: `Task.cancel()` on the active launch task → SIGTERM to the child bash process → emit a "已取消" `LauncherResultCard`.

## 9. Validation (M6)

- [ ] 9.1 `swift build` succeeds with no warnings except the intentional deprecation notices on the compatibility-shim snapshot fields (§7.3).
- [ ] 9.2 Run `./HermesMacGuiLauncher.command --probe-node` on a machine with system Node ≥23 and on a machine without — both report sensible `node_runtime_kind`.
- [ ] 9.3 Run `./HermesMacGuiLauncher.command --install-webui` and verify `~/.hermes/launcher-runtime/npm-prefix/bin/hermes-web-ui --version` returns `hermes-web-ui v0.5.9`.
- [ ] 9.4 Run `./HermesMacGuiLauncher.command --start-webui`, `curl http://127.0.0.1:8648/health` returns 200, `~/.hermes-web-ui/server.pid` populated, `.token` file exists with mode 0600.
- [ ] 9.5 Run `./HermesMacGuiLauncher.command --stop-webui` — port freed, PID file removed.
- [ ] 9.6 Launch the macOS app, click the launch action, observe `LauncherStore.snapshot.launchProgress` walking through phases in the debugger, and the 2-card stage list rendering. (UI doesn't need polish for M6 — only compile + render correctness.)
- [ ] 9.7 On a machine with `~/.hermes/hermes-webui/` populated, first run renames it to `~/.hermes/hermes-webui.legacy-<ts>/` and the launcher proceeds without error.
- [ ] 9.8 Validate the OpenSpec change with `openspec validate macos-webui-migration --strict` once the change is wired in.

## 10. Out of Scope (Tracked Separately)

- [ ] 10.1 `macos-app/Sources/LauncherRootView.swift` revamp (gated behind UI design-mockup approval).
- [ ] 10.2 README and `index.html` copy refresh.
- [ ] 10.3 Removal of the §7.3 deprecated-snapshot-fields compatibility shim (lands in the UI follow-up commit).
- [ ] 10.4 Telemetry / data reporting (separate proposal `macos-launcher-telemetry`).
