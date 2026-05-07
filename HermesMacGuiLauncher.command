#!/bin/bash

set -euo pipefail

APP_TITLE="Hermes Agent macOS 轻量启动器"
LAUNCHER_VERSION="macOS v2026.05.07.1"
OFFICIAL_INSTALL_URL="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
OFFICIAL_REPO_URL="https://github.com/NousResearch/hermes-agent"
OFFICIAL_DOCS_URL="https://hermes-agent.nousresearch.com/docs/getting-started/installation/"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_PATH="$SELF_DIR/$(basename "$0")"

DEFAULT_HERMES_HOME="$HOME/.hermes"
DEFAULT_INSTALL_DIR="$DEFAULT_HERMES_HOME/hermes-agent"

HERMES_HOME="${HERMES_HOME:-$DEFAULT_HERMES_HOME}"
INSTALL_DIR="${HERMES_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"

# Hermes Agent install branch (used by launch_install for the official installer + manual fallback).
BRANCH="main"

# Track D: pin hermes-agent to a known-good commit. "HEAD" means follow the branch (no checkout).
# Bump this string after smoke-testing each upgrade. The "检查更新" footer entry shows newer commits.
HERMES_AGENT_PINNED_COMMIT="HEAD"

# Track A: messaging-platform → pip-package mapping.
# Each row is "ENV_VAR_KEY:python_module:pip_packages_space_separated".
# `WEIXIN_*` and `WECOM_*` rows have an empty pip-package field — they are zero-dep (D3) and only
# verify env-var presence. Empty pip field === skip the install step.
GATEWAY_PLATFORM_MAP=(
    "TELEGRAM_BOT_TOKEN:telegram:python-telegram-bot[webhooks]"
    "FEISHU_APP_ID:lark_oapi:lark-oapi"
    "DISCORD_BOT_TOKEN:discord:discord.py[voice]"
    "SLACK_BOT_TOKEN:slack_bolt:slack-bolt slack-sdk"
    "DINGTALK_CLIENT_ID:dingtalk_stream:dingtalk-stream alibabacloud-dingtalk"
    "WEIXIN_ACCOUNT_ID::"
    "WEIXIN_TOKEN::"
    "WECOM_BOT_ID::"
)

# Friendly Chinese names for STAGE events / UI fallback when only the env-var key is known.
GATEWAY_PLATFORM_LABELS=(
    "TELEGRAM_BOT_TOKEN:Telegram"
    "FEISHU_APP_ID:飞书"
    "DISCORD_BOT_TOKEN:Discord"
    "SLACK_BOT_TOKEN:Slack"
    "DINGTALK_CLIENT_ID:钉钉"
    "WEIXIN_ACCOUNT_ID:微信"
    "WEIXIN_TOKEN:微信"
    "WECOM_BOT_ID:企业微信"
)

# --- Node.js runtime (M1, M2) ---
NODE_REQUIRED_MAJOR=23
NODE_PORTABLE_VERSION="v23.11.0"
NODE_DIST_BASE="https://nodejs.org/dist/${NODE_PORTABLE_VERSION}"
LAUNCHER_RUNTIME_DIR="$HERMES_HOME/launcher-runtime"
NODE_INSTALL_DIR="$LAUNCHER_RUNTIME_DIR/node"
NPM_PREFIX="$LAUNCHER_RUNTIME_DIR/npm-prefix"
RUNTIME_CACHE_DIR="$LAUNCHER_RUNTIME_DIR/cache"
RUNTIME_INSTALL_LOG="$LAUNCHER_RUNTIME_DIR/install.log"
# From https://nodejs.org/dist/v23.11.0/SHASUMS256.txt
NODE_SHA256_DARWIN_ARM64="635990b46610238e3c008cd01480c296e0c2bfe7ec59ea9a8cd789d5ac621bb0"
NODE_SHA256_DARWIN_X64="a5782655748d4602c1ee1ee62732e0a16d29d3e4faac844db395b0fbb1c9dab8"

# --- Hermes WebUI npm package (M3, M4, M5) ---
WEBUI_NPM_PACKAGE="hermes-web-ui"
WEBUI_NPM_VERSION="0.5.9"
WEBUI_HOST="${HERMES_WEBUI_HOST:-127.0.0.1}"
WEBUI_PORT="${HERMES_WEBUI_PORT:-8648}"
WEBUI_URL="http://localhost:$WEBUI_PORT"
WEBUI_HEALTH_URL="http://$WEBUI_HOST:$WEBUI_PORT/health"
WEBUI_BIN="$NPM_PREFIX/bin/hermes-web-ui"
WEBUI_HOME_DIR="$HOME/.hermes-web-ui"
WEBUI_TOKEN_FILE="$WEBUI_HOME_DIR/.token"
WEBUI_PID_FILE="$WEBUI_HOME_DIR/server.pid"
WEBUI_SERVER_LOG="$WEBUI_HOME_DIR/server.log"

# Resolved at runtime by detect_node_runtime / download_portable_node / select_npm_registry.
NODE_BIN=""
NPM_BIN=""
NODE_RUNTIME_KIND="missing"
NODE_RUNTIME_VERSION=""
NPM_REGISTRY=""

LAUNCHER_LOG_DIR="$HERMES_HOME/logs/launcher"
LAUNCHER_STATE_FILE="$LAUNCHER_LOG_DIR/state.env"
LAST_ACTION_SUMMARY="启动器已就绪"
LAST_STAGE="none"
LAST_RESULT="idle"
LAST_LOG_PATH=""

show_message() {
    local message="$1"
    /usr/bin/osascript - "$message" "$APP_TITLE" <<'OSA'
on run argv
    display dialog (item 1 of argv) with title (item 2 of argv) buttons {"确定"} default button "确定"
end run
OSA
}

show_warning() {
    local message="$1"
    /usr/bin/osascript - "$message" "$APP_TITLE" <<'OSA'
on run argv
    display dialog (item 1 of argv) with title (item 2 of argv) buttons {"确定"} default button "确定" with icon caution
end run
OSA
}

prompt_failure_action() {
    local prompt="$1"
    local default_item="${2:-重新尝试}"
    choose_from_list "$prompt" "$default_item" \
        "重新尝试" \
        "打开日志" \
        "返回首页"
}

prompt_webui_failure_action() {
    local prompt="$1"
    choose_from_list "$prompt" "改用终端对话" \
        "改用终端对话" \
        "重新尝试" \
        "打开日志" \
        "返回首页"
}

prompt_text() {
    local prompt="$1"
    local default_value="$2"
    /usr/bin/osascript - "$prompt" "$default_value" "$APP_TITLE" <<'OSA'
on run argv
    set resultRecord to display dialog (item 1 of argv) default answer (item 2 of argv) with title (item 3 of argv) buttons {"取消", "确定"} default button "确定" cancel button "取消"
    return text returned of resultRecord
end run
OSA
}

prompt_yes_no() {
    local prompt="$1"
    local default_button="${2:-是}"
    /usr/bin/osascript - "$prompt" "$default_button" "$APP_TITLE" <<'OSA'
on run argv
    set resultRecord to display dialog (item 1 of argv) with title (item 3 of argv) buttons {"否", "是"} default button (item 2 of argv) cancel button "否"
    return button returned of resultRecord
end run
OSA
}

prompt_uninstall_mode() {
    local prompt="$1"
    /usr/bin/osascript - "$prompt" "$APP_TITLE" <<'OSA'
on run argv
    set resultRecord to display dialog (item 1 of argv) with title (item 2 of argv) buttons {"取消", "标准卸载", "彻底卸载"} default button "标准卸载" cancel button "取消" with icon caution
    return button returned of resultRecord
end run
OSA
}

choose_from_list() {
    local prompt="$1"
    local default_item="$2"
    shift 2
    local items_text
    items_text="$(printf '%s\n' "$@")"
    /usr/bin/osascript - "$prompt" "$APP_TITLE" "$default_item" "$items_text" <<'OSA'
on run argv
    set AppleScript's text item delimiters to linefeed
    set options to paragraphs of (item 4 of argv)
    set picked to choose from list options with title (item 2 of argv) with prompt (item 1 of argv) default items {(item 3 of argv)} OK button name "确定" cancel button name "退出" without multiple selections allowed and empty selection allowed
    if picked is false then
        return "__CANCEL__"
    end if
    return item 1 of picked
end run
OSA
}

quoted_line() {
    printf "%q" "$1"
}

slugify_label() {
    case "$1" in
        install|"安装"|"安装或更新") printf 'install\n' ;;
        model|"模型配置") printf 'model\n' ;;
        chat|"本地对话") printf 'chat\n' ;;
        chat-terminal|"终端对话") printf 'chat-terminal\n' ;;
        doctor) printf 'doctor\n' ;;
        update) printf 'update\n' ;;
        tools) printf 'tools\n' ;;
        setup|"完整 setup") printf 'setup\n' ;;
        gateway|"消息网关") printf 'gateway\n' ;;
        gateway-setup|"消息渠道配置") printf 'gateway-setup\n' ;;
        uninstall|"卸载") printf 'uninstall\n' ;;
        *) printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^-//; s/-$//' ;;
    esac
}

write_temp_command_script() {
    local payload="$1"
    local title="$2"
    local log_path="${3:-}"
    local capture_output="${4:-true}"
    local script_path
    script_path="/tmp/hermes-launcher-$(date '+%Y%m%d-%H%M%S')-$RANDOM.command"
    cat >"$script_path" <<EOF
#!/bin/bash
export HERMES_HOME=$(quoted_line "$HERMES_HOME")
export HERMES_INSTALL_DIR=$(quoted_line "$INSTALL_DIR")
export PATH=$(quoted_line "$HOME/.local/bin:$PATH")
export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1
export HERMES_LAUNCHER_PLAIN_UI=1
export HERMES_LAUNCHER_WINDOW_TITLE=$(quoted_line "$title")
# Launcher sessions run inside Terminal.app; override inherited non-interactive
# values from the parent shell so curses/prompt_toolkit UIs render correctly.
if [[ -z "\${TERM:-}" || "\${TERM:-}" == "dumb" ]]; then
export TERM=xterm-256color
fi
export COLORTERM=truecolor
unset NO_COLOR
close_terminal_window_by_title() {
local target_title="\${1:-\$HERMES_LAUNCHER_WINDOW_TITLE}"
/usr/bin/osascript - "\$target_title" <<'OSA'
on run argv
    set targetTitle to item 1 of argv
    tell application "Terminal"
        repeat with w in windows
            try
                if name of w contains targetTitle then
                    close w saving no
                    exit repeat
                end if
            end try
        end repeat
    end tell
end run
OSA
}
printf '\033]0;%s\007' $(printf '%q' "$title")
$( [[ -n "$log_path" && "$capture_output" == "true" ]] && printf 'exec > >(tee -a %s) 2>&1\n' "$(quoted_line "$log_path")" )
$payload
EOF
    chmod +x "$script_path"
    printf '%s\n' "$script_path"
}

ensure_launcher_dirs() {
    mkdir -p "$HERMES_HOME" "$LAUNCHER_LOG_DIR"
}

