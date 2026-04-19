#!/bin/bash

set -euo pipefail

APP_TITLE="Hermes Agent macOS 轻量启动器"
LAUNCHER_VERSION="macOS v2026.04.19.1"
OFFICIAL_INSTALL_URL="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
OFFICIAL_REPO_URL="https://github.com/NousResearch/hermes-agent"
OFFICIAL_DOCS_URL="https://hermes-agent.nousresearch.com/docs/getting-started/installation/"
WEBUI_REPO_URL="https://github.com/nesquena/hermes-webui.git"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_PATH="$SELF_DIR/$(basename "$0")"

DEFAULT_HERMES_HOME="$HOME/.hermes"
DEFAULT_INSTALL_DIR="$DEFAULT_HERMES_HOME/hermes-agent"
DEFAULT_WEBUI_DIR="$DEFAULT_HERMES_HOME/hermes-webui"
DEFAULT_WEBUI_STATE_DIR="$DEFAULT_HERMES_HOME/webui"

HERMES_HOME="${HERMES_HOME:-$DEFAULT_HERMES_HOME}"
INSTALL_DIR="${HERMES_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
WEBUI_DIR="${HERMES_WEBUI_DIR:-$DEFAULT_WEBUI_DIR}"
WEBUI_STATE_DIR="${HERMES_WEBUI_STATE_DIR:-$DEFAULT_WEBUI_STATE_DIR}"
WEBUI_HOST="${HERMES_WEBUI_HOST:-127.0.0.1}"
WEBUI_PORT="${HERMES_WEBUI_PORT:-8787}"
WEBUI_LANGUAGE="${HERMES_WEBUI_LANGUAGE:-zh}"
WEBUI_URL="http://localhost:$WEBUI_PORT"
WEBUI_HEALTH_URL="http://$WEBUI_HOST:$WEBUI_PORT/health"
BRANCH="main"
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
    local installed model_ready
    installed="$(state_get installed "$state")"
    model_ready="$(state_get model_ready "$state")"

    if [[ "$installed" != "true" ]]; then
        printf '继续安装\n'
    elif [[ "$model_ready" != "true" ]]; then
        printf '继续配置模型\n'
    else
        printf '开始第一次对话\n'
    fi
}

next_primary_key() {
    local state="$1"
    local installed model_ready
    installed="$(state_get installed "$state")"
    model_ready="$(state_get model_ready "$state")"

    if [[ "$installed" != "true" ]]; then
        printf 'install\n'
    elif [[ "$model_ready" != "true" ]]; then
        printf 'model\n'
    else
        printf 'chat\n'
    fi
}

ui_status_class() {
    case "$1" in
        "已完成") printf 'complete\n' ;;
        "进行中"|"待完成"|"可以开始") printf 'active\n' ;;
        *) printf 'muted\n' ;;
    esac
}

