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
- `macos-app/`: macOS Swift app wrapper used for the downloadable `.app`
- `HermesMacGuiLauncher.command`: macOS helper script used by the app bundle and for source-tree development
- `index.html`: static download page that auto-detects Windows/macOS and recommends the matching installer
- `downloads/`: packaged ZIP downloads for Windows and macOS installers

## Versions

- Windows launcher: `Windows v2026.04.14.2`
- macOS launcher: `macOS v2026.05.06.5`

## Run

Use either of these:

```powershell
powershell -ExecutionPolicy Bypass -File .\HermesGuiLauncher.ps1
```

or double-click:

```text
Start-HermesGuiLauncher.cmd
```

For macOS packaged downloads, unzip the archive and open:

```text
Hermes Launcher.app
```

For macOS source-tree development:

```bash
chmod +x ./HermesMacGuiLauncher.command
./HermesMacGuiLauncher.command
```

For the download page:

```text
index.html
```

## Notes

- The launcher uses the same default paths as the official Windows installer:
  - `HERMES_HOME=%LOCALAPPDATA%\hermes`
  - `InstallDir=%LOCALAPPDATA%\hermes\hermes-agent`
- The macOS launcher follows the current official docs and installer defaults:
  - `HERMES_HOME=~/.hermes`
  - `InstallDir=~/.hermes/hermes-agent`
- The official README page currently still says native Windows is not supported and recommends WSL2.
- The current repository also ships `scripts/install.ps1`, so this launcher follows the repository's newer Windows installation flow instead of the older README note.