load_session_state() {
    if [[ -f "$LAUNCHER_STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$LAUNCHER_STATE_FILE"
    fi
    LAST_STAGE="${LAST_STAGE:-none}"
    LAST_RESULT="${LAST_RESULT:-idle}"
    LAST_LOG_PATH="${LAST_LOG_PATH:-}"
    if [[ "$LAST_RESULT" != "idle" && ( -z "$LAST_LOG_PATH" || ! -f "$LAST_LOG_PATH" ) ]]; then
        LAST_STAGE="none"
        LAST_RESULT="idle"
        LAST_LOG_PATH=""
    fi
}

save_session_state() {
    ensure_launcher_dirs
    cat >"$LAUNCHER_STATE_FILE" <<EOF
LAST_STAGE=$(quoted_line "$LAST_STAGE")
LAST_RESULT=$(quoted_line "$LAST_RESULT")
LAST_LOG_PATH=$(quoted_line "$LAST_LOG_PATH")
EOF
}

set_stage_state() {
    LAST_STAGE="$1"
    LAST_RESULT="$2"
    LAST_LOG_PATH="${3:-$LAST_LOG_PATH}"
    save_session_state
}

timestamp_now() {
    date '+%Y-%m-%d %H:%M:%S'
}

set_last_action() {
    LAST_ACTION_SUMMARY="[$(timestamp_now)] $1"
}

build_log_path() {
    local slug="$1"
    ensure_launcher_dirs
    printf '%s/%s-%s.log\n' "$LAUNCHER_LOG_DIR" "$(date '+%Y%m%d-%H%M%S')" "$(slugify_label "$slug")"
}

state_get() {
    local key="$1"
    local state_blob="$2"
    printf '%s\n' "$state_blob" | awk -F= -v k="$key" '$1 == k { print substr($0, length($1) + 2); exit }'
}

html_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    value="${value//\'/&#39;}"
    printf '%s' "$value"
}

ui_primary_copy() {
    local state="$1"
    local installed
    installed="$(state_get installed "$state")"

    if [[ "$installed" != "true" ]]; then
        printf '继续安装\n'
    else
        printf '启动浏览器对话\n'
    fi
}

next_primary_key() {
    local state="$1"
    local installed
    installed="$(state_get installed "$state")"

    if [[ "$installed" != "true" ]]; then
        printf 'install\n'
    else
        printf 'chat\n'
    fi
}

ui_status_class() {
    case "$1" in
        "已完成"|"已在运行") printf 'complete\n' ;;
        "进行中"|"待完成"|"可以启动"|"待安装") printf 'active\n' ;;
        *) printf 'muted\n' ;;
    esac
}

write_native_ui_html() {
    local state="$1"
    local primary_key="$2"
    local html_path="$3"
    local installed webui_installed webui_running webui_url node_runtime_kind webui_version
    local install_line launch_line current_step primary_copy
    local install_class launch_class

    installed="$(state_get installed "$state")"
    webui_installed="$(state_get webui_installed "$state")"
    webui_running="$(state_get webui_running "$state")"
    webui_url="$(state_get webui_url "$state")"
    node_runtime_kind="$(state_get node_runtime_kind "$state")"
    webui_version="$(state_get webui_version "$state")"
    [[ -z "$webui_url" ]] && webui_url="$WEBUI_URL"

    install_line="未开始"
    launch_line="尚不可用"
    current_step="继续安装"
    primary_copy="$(ui_primary_copy "$state")"

    if [[ "$LAST_STAGE" == "install" && "$LAST_RESULT" == "running" ]]; then
        install_line="进行中"
    elif [[ "$installed" == "true" ]]; then
        install_line="已完成"
    fi

    if [[ "$installed" == "true" ]]; then
        if [[ "$webui_running" == "true" ]]; then
            launch_line="已在运行"
            current_step="打开浏览器对话"
        elif [[ "$webui_installed" == "true" ]]; then
            launch_line="可以启动"
            current_step="启动浏览器对话"
        else
            launch_line="待安装"
            current_step="启动浏览器对话"
        fi
    fi

    if [[ "$LAST_STAGE" == "chat" && "$LAST_RESULT" == "running" ]]; then
        launch_line="进行中"
    fi

    install_class="$(ui_status_class "$install_line")"
    launch_class="$(ui_status_class "$launch_line")"

    local runtime_label="未检测"
    case "$node_runtime_kind" in
        system) runtime_label="系统 Node" ;;
        portable) runtime_label="便携 Node" ;;
        missing) runtime_label="未检测" ;;
        *) runtime_label="${node_runtime_kind:-未检测}" ;;
    esac
    local webui_version_label="${webui_version:-未安装}"

    cat >"$html_path" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Hermes Agent for macOS</title>
  <style>
    :root {
      --bg0: #f6f2e9;
      --bg1: #fbf8f2;
      --panel: rgba(255, 251, 245, 0.78);
      --panel-strong: rgba(255, 252, 247, 0.92);
      --line: rgba(87, 63, 28, 0.14);
      --line-strong: rgba(87, 63, 28, 0.24);
      --ink: #1f1b16;
      --muted: #6d655b;
      --accent: #b88338;
      --accent-strong: #8c6328;
      --accent-ink: #2b2112;
      --ok: #1d7f72;
      --warn: #b57b2b;
      --shadow: 0 30px 80px rgba(58, 39, 11, 0.14);
      --radius-xl: 28px;
      --radius-lg: 22px;
      --radius-md: 16px;
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; height: 100%; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "PingFang SC", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top left, rgba(255,255,255,0.75), transparent 36%),
        radial-gradient(circle at bottom right, rgba(221, 187, 133, 0.18), transparent 30%),
        linear-gradient(160deg, var(--bg0), var(--bg1));
      -webkit-font-smoothing: antialiased;
      text-rendering: optimizeLegibility;
    }
    .app {
      min-height: 100%;
      padding: 28px;
      display: grid;
      grid-template-rows: auto auto 1fr;
      gap: 18px;
    }
    .surface {
      background: var(--panel);
      border: 1px solid var(--line);
      box-shadow: var(--shadow);
      backdrop-filter: blur(24px);
      border-radius: var(--radius-xl);
    }
    .hero {
      padding: 28px;
      display: grid;
      grid-template-columns: 1.35fr 0.9fr;
      gap: 18px;
      align-items: stretch;
    }
    .eyebrow {
      display: inline-flex;
      align-items: center;
      gap: 10px;
      padding: 8px 12px;
      border-radius: 999px;
      background: rgba(255,255,255,0.7);
      border: 1px solid var(--line);
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }
    .eyebrow::before {
      content: "";
      width: 8px;
      height: 8px;
      border-radius: 999px;
      background: var(--accent);
      box-shadow: 0 0 0 6px rgba(184,131,56,0.14);
    }
    h1 {
      margin: 16px 0 10px;
      font-size: 42px;
      line-height: 1.02;
      letter-spacing: -0.05em;
    }
    .summary {
      margin: 0;
      max-width: 42ch;
      color: var(--muted);
      font-size: 15px;
      line-height: 1.75;
    }
    .hero-side {
      display: grid;
      gap: 12px;
      align-content: start;
    }
    .stat {
      padding: 18px 18px 16px;
      border-radius: var(--radius-lg);
      background: var(--panel-strong);
      border: 1px solid var(--line);
    }
    .stat-label {
      margin: 0 0 8px;
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }
    .stat-value {
      margin: 0;
      font-size: 27px;
      line-height: 1.15;
      letter-spacing: -0.04em;
    }
    .hero-actions {
      display: flex;
      gap: 12px;
      margin-top: 22px;
      flex-wrap: wrap;
    }
    button {
      appearance: none;
      border: 0;
      cursor: pointer;
      font: inherit;
    }
    .btn {
      min-height: 52px;
      padding: 0 18px;
      border-radius: 16px;
      transition: transform 180ms ease, box-shadow 180ms ease, background 180ms ease;
    }
    .btn:hover { transform: translateY(-1px); }
    .btn:active { transform: translateY(0); }
    .btn.primary {
      background: linear-gradient(180deg, #c79242, var(--accent-strong));
      color: #fff8ec;
      box-shadow: 0 14px 36px rgba(140, 99, 40, 0.26);
      font-weight: 700;
    }
    .btn.secondary {
      background: rgba(255,255,255,0.72);
      color: var(--ink);
      border: 1px solid var(--line-strong);
      font-weight: 600;
    }
    .dashboard {
      padding: 22px;
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 14px;
    }
    .stage {
      padding: 18px;
      border-radius: var(--radius-lg);
      background: var(--panel-strong);
      border: 1px solid var(--line);
      display: grid;
      gap: 12px;
    }
    .stage-top {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
    }
    .stage-index {
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }
    .pill {
      padding: 6px 10px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.02em;
    }
    .pill.complete { background: rgba(29,127,114,0.12); color: var(--ok); }
    .pill.active { background: rgba(184,131,56,0.14); color: var(--accent-strong); }
    .pill.muted { background: rgba(78, 63, 43, 0.08); color: var(--muted); }
    .stage h2 {
      margin: 0;
      font-size: 20px;
      letter-spacing: -0.04em;
    }
    .stage p {
      margin: 0;
      color: var(--muted);
      font-size: 14px;
      line-height: 1.65;
    }
    .meta-grid {
      display: grid;
      grid-template-columns: 1.2fr 0.8fr;
      gap: 18px;
      align-items: start;
    }
    .panel {
      padding: 22px;
    }
    .panel h3 {
      margin: 0 0 14px;
      font-size: 18px;
      letter-spacing: -0.03em;
    }
    .list {
      display: grid;
      gap: 10px;
    }
    .row {
      display: grid;
      gap: 4px;
      padding: 14px 16px;
      border-radius: 16px;
      background: rgba(255,255,255,0.68);
      border: 1px solid rgba(87, 63, 28, 0.08);
    }
    .row-label {
      font-size: 12px;
      font-weight: 700;
      color: var(--muted);
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }
    .row-value {
      font-size: 14px;
      line-height: 1.55;
      word-break: break-word;
    }
    .maintenance {
      display: grid;
      gap: 12px;
    }
    .maintenance-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 10px;
    }
    .maintenance button {
      min-height: 46px;
      padding: 0 14px;
      border-radius: 14px;
      text-align: left;
      background: rgba(255,255,255,0.72);
      color: var(--ink);
      border: 1px solid rgba(87, 63, 28, 0.1);
      font-weight: 600;
    }
    .fineprint {
      color: var(--muted);
      font-size: 13px;
      line-height: 1.65;
    }
    @media (max-width: 900px) {
      .hero, .meta-grid, .dashboard { grid-template-columns: 1fr; }
      .app { padding: 18px; }
      h1 { font-size: 34px; }
    }
  </style>