write_native_ui_html() {
    local state="$1"
    local primary_key="$2"
    local html_path="$3"
    local installed model_ready gateway_configured gateway_running
    local install_line model_line chat_line gateway_line support_line current_step primary_copy
    local install_class model_class chat_class

    installed="$(state_get installed "$state")"
    model_ready="$(state_get model_ready "$state")"
    gateway_configured="$(state_get gateway_configured "$state")"
    gateway_running="$(state_get gateway_running "$state")"

    install_line="未开始"
    model_line="等待安装完成"
    chat_line="尚不可用"
    gateway_line="暂未配置"
    support_line="日常使用暂不需要"
    current_step="继续安装"
    primary_copy="$(ui_primary_copy "$state")"

    if [[ "$LAST_STAGE" == "install" && "$LAST_RESULT" == "running" ]]; then
        install_line="进行中"
    elif [[ "$installed" == "true" ]]; then
        install_line="已完成"
    fi

    if [[ "$installed" == "true" && "$model_ready" == "false" ]]; then
        model_line="待完成"
    fi
    if [[ "$LAST_STAGE" == "model" && "$LAST_RESULT" == "running" ]]; then
        model_line="进行中"
    elif [[ "$model_ready" == "true" ]]; then
        model_line="已完成"
        chat_line="可以开始"
    fi

    if [[ "$gateway_configured" == "true" ]]; then
        gateway_line="已配置"
        if [[ "$gateway_running" == "true" ]]; then
            gateway_line="已配置，当前在线"
        fi
    fi

    if [[ "$installed" != "true" ]]; then
        current_step="继续安装"
    elif [[ "$model_ready" != "true" ]]; then
        current_step="继续配置模型"
    else
        current_step="开始第一次对话"
        support_line="可选，用于维护与消息渠道"
    fi

    install_class="$(ui_status_class "$install_line")"
    model_class="$(ui_status_class "$model_line")"
    chat_class="$(ui_status_class "$chat_line")"

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
      grid-template-columns: repeat(3, 1fr);
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
        <p>把运行环境和命令入口准备好。完成后，启动器会自动引导你进入模型配置。</p>
      </article>
      <article class="stage">
        <div class="stage-top">
          <span class="stage-index">Stage 02</span>
          <span class="pill $model_class">$(html_escape "$model_line")</span>
        </div>
        <h2>配置模型</h2>
        <p>选择 provider 和默认模型。只要配置完成，后面的浏览器对话就可以直接开始。</p>
      </article>
      <article class="stage">
        <div class="stage-top">
          <span class="stage-index">Stage 03</span>
          <span class="pill $chat_class">$(html_escape "$chat_line")</span>
        </div>
        <h2>开始第一次对话</h2>
        <p>打开浏览器里的 Hermes WebUI。看到对话入口，就表示这套环境已经可以用了。</p>
      </article>
    </section>

    <section class="meta-grid">
      <section class="panel surface">
        <h3>当前状态</h3>
        <div class="list">
          <div class="row">
            <div class="row-label">消息渠道</div>
            <div class="row-value">$(html_escape "$gateway_line")</div>
          </div>
          <div class="row">
            <div class="row-label">维护入口</div>
            <div class="row-value">$(html_escape "$support_line")</div>
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
          <p class="fineprint">这些动作留给维护、排查和消息渠道配置。首次使用时，一般不需要先进入这里。</p>
        </div>
        <div class="maintenance-grid">
          <button data-action="doctor">诊断问题</button>
          <button data-action="update">更新 Hermes</button>
          <button data-action="setup">重新执行完整设置</button>
          <button data-action="tools">配置 tools</button>
          <button data-action="gateway_setup">配置消息渠道</button>
          <button data-action="gateway_run">打开消息网关</button>
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

test_model_ready() {
    local config_path="$HERMES_HOME/config.yaml"
    local env_path="$HERMES_HOME/.env"
    local auth_path="$HERMES_HOME/auth.json"
    local has_model="false"
    local has_api="false"

    if [[ -f "$config_path" ]]; then
        if grep -Eq '^[[:space:]]*model[[:space:]]*:' "$config_path" && grep -Eq '^[[:space:]]+default[[:space:]]*:[[:space:]]*\S+' "$config_path"; then
            has_model="true"
        elif grep -Eq '^[[:space:]]+model[[:space:]]*:[[:space:]]*\S+' "$config_path"; then
            has_model="true"
        fi
    fi

    if [[ -f "$env_path" ]] && grep -Eq '^[[:space:]]*[A-Z0-9_]*API_KEY[[:space:]]*=[[:space:]]*[^#[:space:]]+' "$env_path"; then
        has_api="true"
    fi

    if [[ "$has_api" != "true" && -f "$auth_path" ]] && command -v python3 >/dev/null 2>&1; then
        if python3 - "$auth_path" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, 'r', encoding='utf-8'))
    provider = data.get('active_provider')
    entry = (data.get('providers') or {}).get(provider or '', {})
    ok = any(entry.get(k) for k in ('access_token', 'agent_key', 'api_key', 'refresh_token'))
    sys.exit(0 if ok else 1)
except Exception:
    sys.exit(1)
PY
        then
            has_api="true"
        fi
    fi

    if [[ "$has_model" == "true" && "$has_api" == "true" ]]; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

