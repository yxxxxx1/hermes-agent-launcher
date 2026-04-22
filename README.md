# Hermes Agent GUI Launcher

This workspace contains desktop launchers for [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent).

It wraps the current official installer scripts:

- Windows: `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1`
- macOS/Linux: `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh`

and exposes common actions through a GUI:

- install or update Hermes
- run the setup wizard
- launch the Hermes CLI
- run `hermes doctor`
- run `hermes update`
- open `config.yaml`, `.env`, and the logs folder

## Files

- `HermesGuiLauncher.ps1`: Windows WPF desktop launcher implemented in PowerShell
- `Start-HermesGuiLauncher.cmd`: Windows double-click entry point
- `HermesMacGuiLauncher.command`: macOS GUI launcher implemented with `osascript` + `Terminal`
- `index.html`: static download page that auto-detects Windows/macOS and recommends the matching installer
- `downloads/`: packaged ZIP downloads for Windows and macOS installers

## Run

Use either of these:

```powershell
powershell -ExecutionPolicy Bypass -File .\HermesGuiLauncher.ps1
```

or double-click:

```text
Start-HermesGuiLauncher.cmd
```

For macOS:

```bash
chmod +x ./HermesMacGuiLauncher.command
./HermesMacGuiLauncher.command
```

or double-click:

```text
HermesMacGuiLauncher.command
```

For the download page:

```text
index.html
```

## Validate

Run the Windows launcher's non-interactive self test:

```powershell
powershell -ExecutionPolicy Bypass -File .\HermesGuiLauncher.ps1 -SelfTest
```

The command prints compact JSON with the launcher version, default paths, resolved `hermes` and `uv` commands, and the current install/config status. It is safe to run while the GUI launcher is already open.

## WebUI

On Windows, the primary `开始对话` action is designed to open a local Hermes WebUI in the browser after Hermes and model configuration are ready. The command-line conversation path remains available from `更多设置` as `打开命令行对话`.

The launcher installs WebUI from an approved upstream snapshot:

- Source: `nesquena/hermes-webui`
- Version label: `v0.50.63`
- Commit: `a512f2020e01ef8c98989eb00c84a8d8cfc81ee1`
- Archive: `https://github.com/nesquena/hermes-webui/archive/a512f2020e01ef8c98989eb00c84a8d8cfc81ee1.zip`

Runtime paths:

- WebUI install: `%LOCALAPPDATA%\hermes\hermes-webui`
- WebUI staging: `%LOCALAPPDATA%\hermes\hermes-webui-staging`
- WebUI backup: `%LOCALAPPDATA%\hermes\hermes-webui-backup`
- WebUI state: `%USERPROFILE%\.hermes\webui`
- Launcher WebUI state: `%USERPROFILE%\.hermes\webui-launcher.json`
- Default workspace: `%USERPROFILE%\HermesWorkspace`
- WebUI logs: `%USERPROFILE%\.hermes\logs\webui`

The first version binds WebUI to `127.0.0.1` only. It does not expose WebUI on the LAN, configure a WebUI password, run Docker, or track upstream `master`. The update action reinstalls the launcher-approved stable WebUI commit bundled with this launcher version.

## Package

Current downloadable artifacts live in `downloads/`:

- `Hermes-Windows-Launcher.zip`: stable Windows download link used as the fallback link on `index.html`
- `Hermes-Windows-Launcher-v2026.04.22.1.zip`: versioned Windows download linked by `index.html`
- `Hermes-macOS-Launcher.tar.gz`: primary macOS download linked by `index.html`
- `Hermes-macOS-Launcher.zip`: alternate macOS archive

Before publishing a Windows launcher update:

1. Update `$script:LauncherVersion` in `HermesGuiLauncher.ps1`.
2. Run the `-SelfTest` command from the Validate section.
3. Create both the versioned Windows ZIP and the stable fallback ZIP:

```powershell
Compress-Archive -Path .\HermesGuiLauncher.ps1, .\Start-HermesGuiLauncher.cmd -DestinationPath .\downloads\Hermes-Windows-Launcher-vYYYY.MM.DD.N.zip -Force
Copy-Item .\downloads\Hermes-Windows-Launcher-vYYYY.MM.DD.N.zip .\downloads\Hermes-Windows-Launcher.zip -Force
```

4. Update `index.html` so the primary Windows link and displayed version match the new ZIP and `$script:LauncherVersion`.

Before publishing a macOS launcher update:

```bash
zip -j downloads/Hermes-macOS-Launcher.zip HermesMacGuiLauncher.command
tar -czf downloads/Hermes-macOS-Launcher.tar.gz HermesMacGuiLauncher.command
```

## Notes

- The Windows launcher currently uses these defaults:
  - `HERMES_HOME=%USERPROFILE%\.hermes`
  - `InstallDir=%LOCALAPPDATA%\hermes\hermes-agent`
- The macOS launcher follows the current official docs and installer defaults:
  - `HERMES_HOME=~/.hermes`
  - `InstallDir=~/.hermes/hermes-agent`
- The official README page currently still says native Windows is not supported and recommends WSL2.
- The current repository also ships `scripts/install.ps1`, so this launcher follows the repository's newer Windows installation flow instead of the older README note.