</head>
<body>
  <main class="app">
    <section class="hero surface">
      <div>
        <div class="eyebrow">Hermes macOS Guided Utility</div>
        <h1>现在只做当前这一步，其他都先不用管。</h1>
        <p class="summary">这个启动器会先帮你走完安装、模型配置和第一次对话。维护工具依然保留，但不会打断首次使用。</p>
        <div class="hero-actions">
          <button class="btn primary" data-action="$(html_escape "$primary_key")">$(html_escape "$primary_copy")</button>
          <button class="btn secondary" data-action="refresh">刷新状态</button>
        </div>
      </div>
      <div class="hero-side">
        <article class="stat">
          <p class="stat-label">当前步骤</p>
          <p class="stat-value">$(html_escape "$current_step")</p>
        </article>
        <article class="stat">
          <p class="stat-label">版本</p>
          <p class="stat-value">$(html_escape "$LAUNCHER_VERSION")</p>
        </article>
      </div>
    </section>

    <section class="dashboard surface">
      <article class="stage">
        <div class="stage-top">
          <span class="stage-index">Stage 01</span>
          <span class="pill $install_class">$(html_escape "$install_line")</span>
        </div>
        <h2>安装 Hermes</h2>
        <p>把运行环境和命令入口准备好。完成后，启动器会自动准备浏览器对话。</p>
      </article>
      <article class="stage">
        <div class="stage-top">
          <span class="stage-index">Stage 02</span>
          <span class="pill $launch_class">$(html_escape "$launch_line")</span>
        </div>
        <h2>启动浏览器对话</h2>
        <p>打开 Hermes WebUI。模型与渠道配置都在浏览器里完成，启动器只负责把它拉起来。</p>
      </article>
    </section>

    <section class="meta-grid">
      <section class="panel surface">
        <h3>当前状态</h3>
        <div class="list">
          <div class="row">
            <div class="row-label">浏览器对话</div>
            <div class="row-value">$(html_escape "$webui_url")</div>
          </div>
          <div class="row">
            <div class="row-label">Node 运行时</div>
            <div class="row-value">$(html_escape "$runtime_label")</div>
          </div>
          <div class="row">
            <div class="row-label">WebUI 版本</div>
            <div class="row-value">$(html_escape "$webui_version_label")</div>
          </div>
          <div class="row">
            <div class="row-label">数据目录</div>
            <div class="row-value">$(html_escape "$HERMES_HOME")</div>
          </div>
          <div class="row">
            <div class="row-label">最近操作</div>
            <div class="row-value">$(html_escape "$LAST_ACTION_SUMMARY")</div>
          </div>
        </div>
      </section>

      <section class="panel surface maintenance">
        <div>
          <h3>维护与高级选项</h3>
          <p class="fineprint">这些动作留给维护与排查。首次使用时一般不需要先进入这里；模型与渠道配置都在浏览器对话里完成。</p>
        </div>
        <div class="maintenance-grid">
          <button data-action="doctor">诊断问题</button>
          <button data-action="update">更新 Hermes</button>
          <button data-action="setup">重新执行完整设置</button>
          <button data-action="tools">配置 tools</button>
          <button data-action="stop_webui">停止浏览器对话</button>
          <button data-action="restart_webui">重启浏览器对话</button>
          <button data-action="open_config">打开 config.yaml</button>
          <button data-action="open_env">打开 .env</button>
          <button data-action="open_logs">打开日志目录</button>
          <button data-action="open_home">打开数据目录</button>
          <button data-action="open_install">打开安装目录</button>
          <button data-action="docs">官方文档</button>
          <button data-action="repo">官方仓库</button>
          <button data-action="uninstall">卸载 Hermes</button>
        </div>
      </section>
    </section>
  </main>
  <script>
    const postAction = (action) => {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.hermes) {
        window.webkit.messageHandlers.hermes.postMessage({ action });
      }
    };
    document.querySelectorAll("[data-action]").forEach((node) => {
      node.addEventListener("click", () => postAction(node.dataset.action));
    });
  </script>
</body>
</html>
EOF
}

launch_native_ui() {
    local state="$1"
    local primary_key="$2"
    local html_path jxa_path
    html_path="/tmp/hermes-launcher-ui-$(date '+%Y%m%d-%H%M%S')-$RANDOM.html"
    jxa_path="/tmp/hermes-launcher-ui-$(date '+%Y%m%d-%H%M%S')-$RANDOM.js"
    write_native_ui_html "$state" "$primary_key" "$html_path"
    cat >"$jxa_path" <<'EOF'
ObjC.import('Cocoa');
ObjC.import('WebKit');

const htmlPath = ObjC.unwrap($.NSString.stringWithUTF8String($.getenv('HERMES_UI_HTML')));
const launcherPath = ObjC.unwrap($.NSString.stringWithUTF8String($.getenv('HERMES_UI_LAUNCHER')));

function launchAction(action) {
  const task = $.NSTask.alloc.init;
  task.setLaunchPath('/bin/bash');
  task.setArguments($([launcherPath, '--dispatch-action', action]));
  task.launch();
}

ObjC.registerSubclass({
  name: 'HermesLauncherMessageHandler',
  protocols: ['WKScriptMessageHandler', 'NSWindowDelegate'],
  methods: {
    'userContentController:didReceiveScriptMessage:': {
      types: ['void', ['id', 'id']],
      implementation: function(_controller, message) {
        const body = ObjC.deepUnwrap(message.body);
        const action = (body && body.action) ? String(body.action) : '';
        if (!action) {
          return;
        }
        launchAction(action);
        $.NSApp.terminate(null);
      }
    },
    'windowWillClose:': {
      types: ['void', ['id']],
      implementation: function() {
        $.NSApp.terminate(null);
      }
    }
  }
});

const app = $.NSApplication.sharedApplication;
app.setActivationPolicy($.NSApplicationActivationPolicyRegular);

const config = $.WKWebViewConfiguration.alloc.init;
const controller = $.WKUserContentController.alloc.init;
const handler = $.HermesLauncherMessageHandler.alloc.init;
controller.addScriptMessageHandlerName(handler, 'hermes');
config.setUserContentController(controller);

const frame = $.NSMakeRect(0, 0, 1120, 820);
const mask = $.NSWindowStyleMaskTitled | $.NSWindowStyleMaskClosable | $.NSWindowStyleMaskMiniaturizable | $.NSWindowStyleMaskResizable;
const window = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(frame, mask, $.NSBackingStoreBuffered, false);
window.setTitle('Hermes Agent for macOS');
window.center();
window.setDelegate(handler);
window.setReleasedWhenClosed(false);

const webView = $.WKWebView.alloc.initWithFrameConfiguration(frame, config);
webView.setAutoresizingMask($.NSViewWidthSizable | $.NSViewHeightSizable);
window.setContentView(webView);

const fileURL = $.NSURL.fileURLWithPath(htmlPath);
webView.loadFileURLAllowingReadAccessToURL(fileURL, fileURL.URLByDeletingLastPathComponent);

window.makeKeyAndOrderFront(null);
app.activateIgnoringOtherApps(true);
app.run();
EOF
    chmod +x "$jxa_path"
    HERMES_UI_HTML="$html_path" HERMES_UI_LAUNCHER="$SELF_PATH" /usr/bin/osascript -l JavaScript "$jxa_path"
}

resolve_hermes_command() {
    local candidates=(
        "$INSTALL_DIR/venv/bin/hermes"
        "$HOME/.local/bin/hermes"
    )
    local candidate=""
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    if command -v hermes >/dev/null 2>&1; then
        command -v hermes
        return 0
    fi

    return 1
}

ensure_config_scaffold() {
    mkdir -p \
        "$HERMES_HOME/cron" \
        "$HERMES_HOME/sessions" \
        "$HERMES_HOME/logs" \
        "$HERMES_HOME/pairing" \
        "$HERMES_HOME/hooks" \
        "$HERMES_HOME/image_cache" \
        "$HERMES_HOME/audio_cache" \
        "$HERMES_HOME/memories" \
        "$HERMES_HOME/skills" \
        "$HERMES_HOME/whatsapp/session"

    if [[ ! -f "$HERMES_HOME/.env" ]]; then
        if [[ -f "$INSTALL_DIR/.env.example" ]]; then
            cp "$INSTALL_DIR/.env.example" "$HERMES_HOME/.env"
        else
            : >"$HERMES_HOME/.env"
        fi
    fi

    if [[ ! -f "$HERMES_HOME/config.yaml" ]]; then
        if [[ -f "$INSTALL_DIR/cli-config.yaml.example" ]]; then
            cp "$INSTALL_DIR/cli-config.yaml.example" "$HERMES_HOME/config.yaml"
        else
            : >"$HERMES_HOME/config.yaml"
        fi
    fi
}

is_installed() {
    [[ -n "${1:-}" ]]
}

emit_stage() {
    # STAGE:<phase> STATUS=<s> [DETAIL=...] [PROGRESS=N] [URL=...] [REASON=...]
    local phase="$1"
    local status="$2"
    shift 2
    local extras=""
    local kv=""
    for kv in "$@"; do
        [[ -z "$kv" ]] && continue
        extras+=" $kv"
    done
    printf 'STAGE:%s STATUS=%s%s\n' "$phase" "$status" "$extras"
}

# --- Node.js runtime detection (M1) ---
detect_node_runtime() {
    NODE_BIN=""
    NPM_BIN=""
    NODE_RUNTIME_KIND="missing"
    NODE_RUNTIME_VERSION=""

    local sys_node=""
    sys_node="$(command -v node 2>/dev/null || true)"
    if [[ -z "$sys_node" || ! -x "$sys_node" ]]; then
        return 1
    fi

    local version_string=""
    version_string="$("$sys_node" -v 2>/dev/null || true)"
    if [[ -z "$version_string" ]]; then
        return 1
    fi

    local major="${version_string#v}"
    major="${major%%.*}"
    if ! [[ "$major" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if (( major < NODE_REQUIRED_MAJOR )); then
        return 1
    fi

    local node_dir
    node_dir="$(dirname "$sys_node")"
    local sys_npm="$node_dir/npm"
    if [[ ! -x "$sys_npm" ]]; then
        sys_npm="$(command -v npm 2>/dev/null || true)"
        if [[ -z "$sys_npm" || ! -x "$sys_npm" ]]; then
            return 1
        fi
        if [[ "$(dirname "$sys_npm")" != "$node_dir" ]]; then
            return 1
        fi
    fi

    NODE_BIN="$sys_node"
    NPM_BIN="$sys_npm"
    NODE_RUNTIME_KIND="system"
    NODE_RUNTIME_VERSION="$version_string"
    return 0
}

# --- Node.js portable download (M2) ---
download_portable_node() {
    local arch_tag=""
    local expected_sha=""
    case "$(uname -m)" in
        arm64)
            arch_tag="darwin-arm64"
            expected_sha="$NODE_SHA256_DARWIN_ARM64"
            ;;
        x86_64)
            arch_tag="darwin-x64"
            expected_sha="$NODE_SHA256_DARWIN_X64"
            ;;
        *)
            emit_stage download_node failed "REASON=unsupported_arch_$(uname -m)"
            return 1
            ;;
    esac

    local tarball="node-${NODE_PORTABLE_VERSION}-${arch_tag}.tar.gz"
    local url="${NODE_DIST_BASE}/${tarball}"
    local cache_path="$RUNTIME_CACHE_DIR/$tarball"
    local extract_root="$NODE_INSTALL_DIR/${NODE_PORTABLE_VERSION}-${arch_tag}"

    mkdir -p "$RUNTIME_CACHE_DIR" "$NODE_INSTALL_DIR"

    if [[ -x "$extract_root/bin/node" && -x "$extract_root/bin/npm" ]]; then
        NODE_BIN="$extract_root/bin/node"
        NPM_BIN="$extract_root/bin/npm"
        NODE_RUNTIME_KIND="portable"
        NODE_RUNTIME_VERSION="$NODE_PORTABLE_VERSION"
        emit_stage download_node ok "DETAIL=cached_${arch_tag}"
        return 0
    fi

    emit_stage download_node running "DETAIL=$arch_tag"
    if ! curl -fL --retry 3 --retry-delay 2 --max-time 600 -o "$cache_path" "$url" >>"$RUNTIME_INSTALL_LOG" 2>&1; then
        local curl_exit=$?
        rm -f "$cache_path"
        emit_stage download_node failed "REASON=curl_${curl_exit}"
        return 1
    fi

    if [[ "$expected_sha" == TODO_SHA256_PLACEHOLDER* ]]; then
        echo "[$(timestamp_now)] WARNING: SHA256 verification skipped (placeholder constant). Tarball: $tarball" >>"$RUNTIME_INSTALL_LOG"
    else
        local got_sha=""
        got_sha="$(shasum -a 256 "$cache_path" 2>/dev/null | awk '{print $1}')"
        if [[ "$got_sha" != "$expected_sha" ]]; then
            rm -f "$cache_path"
            emit_stage download_node failed "REASON=sha256_mismatch"
            return 1
        fi
    fi
    emit_stage download_node ok "DETAIL=$arch_tag"

    emit_stage extract_node running
    rm -rf "$extract_root.partial"
    mkdir -p "$extract_root.partial"
    if ! tar -xzf "$cache_path" -C "$extract_root.partial" --strip-components=1 >>"$RUNTIME_INSTALL_LOG" 2>&1; then
        local tar_exit=$?
        rm -rf "$extract_root.partial"
        emit_stage extract_node failed "REASON=tar_${tar_exit}"
        return 1
    fi

    rm -rf "$extract_root"
    mv "$extract_root.partial" "$extract_root"

    if command -v xattr >/dev/null 2>&1; then
        xattr -dr com.apple.quarantine "$extract_root" >/dev/null 2>&1 || true
    fi

    if [[ ! -x "$extract_root/bin/node" || ! -x "$extract_root/bin/npm" ]]; then
        emit_stage extract_node failed "REASON=missing_binaries"
        return 1
    fi

    NODE_BIN="$extract_root/bin/node"
    NPM_BIN="$extract_root/bin/npm"
    NODE_RUNTIME_KIND="portable"
    NODE_RUNTIME_VERSION="$NODE_PORTABLE_VERSION"
    emit_stage extract_node ok "DETAIL=$arch_tag"
    return 0
}