detect_gateway_configured() {
    local env_path="$HERMES_HOME/.env"
    if [[ ! -f "$env_path" ]]; then
        printf 'false\n'
        return
    fi

    if grep -Eq '^[[:space:]]*(TELEGRAM_BOT_TOKEN|DISCORD_BOT_TOKEN|SLACK_BOT_TOKEN|WEIXIN_ACCOUNT_ID|WHATSAPP_ENABLED|MATRIX_HOMESERVER_URL|DINGTALK_CLIENT_ID|FEISHU_APP_ID|WECOM_BOT_ID|BLUEBUBBLES_SERVER_URL)[[:space:]]*=' "$env_path"; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

detect_gateway_running() {
    if pgrep -af 'hermes.*gateway|venv/bin/python.*gateway|python.*gateway.run' >/dev/null 2>&1; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

detect_webui_installed() {
    if [[ -f "$WEBUI_DIR/bootstrap.py" && -f "$WEBUI_DIR/server.py" ]]; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

find_webui_python() {
    if [[ -n "${HERMES_WEBUI_PYTHON:-}" && -x "${HERMES_WEBUI_PYTHON:-}" ]]; then
        printf '%s\n' "$HERMES_WEBUI_PYTHON"
        return 0
    fi

    local candidates=(
        "$INSTALL_DIR/venv/bin/python"
        "$WEBUI_DIR/.venv/bin/python"
        "$WEBUI_DIR/venv/bin/python"
    )
    local candidate=""
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return 0
    fi

    if command -v python >/dev/null 2>&1; then
        command -v python
        return 0
    fi

    return 1
}

webui_health_check() {
    local python_cmd=""
    python_cmd="$(find_webui_python 2>/dev/null || true)"
    if [[ -z "$python_cmd" ]]; then
        return 1
    fi

    "$python_cmd" - "$WEBUI_HEALTH_URL" <<'PY'
import sys
import urllib.request

url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=1.5) as response:
        body = response.read()
    raise SystemExit(0 if b'"status": "ok"' in body else 1)
except Exception:
    raise SystemExit(1)
PY
}

is_webui_port_listening() {
    lsof -nP -iTCP:"$WEBUI_PORT" -sTCP:LISTEN >/dev/null 2>&1
}

set_webui_port() {
    WEBUI_PORT="$1"
    WEBUI_URL="http://localhost:$WEBUI_PORT"
    WEBUI_HEALTH_URL="http://$WEBUI_HOST:$WEBUI_PORT/health"
}

select_webui_port_for_launch() {
    local log_path="$1"
    local base_port="$WEBUI_PORT"
    local candidate=""

    for candidate in $(seq "$base_port" $((base_port + 9))); do
        set_webui_port "$candidate"
        if webui_health_check; then
            if [[ "$(detect_webui_installed)" == "true" ]]; then
                echo "发现可用的 Hermes 对话服务：$WEBUI_URL" >>"$log_path"
                return 0
            fi
            echo "端口 $WEBUI_PORT 已有服务响应，但不是启动器管理的对话界面，尝试下一个端口。" >>"$log_path"
            continue
        fi
        if is_webui_port_listening; then
            echo "端口 $WEBUI_PORT 已被其他服务占用，尝试下一个端口。" >>"$log_path"
            continue
        fi
        echo "选择端口 $WEBUI_PORT 启动 Hermes 对话服务。" >>"$log_path"
        return 0
    done

    set_webui_port "$base_port"
    echo "端口 $base_port-$((base_port + 9)) 都不可用，无法启动 Hermes 对话服务。" >>"$log_path"
    return 1
}

wait_for_webui_health() {
    local timeout="${1:-45}"
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

compute_app_state() {
    local hermes_cmd="$1"
    local installed="false"
    local model_ready="false"
    local gateway_configured="false"
    local gateway_running="false"
    local webui_installed="false"
    local webui_running="false"

    if is_installed "$hermes_cmd"; then
        installed="true"
        ensure_config_scaffold
        if [[ "$(test_model_ready)" == "true" ]]; then
            model_ready="true"
        fi
        if [[ "$(detect_gateway_configured)" == "true" ]]; then
            gateway_configured="true"
        fi
        if [[ "$(detect_gateway_running)" == "true" ]]; then
            gateway_running="true"
        fi
        if [[ "$(detect_webui_installed)" == "true" ]]; then
            webui_installed="true"
        fi
        if [[ "$(detect_webui_running)" == "true" ]]; then
            webui_running="true"
        fi
    fi

    cat <<EOF
installed=$installed
model_ready=$model_ready
gateway_configured=$gateway_configured
gateway_running=$gateway_running
webui_installed=$webui_installed
webui_running=$webui_running
webui_url=$WEBUI_URL
EOF
}

build_dashboard_prompt() {
    local state="$1"
    local installed model_ready gateway_configured gateway_running
    installed="$(state_get installed "$state")"
    model_ready="$(state_get model_ready "$state")"
    gateway_configured="$(state_get gateway_configured "$state")"
    gateway_running="$(state_get gateway_running "$state")"

    local install_line="未开始"
    local model_line="等待安装完成"
    local chat_line="尚不可用"
    local gateway_line="暂未配置"
    local current_step="继续安装"
    local support_line="日常使用暂不需要"

    if [[ "$LAST_STAGE" == "install" && "$LAST_RESULT" == "running" ]]; then
        install_line="进行中"
    elif [[ "$installed" == "true" ]]; then
        install_line="已完成"
    fi

    if [[ "$installed" == "true" && "$model_ready" == "false" ]]; then
        model_line="待完成"
    fi
    if [[ "$LAST_STAGE" == "model" && "$LAST_RESULT" == "running" ]]; then
        model_line="进行中"
    elif [[ "$model_ready" == "true" ]]; then
        model_line="已完成"
        chat_line="可以开始"
    fi

    if [[ "$gateway_configured" == "true" ]]; then
        gateway_line="已配置"
        if [[ "$gateway_running" == "true" ]]; then
            gateway_line="已配置，当前在线"
        fi
    fi

    if [[ "$installed" != "true" ]]; then
        current_step="继续安装"
    elif [[ "$model_ready" != "true" ]]; then
        current_step="继续配置模型"
    else
        current_step="开始第一次对话"
        support_line="可选，用于维护与消息渠道"
    fi

    cat <<EOF
Hermes macOS 启动器

当前步骤：$current_step
版本：$LAUNCHER_VERSION

阶段总览
1. 安装 Hermes     $install_line
2. 配置模型        $model_line
3. 开始第一次对话  $chat_line

消息渠道：$gateway_line
维护入口：$support_line

数据目录：$HERMES_HOME
最近操作：$LAST_ACTION_SUMMARY

只处理当前这一步即可，其余内容稍后再看。
EOF
}

next_primary_action() {
    local state="$1"
    local installed model_ready
    installed="$(state_get installed "$state")"
    model_ready="$(state_get model_ready "$state")"

    if [[ "$installed" != "true" ]]; then
        printf '开始安装\n'
    elif [[ "$model_ready" != "true" ]]; then
        printf '配置模型\n'
    else
        printf '开始第一次对话\n'
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
    local installed model_ready
    installed="$(state_get installed "$state")"
    model_ready="$(state_get model_ready "$state")"

    if [[ "$LAST_RESULT" == "running" || "$LAST_RESULT" == "idle" ]]; then
        return 0
    fi

    case "$LAST_STAGE" in
        install)
            if [[ "$LAST_RESULT" == "success" && "$installed" == "true" ]]; then
                show_message "安装已完成。\n\n下一步继续配置模型。完成后，你就可以开始和 Hermes 对话。"
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
        model)
            if [[ "$LAST_RESULT" == "success" && "$model_ready" == "true" ]]; then
                show_message "模型配置已完成。\n\n现在可以开始第一次对话。"
                set_stage_state "none" "idle" "$LAST_LOG_PATH"
            else
                local picked=""
                picked="$(prompt_failure_action "还没有检测到完整模型配置。\n\n如果配置流程已经结束，可以重新打开它，或先查看日志。")" || return 0
                case "$picked" in
                    "重新尝试") set_stage_state "none" "idle" "$LAST_LOG_PATH"; start_model_flow "$(resolve_hermes_command 2>/dev/null || true)" ;;
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

configure_model() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "模型配置" "model" "命令执行结束后，可关闭窗口。" "model" "true" "TERM=dumb NO_COLOR=1 COLORTERM="
}

