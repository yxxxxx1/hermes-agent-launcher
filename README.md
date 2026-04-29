# Hermes Agent 启动器

> 让每一个想用 AI Agent 的普通人,都不用去啃英文文档和命令行.

## 这是什么

[Hermes Agent](https://github.com/NousResearch/hermes-agent) 是一个很强的开源 AI Agent.但装它需要:打开终端,运行英文命令,配置环境,读文档.

这对开发者没问题.但对一个想用 AI 的普通人——**太难了**.

这个启动器把安装和配置的所有步骤,变成一个双击就能打开的图形界面.全中文.一路图形化.不会命令行也能用.

## 下载

**[hermes.aisuper.win](https://hermes.aisuper.win)** — 一键下载

- Windows(需先装 WSL2,启动器会帮你)
- macOS(直接双击打开)

## 做了哪些事让它更好用

- 🖱️ **全图形化**:模型配置,API Key,环境检测,都是点按钮
- 🇨🇳 **全中文**:界面,错误提示,引导,都是中文
- ✅ **自动校验**:填错的 API Key 当场就提示,不会等到对话时才发现
- 🔧 **内置引导**:不知道选哪个模型?界面里有建议

## 它不是什么

- **不是 Hermes Agent 官方产品**:我是 [@yxxxxx1](https://github.com/yxxxxx1),一个想让身边人也能用上 AI 的 PM
- **不代表官方支持**:遇到问题找我,别找 Nous Research
- **不保证完美**:百人用户群在共同踩坑和反馈中迭代

## 加入我们

- 问题反馈:[Issues](https://github.com/yxxxxx1/hermes-agent-launcher/issues)
- 交流群:[群链接占位,PM 稍后填入]

遵循 MIT 协议开源.

---

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
- `Hermes-Windows-Launcher-v2026.04.29.1.zip`: versioned Windows download linked by `index.html`
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