ensure_node_runtime() {
    mkdir -p "$LAUNCHER_RUNTIME_DIR" "$RUNTIME_CACHE_DIR" "$NODE_INSTALL_DIR"
    : >>"$RUNTIME_INSTALL_LOG"

    emit_stage check_node running
    if detect_node_runtime; then
        if "$NODE_BIN" -v >/dev/null 2>&1 && "$NPM_BIN" -v >/dev/null 2>&1; then
            emit_stage check_node ok "DETAIL=system_${NODE_RUNTIME_VERSION}"
            return 0
        fi
        # System Node looked usable but its binaries failed to exec — fall back to portable.
        emit_stage check_node failed "REASON=system_node_broken"
        NODE_BIN=""
        NPM_BIN=""
        NODE_RUNTIME_KIND="missing"
        NODE_RUNTIME_VERSION=""
    else
        emit_stage check_node ok "DETAIL=missing"
    fi

    if ! download_portable_node; then
        return 1
    fi

    if ! "$NODE_BIN" -v >/dev/null 2>&1 || ! "$NPM_BIN" -v >/dev/null 2>&1; then
        rm -rf "$NODE_INSTALL_DIR"
        emit_stage check_node failed "REASON=portable_node_broken"
        return 1
    fi
    return 0
}

# --- npm registry + isolated install shim (M3) ---
select_npm_registry() {
    if [[ -n "$NPM_REGISTRY" ]]; then
        return 0
    fi
    if curl -fsS --max-time 4 "https://registry.npmjs.org/-/ping?write=true" >/dev/null 2>&1; then
        NPM_REGISTRY="https://registry.npmjs.org/"
    else
        NPM_REGISTRY="https://registry.npmmirror.com/"
    fi
    return 0
}

npm_isolated() {
    # The portable npm/npx are symlinks to *.js files with `#!/usr/bin/env node` shebangs,
    # so without PATH prepending the kernel resolves `node` from the user's PATH (which may
    # be a too-old version). Prepend the portable bin dir so all child node invocations
    # — including npm postinstall hooks — use the portable runtime.
    PATH="$(dirname "$NODE_BIN"):$PATH" "$NPM_BIN" --prefix "$NPM_PREFIX" --registry "$NPM_REGISTRY" "$@"
}

webui_node_path() {
    # Path prefix for invoking the hermes-web-ui CLI: prepend whichever Node bin dir we
    # resolved (portable or system) so the `#!/usr/bin/env node` shebang resolves to it.
    if [[ -n "$NODE_BIN" ]]; then
        printf '%s:' "$(dirname "$NODE_BIN")"
        return 0
    fi
    # Fall back to a portable install if it's already on disk (e.g. compute_app_state
    # before ensure_node_runtime has run).
    local fallback=""
    fallback="$NODE_INSTALL_DIR/${NODE_PORTABLE_VERSION}-darwin-arm64/bin"
    [[ -x "$fallback/node" ]] && { printf '%s:' "$fallback"; return 0; }
    fallback="$NODE_INSTALL_DIR/${NODE_PORTABLE_VERSION}-darwin-x64/bin"
    [[ -x "$fallback/node" ]] && { printf '%s:' "$fallback"; return 0; }
}

webui_bin_invoke() {
    PATH="$(webui_node_path)$PATH" "$WEBUI_BIN" "$@"
}

webui_installed_version() {
    [[ -x "$WEBUI_BIN" ]] || return 1
    local raw=""
    raw="$(webui_bin_invoke --version 2>/dev/null || true)"
    [[ -z "$raw" ]] && return 1
    raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
    raw="${raw#hermes-web-ui}"
    raw="${raw#@}"
    raw="${raw#v}"
    printf '%s' "$raw"
}

ensure_hermes_web_ui_installed() {
    mkdir -p "$NPM_PREFIX" "$RUNTIME_CACHE_DIR"
    : >>"$RUNTIME_INSTALL_LOG"

    if [[ -x "$WEBUI_BIN" ]]; then
        local installed_ver=""
        installed_ver="$(webui_installed_version || true)"
        if [[ "$installed_ver" == "$WEBUI_NPM_VERSION" ]]; then
            emit_stage install_webui ok "DETAIL=v$installed_ver"
            return 0
        fi
    fi

    if [[ -z "$NODE_BIN" || -z "$NPM_BIN" ]]; then
        emit_stage install_webui failed "REASON=node_not_resolved"
        return 1
    fi

    select_npm_registry
    emit_stage install_webui running "DETAIL=v$WEBUI_NPM_VERSION"

    {
        echo
        echo "[$(timestamp_now)] npm install ${WEBUI_NPM_PACKAGE}@${WEBUI_NPM_VERSION} (registry=$NPM_REGISTRY)"
    } >>"$RUNTIME_INSTALL_LOG"

    if ! npm_isolated install -g "${WEBUI_NPM_PACKAGE}@${WEBUI_NPM_VERSION}" >>"$RUNTIME_INSTALL_LOG" 2>&1; then
        local npm_exit=$?
        emit_stage install_webui failed "REASON=npm_install_failed_${npm_exit}"
        return 1
    fi

    if [[ ! -x "$WEBUI_BIN" ]]; then
        emit_stage install_webui failed "REASON=bin_missing"
        return 1
    fi
    chmod +x "$WEBUI_BIN" 2>/dev/null || true

    local got_version=""
    got_version="$(webui_installed_version || true)"
    if [[ "$got_version" != "$WEBUI_NPM_VERSION" ]]; then
        emit_stage install_webui failed "REASON=version_mismatch_${got_version:-unknown}"
        return 1
    fi

    emit_stage install_webui ok "DETAIL=v$WEBUI_NPM_VERSION"
    return 0
}

