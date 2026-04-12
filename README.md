# Hermes Agent Launcher

This repository contains two launcher variants for [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent):

- Windows desktop console: full Chinese GUI launcher built with PowerShell + WPF
- macOS lightweight launcher: utility-style launcher built with `osascript` + `Terminal`

## Included Files

- `HermesGuiLauncher.ps1`: Windows launcher source
- `Start-HermesGuiLauncher.cmd`: Windows double-click entry
- `HermesMacGuiLauncher.command`: macOS launcher source
- `index.html`: static download page
- `downloads/Hermes-Windows-Launcher.zip`: packaged Windows launcher
- `downloads/Hermes-macOS-Launcher.tar.gz`: packaged macOS launcher

## Product Positioning

### Windows

Windows uses a full desktop control panel with guided flow, status area, maintenance tools, and packaged downloads.

### macOS

macOS uses a lightweight utility launcher. It does not try to replicate the Windows step-by-step control panel. Installation runs the official `install.sh`, and the launcher mainly provides quick access to:

- install/update
- model configuration
- local chat
- messaging setup
- gateway launch
- maintenance and file shortcuts

## Official Installers

- Windows: `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1`
- macOS/Linux: `https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh`

## Notes

- Windows package is distributed as `.zip`
- macOS package is distributed as `.tar.gz` to preserve executable permission on `HermesMacGuiLauncher.command`
- macOS users may still need to allow the launcher in System Settings → Privacy & Security on first run