launch_terminal_chat() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "终端对话" "chat" "" "" "false"
}

ensure_webui_checkout() {
    local log_path="$1"

    mkdir -p "$(dirname "$WEBUI_DIR")" "$WEBUI_STATE_DIR"

    if [[ -f "$WEBUI_DIR/bootstrap.py" && -f "$WEBUI_DIR/server.py" ]]; then
        return 0
    fi

    if [[ -e "$WEBUI_DIR" ]]; then
        {
            echo "Hermes WebUI 目录已存在，但没有检测到 bootstrap.py/server.py：$WEBUI_DIR"
            echo "请移动或删除这个目录后重试。"
        } >>"$log_path"
        return 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "没有检测到 git，无法自动下载 Hermes WebUI。" >>"$log_path"
        return 1
    fi

    echo "正在下载 Hermes WebUI：$WEBUI_REPO_URL" >>"$log_path"
    git clone --depth 1 "$WEBUI_REPO_URL" "$WEBUI_DIR" >>"$log_path" 2>&1
}

ensure_webui_default_language() {
    local log_path="$1"
    local python_cmd=""
    python_cmd="$(find_webui_python 2>/dev/null || true)"
    if [[ -z "$python_cmd" ]]; then
        echo "没有检测到可用的 Python，暂时无法写入 WebUI 默认语言。" >>"$log_path"
        return 0
    fi

    mkdir -p "$WEBUI_STATE_DIR"
    "$python_cmd" - "$WEBUI_STATE_DIR/settings.json" "$WEBUI_LANGUAGE" >>"$log_path" 2>&1 <<'PY'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1]).expanduser()