# --- WebUI lifecycle (M4, M5) ---
detect_webui_installed() {
    if [[ -x "$WEBUI_BIN" ]]; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

webui_health_check() {
    curl -fsS --max-time 3 "$WEBUI_HEALTH_URL" >/dev/null 2>&1
}

wait_for_webui_health() {
    local timeout="${1:-30}"
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if webui_health_check; then
            return 0
        fi
        sleep 1
    done
    return 1
}

detect_webui_running() {
    if webui_health_check; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

read_webui_token() {
    [[ -f "$WEBUI_TOKEN_FILE" ]] || return 1
    tr -d '[:space:]' <"$WEBUI_TOKEN_FILE"
}

read_webui_pid() {
    [[ -f "$WEBUI_PID_FILE" ]] || return 1
    tr -d '[:space:]' <"$WEBUI_PID_FILE"
}

start_hermes_web_ui() {
    local log_path="${1:-}"
    if [[ ! -x "$WEBUI_BIN" ]]; then
        emit_stage start_webui failed "REASON=bin_missing"
        return 1
    fi

    # Short-circuit: if the daemon is already healthy, skip the start call. The bin script
    # responds with "✗ hermes-web-ui is already running" and exit 1 in this case, which we'd
    # otherwise mis-translate into a hero error state — even though the WebUI is fine.
    if webui_health_check; then
        emit_stage start_webui ok "DETAIL=already_running"
        emit_stage wait_healthy ok "URL=$WEBUI_URL"
        return 0
    fi

    emit_stage start_webui running

    local tmp_log
    tmp_log="$(mktemp -t hermes-web-ui-start.XXXXXX 2>/dev/null || mktemp /tmp/hermes-web-ui-start.XXXXXX)"

    # The hermes-web-ui bin is a `#!/usr/bin/env node` symlink, and the daemon it forks
    # also relies on PATH-resolved `node`. webui_bin_invoke prepends the resolved Node
    # bin dir so both this invocation and the daemonized child use it.
    HERMES_HOME="$HERMES_HOME" \
    GATEWAY_ALLOW_ALL_USERS=true \
    API_SERVER_PORT=8642 \
    PORT="$WEBUI_PORT" \
        webui_bin_invoke start "$WEBUI_PORT" >"$tmp_log" 2>&1
    local bin_exit=$?

    if [[ -n "$log_path" ]]; then
        cat "$tmp_log" >>"$log_path" || true
    fi
    cat "$tmp_log" >>"$RUNTIME_INSTALL_LOG" || true
    rm -f "$tmp_log"

    if (( bin_exit != 0 )); then
        # Defensive double-check: the bin script may return non-zero even when the daemon
        # is alive (e.g. another process won a race and the bin printed "already running").
        # If `/health` responds now, treat as success.
        if webui_health_check; then
            emit_stage start_webui ok "DETAIL=already_running_post_check"
            emit_stage wait_healthy ok "URL=$WEBUI_URL"
            return 0
        fi
        emit_stage start_webui failed "REASON=bin_exit_${bin_exit}"
        return 1
    fi
    emit_stage start_webui ok

    emit_stage wait_healthy running
    if ! wait_for_webui_health 30; then
        emit_stage wait_healthy failed "REASON=health_timeout"
        return 1
    fi
    emit_stage wait_healthy ok "URL=$WEBUI_URL"
    return 0
}

stop_hermes_web_ui() {
    if [[ ! -x "$WEBUI_BIN" ]]; then
        emit_stage stop_webui ok "DETAIL=not_installed"
        return 0
    fi
    if webui_bin_invoke stop >>"$RUNTIME_INSTALL_LOG" 2>&1; then
        emit_stage stop_webui ok
    else
        # bin script returns non-zero when nothing was running — treat as benign.
        emit_stage stop_webui ok "DETAIL=not_running"
    fi
    return 0
}

status_hermes_web_ui() {
    [[ -x "$WEBUI_BIN" ]] || return 1
    webui_bin_invoke status 2>/dev/null
}

# --- Track A: messaging-platform deps (port of Windows Install-GatewayPlatformDeps) ---

# Resolve the venv python; install_dir/venv/bin/python is the install.sh-created path.
agent_venv_python() {
    local cand="$INSTALL_DIR/venv/bin/python"
    [[ -x "$cand" ]] || cand="$INSTALL_DIR/venv/bin/python3"
    [[ -x "$cand" ]] || return 1
    printf '%s' "$cand"
}

# Echo the pretty Chinese label for a platform env-var key.
gateway_platform_label() {
    local key="$1"
    local pair label
    for pair in "${GATEWAY_PLATFORM_LABELS[@]}"; do
        if [[ "${pair%%:*}" == "$key" ]]; then
            label="${pair#*:}"
            printf '%s' "$label"
            return 0
        fi
    done
    printf '%s' "$key"
}

# Read a single env-var value out of ~/.hermes/.env (skipping commented / empty lines).
# Returns empty if not set or value is empty.
read_env_value() {
    local key="$1"
    local env_file="$HERMES_HOME/.env"
    [[ -f "$env_file" ]] || return 0
    awk -F= -v key="$key" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            if ($1 == key) {
                v = substr($0, index($0, "=") + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                gsub(/^"|"$|^'\''|'\''$/, "", v)
                print v
                exit
            }
        }
    ' "$env_file"
}

# Strict-verify that a Python module imports AND its __file__ lives inside the venv site-packages.
# Returns 0 if OK, non-zero otherwise. Stdout: "OK" / "IMPORT_ERROR:..." / "PATH_MISMATCH:..."
gateway_strict_verify_module() {
    local module="$1"
    local py
    py="$(agent_venv_python)" || return 2
    local site_packages="$INSTALL_DIR/venv/lib"
    "$py" - "$module" "$site_packages" <<'PY' 2>&1
import sys
mod, expected = sys.argv[1], sys.argv[2]
try:
    m = __import__(mod)
    p = (getattr(m, '__file__', '') or '').lower()
    if p and expected.lower() in p:
        print('OK')
    else:
        print('PATH_MISMATCH:' + p)
        sys.exit(2)
except ImportError as e:
    print('IMPORT_ERROR:' + str(e))
    sys.exit(1)
except Exception as e:
    print('UNEXPECTED:' + str(e))
    sys.exit(3)
PY
}

# Resolve the `uv` binary path. The Hermes installer typically installs uv to ~/.local/bin.
agent_uv_command() {
    local cand
    for cand in "$HOME/.local/bin/uv" "$INSTALL_DIR/venv/bin/uv" "/opt/homebrew/bin/uv" "/usr/local/bin/uv"; do
        if [[ -x "$cand" ]]; then
            printf '%s' "$cand"
            return 0
        fi
    done
    if command -v uv >/dev/null 2>&1; then
        command -v uv
        return 0
    fi
    return 1
}

# pip install <pkgs> into the agent venv. Prefers `uv pip install --python <venv-python>` because
# venvs created via `uv venv` don't ship with pip itself by default. Falls back to ensurepip + pip.
# Captures stdout/stderr to RUNTIME_INSTALL_LOG.
agent_pip_install() {
    local py
    py="$(agent_venv_python)" || return 2
    {
        echo
        echo "[$(timestamp_now)] agent pip install $*"
    } >>"$RUNTIME_INSTALL_LOG"

    local uv
    if uv="$(agent_uv_command)"; then
        "$uv" pip install --python "$py" "$@" >>"$RUNTIME_INSTALL_LOG" 2>&1
        return $?
    fi

    # Fallback: bootstrap pip into the venv if needed, then use it.
    if ! "$py" -m pip --version >/dev/null 2>&1; then
        echo "[$(timestamp_now)] bootstrapping pip via ensurepip" >>"$RUNTIME_INSTALL_LOG"
        "$py" -m ensurepip --upgrade >>"$RUNTIME_INSTALL_LOG" 2>&1 || return 4
    fi
    "$py" -m pip install "$@" >>"$RUNTIME_INSTALL_LOG" 2>&1
}

# Append GATEWAY_ALLOW_ALL_USERS=true to .env if any platform is configured but flag missing.
ensure_gateway_allow_all_users() {
    local env_file="$HERMES_HOME/.env"
    [[ -f "$env_file" ]] || return 0
    if grep -Eq '^[[:space:]]*GATEWAY_ALLOW_ALL_USERS[[:space:]]*=[[:space:]]*true' "$env_file"; then
        return 0
    fi
    {
        echo
        echo "GATEWAY_ALLOW_ALL_USERS=true"
    } >>"$env_file"
    emit_stage gateway_allow_all_users ok "DETAIL=appended"
}

# Track A entry point. Pure on-demand: scan .env and install only configured platforms.
ensure_gateway_platform_deps() {
    local env_file="$HERMES_HOME/.env"
    if [[ ! -f "$env_file" ]]; then
        emit_stage install_platform_deps skipped "DETAIL=no_env"
        return 0
    fi
    local py
    if ! py="$(agent_venv_python)"; then
        emit_stage install_platform_deps skipped "DETAIL=no_agent_venv"
        return 0
    fi

    : >>"$RUNTIME_INSTALL_LOG"

    # Configured-platform set: pretty labels for the Swift-side aggregator.
    local configured_labels=()
    local row key module pkgs val label
    local any_failure=0
    local any_configured=0
    local any_new_install=0
    local seen_keys=":"

    for row in "${GATEWAY_PLATFORM_MAP[@]}"; do
        key="${row%%:*}"
        module="$(printf '%s' "$row" | cut -d: -f2)"
        pkgs="$(printf '%s' "$row" | cut -d: -f3-)"
        val="$(read_env_value "$key")"
        [[ -z "$val" ]] && continue

        any_configured=1
        label="$(gateway_platform_label "$key")"

        # Dedup labels (e.g. WEIXIN_TOKEN + WEIXIN_ACCOUNT_ID both map to 微信).
        if [[ "$seen_keys" != *":${label}:"* ]]; then
            seen_keys+="${label}:"
            configured_labels+=("$label")
        fi

        # Zero-dep platforms (weixin / wecom): just verify and continue.
        if [[ -z "$pkgs" ]]; then
            emit_stage platform_dep ok "PLATFORM=${label}" "DETAIL=zero_dep"
            continue
        fi

        # Strict pre-verify.
        emit_stage platform_dep running "PLATFORM=${label}" "DETAIL=verifying"
        local verify_out=""
        verify_out="$(gateway_strict_verify_module "$module" 2>&1 || true)"
        if [[ "$verify_out" == *"OK"* ]]; then
            emit_stage platform_dep ok "PLATFORM=${label}" "DETAIL=already_installed"
            continue
        fi

        # Missing — install.
        emit_stage platform_dep running "PLATFORM=${label}" "DETAIL=installing"
        # shellcheck disable=SC2086 — pkgs is intentionally word-split so multi-pkg rows install together.
        agent_pip_install $pkgs
        local pip_exit=$?
        if (( pip_exit != 0 )); then
            emit_stage platform_dep failed "PLATFORM=${label}" "REASON=pip_install_${pip_exit}"
            any_failure=1
            continue
        fi

        # Post-verify.
        verify_out="$(gateway_strict_verify_module "$module" 2>&1 || true)"
        if [[ "$verify_out" == *"OK"* ]]; then
            emit_stage platform_dep ok "PLATFORM=${label}" "DETAIL=installed"
            any_new_install=1
        else
            emit_stage platform_dep failed "PLATFORM=${label}" "REASON=post_verify_failed"
            any_failure=1
        fi
    done

    if (( any_configured == 0 )); then
        emit_stage install_platform_deps skipped "DETAIL=no_channels"
        return 0
    fi

    ensure_gateway_allow_all_users

    # Emit the ordered configured-platform list so the Swift store can render the simplified
    # stage-2 row's detail string ("正在配置：飞书、Telegram").
    local joined=""
    local i
    for ((i = 0; i < ${#configured_labels[@]}; i++)); do
        if (( i > 0 )); then joined+="、"; fi
        joined+="${configured_labels[$i]}"
    done
    emit_stage install_platform_deps_summary ok "COUNT=${#configured_labels[@]}" "PLATFORMS=${joined}"

    if (( any_failure != 0 )); then
        emit_stage install_platform_deps failed "DETAIL=${joined}"
        return 1
    fi
    emit_stage install_platform_deps ok "DETAIL=${joined}"

    # If we just installed at least one new pip package, the running gateway can't see it
    # (Python imports are cached at process start). Restart the gateway so the new adapter
    # actually loads. Without this, users who configure Telegram/Feishu/etc. in WebUI see
    # "no response" until they manually restart — see chat #N+5.
    if (( any_new_install != 0 )); then
        restart_gateway_for_new_deps
    fi
    return 0
}

# Restart the hermes-agent gateway so it picks up newly-installed messaging deps.
# Best-effort: emits STAGE events for UI feedback but never fails the parent flow.
restart_gateway_for_new_deps() {
    emit_stage restart_gateway running "DETAIL=picking_up_new_deps"
    local hermes_cmd="$INSTALL_DIR/venv/bin/hermes"
    if [[ ! -x "$hermes_cmd" ]]; then
        # Fallback: try the user's PATH-resolved hermes.
        hermes_cmd="$(command -v hermes 2>/dev/null || true)"
    fi
    if [[ -z "$hermes_cmd" || ! -x "$hermes_cmd" ]]; then
        emit_stage restart_gateway skipped "DETAIL=hermes_cli_missing"
        return 0
    fi
    if "$hermes_cmd" gateway restart >>"$RUNTIME_INSTALL_LOG" 2>&1; then
        emit_stage restart_gateway ok
    else
        local exit_code=$?
        emit_stage restart_gateway failed "REASON=gateway_restart_${exit_code}"
    fi
    return 0
}

# --- Track B: post-verify gateway connected platforms == configured ---

# Count messaging platforms in .env (deduped: WEIXIN_TOKEN + WEIXIN_ACCOUNT_ID = 1).
count_configured_platforms() {
    local env_file="$HERMES_HOME/.env"
    [[ -f "$env_file" ]] || { printf '0'; return; }
    local row key val seen=":"
    local count=0
    for row in "${GATEWAY_PLATFORM_MAP[@]}"; do
        key="${row%%:*}"
        val="$(read_env_value "$key")"
        [[ -z "$val" ]] && continue
        # Map the env-var key back to its platform label for dedup.
        local label
        label="$(gateway_platform_label "$key")"
        if [[ "$seen" != *":${label}:"* ]]; then
            seen+="${label}:"
            ((count++))
        fi
    done
    printf '%d' "$count"
}

# Read most recent "Gateway running with N platform(s)" from gateway.log.
# Echoes integer N (ACTUAL platform count incl. api_server), or empty on no-info.
read_gateway_running_count() {
    local gw_log="$HERMES_HOME/logs/gateway.log"
    [[ -f "$gw_log" ]] || return 0
    tail -n 200 "$gw_log" 2>/dev/null \
        | grep -E 'Gateway running with [0-9]+ platform' \
        | tail -n 1 \
        | sed -E 's/.*Gateway running with ([0-9]+) platform.*/\1/'
}

# Track B entry point. Returns 0 if matched (or no info / no config), non-zero on persistent mismatch.
verify_gateway_platforms_match_env() {
    local configured actual expected
    configured="$(count_configured_platforms)"
    if [[ "$configured" -eq 0 ]]; then
        emit_stage verify_platforms ok "DETAIL=no_channels"
        return 0
    fi
    expected=$((configured + 1))  # +1 for api_server
    sleep 5  # let laggy adapters finish connecting
    actual="$(read_gateway_running_count || true)"
    if [[ -z "$actual" ]]; then
        emit_stage verify_platforms ok "DETAIL=no_log"
        return 0
    fi
    if [[ "$actual" -ge "$expected" ]]; then
        emit_stage verify_platforms ok "ACTUAL=${actual}" "EXPECTED=${expected}"
        return 0
    fi
    # Mismatch — 1 retry attempt with 5s sleep, mirroring Windows.
    emit_stage verify_platforms running "DETAIL=mismatch_retry" "ACTUAL=${actual}" "EXPECTED=${expected}"
    sleep 5
    actual="$(read_gateway_running_count || true)"
    if [[ -n "$actual" && "$actual" -ge "$expected" ]]; then
        emit_stage verify_platforms ok "ACTUAL=${actual}" "EXPECTED=${expected}"
        return 0
    fi
    emit_stage verify_platforms mismatch_persistent "ACTUAL=${actual:-0}" "EXPECTED=${expected}" "CONFIGURED=${configured}"
    return 1
}

compute_app_state() {
    local hermes_cmd="$1"
    local installed="false"
    local webui_installed="false"
    local webui_running="false"
    local webui_pid=""
    local webui_version=""

    if is_installed "$hermes_cmd"; then
        installed="true"
        ensure_config_scaffold
    fi

    if [[ "$(detect_webui_installed)" == "true" ]]; then
        webui_installed="true"
        webui_version="$(webui_installed_version 2>/dev/null || true)"
    fi
    if webui_health_check; then
        webui_running="true"
    fi
    webui_pid="$(read_webui_pid 2>/dev/null || true)"

    if [[ -z "$NODE_RUNTIME_KIND" || "$NODE_RUNTIME_KIND" == "missing" ]]; then
        # Cheap probe: try to detect a system Node. Never download here — that belongs to the launch flow.
        detect_node_runtime >/dev/null 2>&1 || true
    fi

    cat <<EOF
installed=$installed
webui_installed=$webui_installed
webui_running=$webui_running
webui_url=$WEBUI_URL
webui_version=$webui_version
webui_pid=$webui_pid
node_runtime_kind=$NODE_RUNTIME_KIND
node_runtime_version=$NODE_RUNTIME_VERSION
EOF
}

build_dashboard_prompt() {
    # TODO(macos-webui-migration UI follow-up): finalize 2-line summary copy alongside design mockup approval.
    local state="$1"
    local installed webui_installed webui_running
    installed="$(state_get installed "$state")"
    webui_installed="$(state_get webui_installed "$state")"
    webui_running="$(state_get webui_running "$state")"

    local install_line="未开始"
    local launch_line="尚不可用"
    local current_step="继续安装"

    if [[ "$LAST_STAGE" == "install" && "$LAST_RESULT" == "running" ]]; then
        install_line="进行中"
    elif [[ "$installed" == "true" ]]; then
        install_line="已完成"
    fi

    if [[ "$installed" == "true" ]]; then
        if [[ "$webui_running" == "true" ]]; then
            launch_line="已在运行"
            current_step="打开浏览器对话"
        elif [[ "$webui_installed" == "true" ]]; then
            launch_line="可以启动"
            current_step="启动浏览器对话"
        else
            launch_line="待安装"
            current_step="启动浏览器对话"
        fi
    fi
    if [[ "$LAST_STAGE" == "chat" && "$LAST_RESULT" == "running" ]]; then
        launch_line="进行中"
    fi

    cat <<EOF
Hermes macOS 启动器

当前步骤：$current_step
版本：$LAUNCHER_VERSION

阶段总览
1. 安装 Hermes        $install_line
2. 启动浏览器对话     $launch_line

数据目录：$HERMES_HOME
最近操作：$LAST_ACTION_SUMMARY

只处理当前这一步即可，其余内容稍后再看。
EOF
}

next_primary_action() {
    local state="$1"
    local installed
    installed="$(state_get installed "$state")"

    if [[ "$installed" != "true" ]]; then
        printf '开始安装\n'
    else
        printf '启动浏览器对话\n'
    fi
}

show_intro_dialog() {
    local message="$1"
    local default_button="${2:-是}"
    local picked=""
    picked="$(prompt_yes_no "$message" "$default_button")" || return 1
    [[ "$picked" == "是" ]]
}

maybe_handle_stage_completion() {
    local state="$1"
    local installed
    installed="$(state_get installed "$state")"

    if [[ "$LAST_RESULT" == "running" || "$LAST_RESULT" == "idle" ]]; then
        return 0
    fi

    case "$LAST_STAGE" in
        install)
            if [[ "$LAST_RESULT" == "success" && "$installed" == "true" ]]; then
                show_message "安装已完成。\n\n下一步会启动浏览器对话；模型与渠道配置都可以在浏览器里完成。"
                set_stage_state "none" "idle" "$LAST_LOG_PATH"
            else
                local picked=""
                picked="$(prompt_failure_action "安装还没有完成。\n\n如果终端里已经报错或提前结束，可以重新尝试，或先打开日志查看原因。")" || return 0
                case "$picked" in
                    "重新尝试") set_stage_state "none" "idle" "$LAST_LOG_PATH"; start_install_flow ;;
                    "打开日志") open_path "$LAST_LOG_PATH"; set_stage_state "none" "idle" "$LAST_LOG_PATH" ;;
                    *) set_stage_state "none" "idle" "$LAST_LOG_PATH" ;;
                esac
            fi
            ;;
        chat)
            if [[ "$LAST_RESULT" == "success" ]]; then
                show_message "Hermes WebUI 已打开。\n\n如果浏览器里已经出现 Hermes 对话界面，现在就可以开始使用。"
            elif [[ -n "$LAST_LOG_PATH" ]]; then
                local picked=""
                picked="$(prompt_webui_failure_action "Hermes 对话界面没有正常打开。\n\n你可以改用终端对话继续使用，或者重新尝试浏览器对话。")" || return 0
                case "$picked" in
                    "改用终端对话") set_stage_state "none" "idle" "$LAST_LOG_PATH"; start_terminal_chat_flow "$(resolve_hermes_command 2>/dev/null || true)" ;;
                    "重新尝试") set_stage_state "none" "idle" "$LAST_LOG_PATH"; start_chat_flow "$(resolve_hermes_command 2>/dev/null || true)" ;;
                    "打开日志") open_path "$LAST_LOG_PATH"; set_stage_state "none" "idle" "$LAST_LOG_PATH" ;;
                    *) set_stage_state "none" "idle" "$LAST_LOG_PATH" ;;
                esac
                return 0
            fi
            set_stage_state "none" "idle" "$LAST_LOG_PATH"
            ;;
        *)
            ;;
    esac
}

