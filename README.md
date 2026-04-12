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

### macOS Gatekeeper 处理

首次双击 `.command` 文件时，macOS 可能会弹出「无法打开，因为无法验证开发者」的安全提示。有以下几种处理方式：

**方式一（推荐）：右键打开**
1. 在 Finder 中右键点击 `HermesMacGuiLauncher.command`
2. 选择「打开」
3. 在弹出的对话框中点击「打开」确认

**方式二：终端命令解除隔离**
```bash
xattr -d com.apple.quarantine /path/to/HermesMacGuiLauncher.command
```

**方式三：系统设置允许**
1. 双击运行后会弹出安全警告
2. 打开「系统设置」→「隐私与安全性」
3. 找到 HermesMacGuiLauncher 相关提示，点击「仍要打开」