language = sys.argv[2]
settings = {}
if settings_path.exists():
    try:
        loaded = json.loads(settings_path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            settings = loaded
    except Exception:
        settings = {}

current = settings.get("language")
if current in (None, "", "en"):
    settings["language"] = language
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings_path.write_text(
        json.dumps(settings, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"WebUI default language set to {language}")
else:
    print(f"WebUI language preserved as {current}")
PY
}

prepare_webui_checkout() {
    local log_path="$1"

    if ensure_webui_checkout "$log_path"; then
        ensure_webui_default_language "$log_path"
        return 0
    fi

    return 1
}

start_webui_server() {
    local log_path="$1"
    local python_cmd=""

    python_cmd="$(find_webui_python 2>/dev/null || true)"
    if [[ -z "$python_cmd" ]]; then
        echo "没有检测到可用的 Python，无法启动 Hermes WebUI。" >>"$log_path"
        return 1
    fi

    {
        echo
        echo "[$(timestamp_now)] 启动 Hermes WebUI"
        echo "WebUI directory: $WEBUI_DIR"
        echo "Agent directory: $INSTALL_DIR"
        echo "State directory: $WEBUI_STATE_DIR"
        echo "Default language: $WEBUI_LANGUAGE"
        echo "URL: $WEBUI_URL"
    } >>"$log_path"

    (
        cd "$WEBUI_DIR"
        HERMES_HOME="$HERMES_HOME" \
        HERMES_CONFIG_PATH="$HERMES_HOME/config.yaml" \
        HERMES_WEBUI_AGENT_DIR="$INSTALL_DIR" \
        HERMES_WEBUI_STATE_DIR="$WEBUI_STATE_DIR" \
        HERMES_WEBUI_HOST="$WEBUI_HOST" \
        HERMES_WEBUI_PORT="$WEBUI_PORT" \
        HERMES_WEBUI_LANGUAGE="$WEBUI_LANGUAGE" \
        "$python_cmd" "$WEBUI_DIR/bootstrap.py" --no-browser --skip-agent-install --host "$WEBUI_HOST" "$WEBUI_PORT"
    ) >>"$log_path" 2>&1 &

    local server_pid=$!
    echo "Hermes 对话服务进程已启动，PID: $server_pid" >>"$log_path"
    disown "$server_pid" 2>/dev/null || true
}

open_webui_browser() {
    open "$WEBUI_URL"
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
    set_last_action "正在打开 Hermes WebUI，日志：$log_path"
    set_stage_state "chat" "running" "$log_path"

    if [[ "$(detect_webui_installed)" == "true" ]]; then
        ensure_webui_default_language "$log_path"
    fi

    if ! select_webui_port_for_launch "$log_path"; then
        set_last_action "Hermes 对话界面端口不可用，日志：$log_path"
        set_stage_state "chat" "failed" "$log_path"
        handle_webui_launch_failure "$log_path" "Hermes 对话界面暂时无法启动。\n\n端口 $WEBUI_PORT 附近都被占用或不可用。你可以关闭旧的 Hermes/WebUI 进程后重试。" "$hermes_cmd"
        return 1
    fi

    if webui_health_check; then
        open_webui_browser
        set_last_action "已打开 Hermes WebUI：$WEBUI_URL"
        set_stage_state "chat" "success" "$log_path"
        return 0
    fi

    if ! ensure_webui_checkout "$log_path"; then
        set_last_action "Hermes WebUI 准备失败，日志：$log_path"
        set_stage_state "chat" "failed" "$log_path"
        handle_webui_launch_failure "$log_path" "Hermes 对话界面没有准备成功。" "$hermes_cmd"
        return 1
    fi

    ensure_webui_default_language "$log_path"

    if ! start_webui_server "$log_path"; then
        set_last_action "Hermes WebUI 启动失败，日志：$log_path"
        set_stage_state "chat" "failed" "$log_path"
        handle_webui_launch_failure "$log_path" "Hermes 对话界面没有启动成功。" "$hermes_cmd"
        return 1
    fi

    if ! wait_for_webui_health 10; then
        set_last_action "Hermes WebUI 健康检查失败，日志：$log_path"
        set_stage_state "chat" "failed" "$log_path"
        handle_webui_launch_failure "$log_path" "Hermes 对话界面已尝试启动，但暂时没有进入可用状态。" "$hermes_cmd"
        return 1
    fi

    open_webui_browser
    set_last_action "已打开 Hermes WebUI：$WEBUI_URL"
    set_stage_state "chat" "success" "$log_path"
}

configure_gateway() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "消息渠道配置" "gateway setup" "命令执行结束后，可关闭窗口。" "" "true"
}