run_in_terminal() {
    local payload="$1"
    local title="$2"
    local log_path="${3:-}"
    local capture_output="${4:-true}"
    local script_path
    script_path="$(write_temp_command_script "$payload" "$title" "$log_path" "$capture_output")"
    /usr/bin/osascript - "$script_path" <<'OSA'
on run argv
    set scriptPath to item 1 of argv
    tell application "Terminal"
        activate
        do script ("bash " & quoted form of scriptPath)
    end tell
end run
OSA
}

open_path() {
    local path="$1"
    if [[ -e "$path" ]]; then
        open "$path"
    else
        show_warning "路径不存在：$path"
    fi
}

require_hermes() {
    local hermes_cmd="$1"
    if [[ -z "$hermes_cmd" ]]; then
        show_warning "当前没有检测到可用的 Hermes 命令。请先安装 Hermes。"
        return 1
    fi
    return 0
}

launch_install() {
    local log_path
    log_path="$(build_log_path "install")"
    local payload=""
    payload+="INSTALL_EXIT=0; "
    payload+="FALLBACK_EXIT=0; "
    payload+="INSTALL_SCRIPT=\$(mktemp -t hermes-install.XXXXXX.sh); "
    payload+="cleanup() { rm -f \"\$INSTALL_SCRIPT\"; }; trap cleanup EXIT; "
    payload+="echo '先尝试官方一键安装...'; "
    payload+="if curl -fsSL $(printf '%q' "$OFFICIAL_INSTALL_URL") -o \"\$INSTALL_SCRIPT\"; then "
    payload+="bash \"\$INSTALL_SCRIPT\" --branch $(printf '%q' "$BRANCH") --skip-setup; "
    payload+="INSTALL_EXIT=\$?; "
    payload+="else "
    payload+="echo '官方安装脚本下载失败。'; "
    payload+="INSTALL_EXIT=1; "
    payload+="fi; "
    payload+="if [[ \"\$INSTALL_EXIT\" -ne 0 ]]; then "
    payload+="echo; "
    payload+="echo '官方一键安装失败，正在自动切换到官方手动安装步骤...'; "
    payload+="rm -rf $(printf '%q' "$INSTALL_DIR"); "
    payload+="mkdir -p $(printf '%q' "$HERMES_HOME"); "
    payload+="cd $(printf '%q' "$HERMES_HOME"); "
    payload+="git clone --recurse-submodules --branch $(printf '%q' "$BRANCH") --single-branch $(printf '%q' "$OFFICIAL_REPO_URL") $(printf '%q' "$INSTALL_DIR") || FALLBACK_EXIT=\$?; "
    payload+="if [[ \"\$FALLBACK_EXIT\" -eq 0 ]]; then "
    payload+="cd $(printf '%q' "$INSTALL_DIR"); "
    payload+="uv venv venv --python 3.11 || FALLBACK_EXIT=\$?; "
    payload+="fi; "
    payload+="if [[ \"\$FALLBACK_EXIT\" -eq 0 ]]; then "
    payload+="uv pip install -e '.[all]' || FALLBACK_EXIT=\$?; "
    payload+="fi; "
    payload+="if [[ \"\$FALLBACK_EXIT\" -eq 0 && -f package.json ]]; then "
    payload+="npm install || FALLBACK_EXIT=\$?; "
    payload+="fi; "
    payload+="if [[ \"\$FALLBACK_EXIT\" -eq 0 ]]; then "
    payload+="mkdir -p $(printf '%q' "$HOME/.local/bin"); "
    payload+="ln -sf $(printf '%q' "$INSTALL_DIR/venv/bin/hermes") $(printf '%q' "$HOME/.local/bin/hermes") || FALLBACK_EXIT=\$?; "
    payload+="fi; "
    payload+="if [[ \"\$FALLBACK_EXIT\" -eq 0 ]]; then "
    payload+="echo '官方手动安装步骤已自动完成。'; "
    payload+="INSTALL_EXIT=0; "
    payload+="else "
    payload+="echo '官方手动安装步骤也失败了，请查看上方报错。'; "
    payload+="INSTALL_EXIT=\"\$FALLBACK_EXIT\"; "
    payload+="fi; "
    payload+="fi; "
    # Track D: pin to a known-good commit if HERMES_AGENT_PINNED_COMMIT is not HEAD.
    # Runs only on success and when a non-HEAD pin is configured. Failures are surfaced as warnings,
    # not fatal — the install is already valid at the moving-main HEAD.
    payload+="if [[ \"\$INSTALL_EXIT\" -eq 0 && $(printf '%q' "$HERMES_AGENT_PINNED_COMMIT") != 'HEAD' ]]; then "
    payload+="echo; echo '正在切换到固定版本 $HERMES_AGENT_PINNED_COMMIT ...'; "
    payload+="if (cd $(printf '%q' "$INSTALL_DIR") && git fetch --depth 50 origin && git checkout --quiet $(printf '%q' "$HERMES_AGENT_PINNED_COMMIT")); then "
    payload+="(cd $(printf '%q' "$INSTALL_DIR") && (uv pip install -e '.' 2>/dev/null || $(printf '%q' "$INSTALL_DIR")/venv/bin/python -m pip install -e '.' 2>/dev/null || true)); "
    payload+="echo '已切到固定版本。'; "
    payload+="else "
    payload+="echo '切换固定版本失败，将沿用刚装的 main 版本。'; "
    payload+="fi; "
    payload+="fi; "
    payload+="echo; if [[ \"\$INSTALL_EXIT\" -eq 0 ]]; then echo '安装流程已结束，可关闭此终端窗口。'; else echo '安装流程失败，请查看上方报错。'; fi; "
    payload+="FINAL_RESULT=failed; if [[ \"\$INSTALL_EXIT\" -eq 0 ]]; then FINAL_RESULT=success; fi; "
    payload+="printf 'LAST_STAGE=%s\nLAST_RESULT=%s\nLAST_LOG_PATH=%s\n' install \"\$FINAL_RESULT\" $(printf '%q' "$log_path") > $(printf '%q' "$LAUNCHER_STATE_FILE"); "
    payload+="if [[ \"\$INSTALL_EXIT\" -eq 0 ]]; then (sleep 1; close_terminal_window_by_title) >/dev/null 2>&1 & fi; "
    payload+="exit \"\$INSTALL_EXIT\""

    if run_in_terminal "$payload" "Hermes 安装或更新" "$log_path" "true"; then
        set_last_action "已启动安装或更新，日志：$log_path"
        set_stage_state "install" "running" "$log_path"
        return 0
    fi

    set_last_action "安装终端拉起失败"
    set_stage_state "install" "failed" "$log_path"
    show_warning "没有成功拉起 Terminal，安装流程尚未开始。请检查 macOS 是否阻止了终端启动。"
    return 1
}

run_hermes_action() {
    local hermes_cmd="$1"
    local label="$2"
    local args="$3"
    local keep_note="${4:-命令执行结束后，可关闭窗口。}"
    local stage="${5:-}"
    local capture_output="${6:-true}"
    local command_prefix="${7:-}"
    require_hermes "$hermes_cmd" || return 0

    local log_path
    log_path="$(build_log_path "$label")"
    local payload=""
    payload+="cd $(printf '%q' "$INSTALL_DIR"); "
    if [[ "$capture_output" != "true" && -n "$log_path" ]]; then
        payload+="printf '%s %s\n' $(printf '%q' "[$(timestamp_now)]") $(printf '%q' "启动 $label") >> $(printf '%q' "$log_path"); "
    fi
    payload+="if $command_prefix $(printf '%q' "$hermes_cmd") $args; then CMD_EXIT=0; else CMD_EXIT=\$?; fi; "
    if [[ -n "$keep_note" ]]; then
        payload+="echo; echo $(printf '%q' "$keep_note"); "
    fi
    if [[ "$capture_output" != "true" && -n "$log_path" ]]; then
        payload+="printf '%s %s %s\n' $(printf '%q' "[$(timestamp_now)]") $(printf '%q' "$label 结束，退出码：") \"\$CMD_EXIT\" >> $(printf '%q' "$log_path"); "
    fi
    if [[ -n "$stage" ]]; then
        payload+="FINAL_RESULT=failed; if [[ \$CMD_EXIT -eq 0 ]]; then FINAL_RESULT=success; fi; "
        payload+="printf 'LAST_STAGE=%s\nLAST_RESULT=%s\nLAST_LOG_PATH=%s\n' $(printf '%q' "$stage") \"\$FINAL_RESULT\" $(printf '%q' "$log_path") > $(printf '%q' "$LAUNCHER_STATE_FILE"); "
    fi
    payload+="exit \$CMD_EXIT"

    if run_in_terminal "$payload" "Hermes $label" "$log_path" "$capture_output"; then
        set_last_action "已启动 $label，日志：$log_path"
        if [[ -n "$stage" ]]; then
            set_stage_state "$stage" "running" "$log_path"
        fi
        return 0
    fi

    set_last_action "$label 终端拉起失败"
    if [[ -n "$stage" ]]; then
        set_stage_state "$stage" "failed" "$log_path"
    fi
    show_warning "没有成功拉起 Terminal，$label 尚未开始。请检查 macOS 是否阻止了终端启动。"
    return 1
}

print_state_test() {
    local hermes_cmd=""
    if hermes_cmd="$(resolve_hermes_command 2>/dev/null)"; then
        ensure_config_scaffold
    else
        hermes_cmd=""
    fi
    load_session_state
    local state=""
    state="$(compute_app_state "$hermes_cmd")"
    printf '%s\n' "$state"
    printf 'primary_action=%s\n' "$(next_primary_action "$state")"
    printf 'last_stage=%s\nlast_result=%s\nlast_log_path=%s\n' "$LAST_STAGE" "$LAST_RESULT" "$LAST_LOG_PATH"
}

launch_terminal_chat() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "终端对话" "chat" "" "" "false"
}

open_webui_browser() {
    local token=""
    token="$(read_webui_token 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
        open "http://localhost:${WEBUI_PORT}/#/?token=${token}"
    else
        open "$WEBUI_URL"
    fi
}

handle_webui_launch_failure() {
    local log_path="$1"
    local message="$2"
    local hermes_cmd="$3"
    local picked=""

    picked="$(prompt_webui_failure_action "$message\n\n你可以先改用终端对话继续使用，或打开日志查看原因。\n\n日志位置：\n$log_path")" || return 0
    case "$picked" in
        "改用终端对话") launch_terminal_chat "$hermes_cmd" ;;
        "重新尝试") launch_webui_chat "$hermes_cmd" ;;
        "打开日志") open_path "$log_path" ;;
        *) ;;
    esac
}

launch_webui_chat() {
    local hermes_cmd="$1"
    require_hermes "$hermes_cmd" || return 0

    local log_path
    log_path="$(build_log_path "webui")"
    set_last_action "正在准备 Hermes WebUI，日志：$log_path"
    set_stage_state "chat" "running" "$log_path"

    {
        echo
        echo "[$(timestamp_now)] launch_webui_chat begin"
        echo "WebUI URL: $WEBUI_URL"
        echo "Runtime root: $LAUNCHER_RUNTIME_DIR"
    } >>"$log_path"

    if webui_health_check; then
        open_webui_browser
        set_last_action "已打开 Hermes WebUI：$WEBUI_URL"
        set_stage_state "chat" "success" "$log_path"
        return 0
    fi

    if ! ensure_node_runtime >>"$log_path" 2>&1; then
        set_last_action "Node.js 运行时准备失败，日志：$log_path"
        set_stage_state "chat" "failed" "$log_path"
        handle_webui_launch_failure "$log_path" "Node.js 运行时准备失败。" "$hermes_cmd"
        return 1
    fi

    if ! ensure_hermes_web_ui_installed >>"$log_path" 2>&1; then
        set_last_action "WebUI 安装失败，日志：$log_path"
        set_stage_state "chat" "failed" "$log_path"
        handle_webui_launch_failure "$log_path" "Hermes WebUI 安装失败。" "$hermes_cmd"
        return 1
    fi

    if ! start_hermes_web_ui "$log_path" >>"$log_path" 2>&1; then
        set_last_action "Hermes WebUI 启动失败，日志：$log_path"
        set_stage_state "chat" "failed" "$log_path"
        handle_webui_launch_failure "$log_path" "Hermes 对话界面没有启动成功。" "$hermes_cmd"
        return 1
    fi

    open_webui_browser
    set_last_action "已打开 Hermes WebUI：$WEBUI_URL"
    set_stage_state "chat" "success" "$log_path"
}

restart_webui_action() {
    local hermes_cmd="$1"
    local log_path
    log_path="$(build_log_path "webui-restart")"
    set_last_action "正在重启 Hermes WebUI，日志：$log_path"
    stop_hermes_web_ui >>"$log_path" 2>&1 || true
    launch_webui_chat "$hermes_cmd"
}

stop_webui_action() {
    local log_path
    log_path="$(build_log_path "webui-stop")"
    set_last_action "正在停止 Hermes WebUI，日志：$log_path"
    stop_hermes_web_ui >>"$log_path" 2>&1 || true
    set_last_action "Hermes WebUI 已停止"
}

run_doctor() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "doctor" "doctor" "命令执行结束后，可关闭窗口。" "" "true"
}

print_doctor_test() {
    ensure_launcher_dirs

    local hermes_cmd=""
    if hermes_cmd="$(resolve_hermes_command 2>/dev/null)"; then
        ensure_config_scaffold
    else
        printf 'status=missing\n'
        printf 'exit_code=127\n'
        printf 'log_path=\n'
        exit 0
    fi

    local log_path
    log_path="$(build_log_path "doctor-inline")"

    cd "$INSTALL_DIR"
    if "$hermes_cmd" doctor >"$log_path" 2>&1; then
        printf 'status=ok\n'
        printf 'exit_code=0\n'
    else
        local exit_code=$?
        printf 'status=failed\n'
        printf 'exit_code=%s\n' "$exit_code"
    fi
    printf 'log_path=%s\n' "$log_path"
}

run_update() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "update" "update" "命令执行结束后，可关闭窗口。" "" "true"
}

run_tools() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "tools" "tools" "命令执行结束后，可关闭窗口。" "" "true"
}

run_full_setup() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "完整 setup" "setup" "命令执行结束后，可关闭窗口。" "" "true"
}

uninstall_hermes() {
    local mode=""
    mode="$(prompt_uninstall_mode "选择卸载方式：\n\n标准卸载：删除程序，保留 ~/.hermes 数据。\n彻底卸载：同时删除 ~/.hermes 数据。")" || return 0
    local log_path
    log_path="$(build_log_path "uninstall")"
    local payload=""
    payload+="rm -f $(printf '%q' "$HOME/.local/bin/hermes"); "
    payload+="rm -rf $(printf '%q' "$INSTALL_DIR"); "
    if [[ "$mode" == "彻底卸载" ]]; then
        payload+="rm -rf $(printf '%q' "$HERMES_HOME"); "
    fi
    payload+="echo; echo '卸载流程已结束，可关闭此终端窗口。'"

    set_last_action "已启动卸载，日志：$log_path"
    run_in_terminal "$payload" "Hermes 卸载" "$log_path"
}