launch_gateway() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "消息网关" "gateway" "保持这个终端窗口打开，消息渠道才能持续在线。" "" "true"
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
        "配置消息渠道"|gateway_setup) configure_gateway "$hermes_cmd" ;;
        "打开消息网关"|gateway_run) launch_gateway "$hermes_cmd" ;;
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
        "配置消息渠道" \
        "打开消息网关" \
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

start_model_flow() {
    local hermes_cmd="$1"
    local intro=$'接下来会打开 Terminal 进入模型配置。\n\n如果你已经准备好 API Key，整个过程会更顺利。打开后按提示完成即可。\n\n现在继续配置模型吗？'
    show_intro_dialog "$intro" "是" || return 0
    configure_model "$hermes_cmd" || return 0
    show_message $'模型配置窗口已经打开。\n\n完成后回到这里，启动器会继续引导你开始第一次对话。'
}

start_chat_flow() {
    local hermes_cmd="$1"
    local intro=""
    if webui_health_check; then
        launch_webui_chat "$hermes_cmd" || return 0
        return 0
    elif [[ "$(detect_webui_installed)" == "true" ]]; then
        launch_webui_chat "$hermes_cmd" || return 0
        return 0
    else
        intro=$'接下来会先准备 Hermes 对话界面，然后自动打开浏览器。\n\n这通常只会在第一次使用时发生，可能需要下载必要文件并准备 Python 依赖。\n\n现在开始和 Hermes 对话吗？'
    fi
    show_intro_dialog "$intro" "是" || return 0
    launch_webui_chat "$hermes_cmd" || return 0
    show_message $'Hermes 对话界面已经打开。\n\n如果浏览器中出现对话界面，你就已经完成首次可用配置。'
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
        "配置模型") start_model_flow "$hermes_cmd" ;;
        "开始第一次对话") start_chat_flow "$hermes_cmd" ;;
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
            model) handle_action "配置模型" "$hermes_cmd" ;;
            chat) handle_action "开始第一次对话" "$hermes_cmd" ;;
            chat_terminal|chat-terminal) handle_action "终端对话" "$hermes_cmd" ;;
            refresh) exec "$SELF_PATH" ;;
            *) handle_advanced_action "${2:-}" "$hermes_cmd" ;;
        esac
        exit 0
    fi

    if [[ "${1:-}" == "--self-test" ]]; then
        printf 'Version=%s\nHermesHome=%s\nInstallDir=%s\nWebUIDir=%s\nWebUIURL=%s\nWebUILanguage=%s\nBranch=%s\n' "$LAUNCHER_VERSION" "$HERMES_HOME" "$INSTALL_DIR" "$WEBUI_DIR" "$WEBUI_URL" "$WEBUI_LANGUAGE" "$BRANCH"
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