open_official_docs() { open "$OFFICIAL_DOCS_URL"; }
open_official_repo() { open "$OFFICIAL_REPO_URL"; }

open_official_resource() {
    local picked=""
    picked="$(choose_from_list "选择要打开的官方资源。" "官方文档" "官方文档" "官方仓库" "返回")" || return 0
    case "$picked" in
        "官方文档") open_official_docs ;;
        "官方仓库") open_official_repo ;;
        *) ;;
    esac
}

handle_advanced_action() {
    local picked="$1"
    local hermes_cmd="$2"
    case "$picked" in
        "诊断问题（doctor）"|doctor) run_doctor "$hermes_cmd" ;;
        "更新 Hermes"|update) run_update "$hermes_cmd" ;;
        "重新执行完整设置"|setup) run_full_setup "$hermes_cmd" ;;
        "配置 tools"|tools) run_tools "$hermes_cmd" ;;
        "打开终端对话"|chat_terminal|chat-terminal) start_terminal_chat_flow "$hermes_cmd" ;;
        "停止浏览器对话"|stop_webui|stop-webui) stop_webui_action ;;
        "重启浏览器对话"|restart_webui|restart-webui) restart_webui_action "$hermes_cmd" ;;
        "打开配置文件 config.yaml"|open_config) ensure_config_scaffold; open_path "$HERMES_HOME/config.yaml" ;;
        "打开环境变量 .env"|open_env) ensure_config_scaffold; open_path "$HERMES_HOME/.env" ;;
        "打开日志目录"|open_logs) open_path "$HERMES_HOME/logs" ;;
        "打开数据目录"|open_home) open_path "$HERMES_HOME" ;;
        "打开安装目录"|open_install) open_path "$INSTALL_DIR" ;;
        "官方文档 / 仓库") open_official_resource ;;
        docs) open_official_docs ;;
        repo) open_official_repo ;;
        "卸载 Hermes"|uninstall) uninstall_hermes ;;
        *) ;;
    esac
}

maintenance_menu() {
    choose_from_list "维护与高级选项" "诊断问题（doctor）" \
        "诊断问题（doctor）" \
        "更新 Hermes" \
        "重新执行完整设置" \
        "配置 tools" \
        "打开终端对话" \
        "停止浏览器对话" \
        "重启浏览器对话" \
        "打开配置文件 config.yaml" \
        "打开环境变量 .env" \
        "打开日志目录" \
        "打开数据目录" \
        "打开安装目录" \
        "官方文档 / 仓库" \
        "卸载 Hermes" \
        "返回"
}

main_menu() {
    local prompt="$2"
    local primary_action="$1"
    choose_from_list "$prompt" "$primary_action" \
        "$primary_action" \
        "维护与高级选项" \
        "退出"
}

start_install_flow() {
    local intro=$'接下来会打开 Terminal 开始安装。\n\n你需要做的只有一件事：等待安装完成。\n安装期间请不要关闭 Terminal。安装成功后，窗口会自动关闭。\n\n现在继续安装吗？'
    show_intro_dialog "$intro" "是" || return 0
    launch_install || return 0
}

start_chat_flow() {
    local hermes_cmd="$1"
    if webui_health_check; then
        launch_webui_chat "$hermes_cmd" || return 0
        return 0
    fi
    local intro=""
    if [[ "$(detect_webui_installed)" == "true" ]]; then
        intro=$'接下来会启动浏览器对话。\n\n模型与渠道配置都在浏览器里完成，启动器只负责把它拉起来。\n\n现在打开浏览器对话吗？'
    else
        intro=$'第一次启动浏览器对话需要先准备 Node.js 运行时并安装 hermes-web-ui 包。\n\n这通常只会在第一次使用时发生。\n\n现在开始？'
    fi
    show_intro_dialog "$intro" "是" || return 0
    launch_webui_chat "$hermes_cmd" || return 0
    show_message $'Hermes 对话界面已经打开。\n\n如果浏览器中出现对话界面，你就可以开始使用。模型 / 渠道配置在浏览器对话里完成。'
}

start_terminal_chat_flow() {
    local hermes_cmd="$1"
    local intro=$'接下来会打开 Terminal 启动 Hermes 终端对话。\n\n这是浏览器对话无法启动时的备用入口。只要终端里出现 Hermes 对话界面，就可以继续使用。\n\n现在改用终端对话吗？'
    show_intro_dialog "$intro" "是" || return 0
    launch_terminal_chat "$hermes_cmd" || return 0
    show_message $'终端对话窗口已经打开。\n\n如果终端中出现 Hermes 对话界面，你就可以继续使用。'
}

handle_action() {
    local action="$1"
    local hermes_cmd="$2"

    case "$action" in
        "开始安装") start_install_flow ;;
        "启动浏览器对话"|"开始第一次对话") start_chat_flow "$hermes_cmd" ;;
        "终端对话") start_terminal_chat_flow "$hermes_cmd" ;;
        "维护与高级选项")
            local picked=""
            picked="$(maintenance_menu)" || return 0
            handle_advanced_action "$picked" "$hermes_cmd"
            ;;
        "__CANCEL__"|"退出") return 1 ;;
        *) show_warning "未识别的操作：$action" ;;
    esac
    return 0
}

main() {
    if [[ "${1:-}" == "--dispatch-action" ]]; then
        ensure_launcher_dirs
        load_session_state
        local hermes_cmd=""
        if hermes_cmd="$(resolve_hermes_command 2>/dev/null)"; then
            ensure_config_scaffold
        else
            hermes_cmd=""
        fi
        case "${2:-}" in
            install) handle_action "开始安装" "$hermes_cmd" ;;
            launch|chat) handle_action "启动浏览器对话" "$hermes_cmd" ;;
            chat_terminal|chat-terminal) handle_action "终端对话" "$hermes_cmd" ;;
            stop_webui|stop-webui) stop_webui_action ;;
            restart_webui|restart-webui) restart_webui_action "$hermes_cmd" ;;
            refresh) exec "$SELF_PATH" ;;
            *) handle_advanced_action "${2:-}" "$hermes_cmd" ;;
        esac
        exit 0
    fi

    if [[ "${1:-}" == "--self-test" ]]; then
        printf 'Version=%s\nHermesHome=%s\nInstallDir=%s\nWebUIPort=%s\nWebUIURL=%s\nNpmPrefix=%s\nNodePortableVersion=%s\nWebUINpmVersion=%s\nBranch=%s\n' \
            "$LAUNCHER_VERSION" "$HERMES_HOME" "$INSTALL_DIR" "$WEBUI_PORT" "$WEBUI_URL" \
            "$NPM_PREFIX" "$NODE_PORTABLE_VERSION" "$WEBUI_NPM_VERSION" "$BRANCH"
        exit 0
    fi

    if [[ "${1:-}" == "--state-test" ]]; then
        print_state_test
        exit 0
    fi

    if [[ "${1:-}" == "--doctor-test" ]]; then
        print_doctor_test
        exit 0
    fi

    if [[ "${1:-}" == "--probe-node" ]]; then
        # Read-only probe (M1): tries phase A only, never downloads.
        if detect_node_runtime; then
            :
        fi
        printf 'node_runtime_kind=%s\nnode_runtime_version=%s\nnode_bin=%s\nnpm_bin=%s\n' \
            "$NODE_RUNTIME_KIND" "$NODE_RUNTIME_VERSION" "$NODE_BIN" "$NPM_BIN"
        exit 0
    fi

    if [[ "${1:-}" == "--install-webui" ]]; then
        # M3 verification flag: ensure runtime + install npm package. Touches network.
        ensure_launcher_dirs
        if ! ensure_node_runtime; then
            exit 1
        fi
        if ! ensure_hermes_web_ui_installed; then
            exit 1
        fi
        printf 'webui_installed=true\nwebui_version=%s\nwebui_bin=%s\n' \
            "$(webui_installed_version 2>/dev/null || true)" "$WEBUI_BIN"
        exit 0
    fi

    if [[ "${1:-}" == "--start-webui" ]]; then
        # Full launch flow: ensure runtime, install/refresh webui, ensure messaging deps,
        # start the daemon, then verify the gateway connected the configured platforms.
        ensure_launcher_dirs
        if ! ensure_node_runtime; then
            exit 1
        fi
        if ! ensure_hermes_web_ui_installed; then
            exit 1
        fi
        # Track A: pure on-demand platform-deps install. Failure here is non-fatal — the daemon
        # still starts; the post-verify (Track B) will surface the resulting mismatch in the UI.
        ensure_gateway_platform_deps || true
        if ! start_hermes_web_ui ""; then
            exit 1
        fi
        # Track B: post-verify connected platforms vs .env. Non-fatal; emits STAGE event for UI banner.
        verify_gateway_platforms_match_env || true
        local token=""
        token="$(read_webui_token 2>/dev/null || true)"
        printf 'webui_running=true\nwebui_url=%s\nwebui_pid=%s\nwebui_token_present=%s\n' \
            "$WEBUI_URL" "$(read_webui_pid 2>/dev/null || true)" "$([[ -n "$token" ]] && echo true || echo false)"
        exit 0
    fi

    if [[ "${1:-}" == "--stop-webui" ]]; then
        stop_hermes_web_ui
        exit 0
    fi

    if [[ "${1:-}" == "--status-webui" ]]; then
        if status_hermes_web_ui; then
            exit 0
        fi
        exit 1
    fi

    if [[ "${1:-}" == "--ensure-platform-deps" ]]; then
        # Track A standalone verification flag. Touches network if any channel needs install.
        ensure_launcher_dirs
        if ensure_gateway_platform_deps; then
            exit 0
        fi
        exit 1
    fi

    if [[ "${1:-}" == "--verify-platforms" ]]; then
        # Track B standalone verification flag. Reads gateway.log + .env, no side effects.
        if verify_gateway_platforms_match_env; then
            exit 0
        fi
        exit 1
    fi

    if [[ "$(uname -s)" != "Darwin" ]]; then
        show_warning "这个启动器只用于 macOS。当前系统不是 macOS。"
        exit 1
    fi

    ensure_launcher_dirs
    load_session_state
    set_last_action "启动器已就绪"

    while true; do
        load_session_state
        local hermes_cmd=""
        if hermes_cmd="$(resolve_hermes_command 2>/dev/null)"; then
            ensure_config_scaffold
        else
            hermes_cmd=""
        fi

        local state=""
        state="$(compute_app_state "$hermes_cmd")"
        maybe_handle_stage_completion "$state"
        state="$(compute_app_state "$hermes_cmd")"

        local prompt=""
        prompt="$(build_dashboard_prompt "$state")"
        local primary_action=""
        primary_action="$(next_primary_action "$state")"
        local primary_key=""
        primary_key="$(next_primary_key "$state")"
        if [[ "${HERMES_USE_LEGACY_UI:-0}" != "1" ]]; then
            if launch_native_ui "$state" "$primary_key"; then
                exit 0
            fi
        fi
        local action=""
        action="$(main_menu "$primary_action" "$prompt")" || exit 0
        handle_action "$action" "$hermes_cmd" || exit 0
    done
}

main "$@"
