#!/bin/bash

set -euo pipefail

APP_TITLE="Hermes Agent macOS 轻量启动器"
OFFICIAL_INSTALL_URL="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
OFFICIAL_REPO_URL="https://github.com/NousResearch/hermes-agent"
OFFICIAL_DOCS_URL="https://hermes-agent.nousresearch.com/docs/getting-started/installation/"

DEFAULT_HERMES_HOME="$HOME/.hermes"
DEFAULT_INSTALL_DIR="$DEFAULT_HERMES_HOME/hermes-agent"

HERMES_HOME="${HERMES_HOME:-$DEFAULT_HERMES_HOME}"
INSTALL_DIR="${HERMES_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
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
# Launcher sessions run inside Terminal.app; override inherited non-interactive
# values from the parent shell so curses/prompt_toolkit UIs render correctly.
if [[ -z "\${TERM:-}" || "\${TERM:-}" == "dumb" ]]; then
export TERM=xterm-256color
fi
export COLORTERM=truecolor
unset NO_COLOR
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

compute_app_state() {
    local hermes_cmd="$1"
    local installed="false"
    local model_ready="false"
    local gateway_configured="false"
    local gateway_running="false"

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
    fi

    cat <<EOF
installed=$installed
model_ready=$model_ready
gateway_configured=$gateway_configured
gateway_running=$gateway_running
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

    cat <<EOF
Hermes 设置进度

1. 安装 Hermes：$install_line
2. 配置模型：$model_line
3. 开始对话：$chat_line

消息渠道：$gateway_line

数据目录：$HERMES_HOME
最近操作：$LAST_ACTION_SUMMARY

只需要完成当前高亮的下一步即可。
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
                show_message "Hermes 已安装完成。\n\n下一步请继续配置模型，完成后就可以开始第一次对话。"
                set_stage_state "none" "idle" "$LAST_LOG_PATH"
            else
                local picked=""
                picked="$(prompt_failure_action "安装步骤还没有完成。\n\n如果终端窗口已经报错或结束，可以选择重试，或者先打开日志查看原因。")" || return 0
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
                picked="$(prompt_failure_action "还没有检测到完整模型配置。\n\n如果终端窗口已经结束，可以重新打开配置，或者先查看日志。")" || return 0
                case "$picked" in
                    "重新尝试") set_stage_state "none" "idle" "$LAST_LOG_PATH"; start_model_flow "$(resolve_hermes_command 2>/dev/null || true)" ;;
                    "打开日志") open_path "$LAST_LOG_PATH"; set_stage_state "none" "idle" "$LAST_LOG_PATH" ;;
                    *) set_stage_state "none" "idle" "$LAST_LOG_PATH" ;;
                esac
            fi
            ;;
        chat)
            if [[ "$LAST_RESULT" == "success" ]]; then
                show_message "本地对话入口已经启动。\n\n如果终端里已经出现 Hermes 对话界面，就说明你可以开始使用了。"
            elif [[ -n "$LAST_LOG_PATH" ]]; then
                local picked=""
                picked="$(prompt_failure_action "本地对话入口没有正常启动。\n\n你可以重新尝试，或者先打开日志查看原因。")" || return 0
                case "$picked" in
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
    require_hermes "$hermes_cmd" || return 0

    local log_path
    log_path="$(build_log_path "$label")"
    local payload=""
    payload+="cd $(printf '%q' "$INSTALL_DIR"); "
    if [[ "$capture_output" != "true" && -n "$log_path" ]]; then
        payload+="printf '%s %s\n' $(printf '%q' "[$(timestamp_now)]") $(printf '%q' "启动 $label") >> $(printf '%q' "$log_path"); "
    fi
    payload+="if $(printf '%q' "$hermes_cmd") $args; then CMD_EXIT=0; else CMD_EXIT=\$?; fi; "
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
    run_hermes_action "$hermes_cmd" "模型配置" "model" "命令执行结束后，可关闭窗口。" "model" "true"
}

launch_local_chat() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "本地对话" "chat" "" "chat" "false"
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

open_official_resource() {
    local picked=""
    picked="$(choose_from_list "选择要打开的官方资源。" "官方文档" "官方文档" "官方仓库" "返回")" || return 0
    case "$picked" in
        "官方文档") open "$OFFICIAL_DOCS_URL" ;;
        "官方仓库") open "$OFFICIAL_REPO_URL" ;;
        *) ;;
    esac
}

maintenance_menu() {
    choose_from_list "高级选项" "诊断问题（doctor）" \
        "诊断问题（doctor）" \
        "更新 Hermes" \
        "重新执行完整设置" \
        "配置 tools" \
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
        "高级选项" \
        "退出"
}

start_install_flow() {
    local intro="接下来会打开一个终端窗口完成安装。\n\n这是正常现象，请不要手动关闭终端。\n安装过程可能持续几分钟。\n\n现在开始安装吗？"
    show_intro_dialog "$intro" "是" || return 0
    launch_install || return 0
    show_message "安装终端已经打开。\n\n请等待终端完成安装；如果稍后出错，可以回到启动器查看日志或重新尝试。"
}

start_model_flow() {
    local hermes_cmd="$1"
    local intro="接下来会打开终端进入模型配置流程。\n\n如果你已经准备好了 API Key，配置会更顺利。\n终端窗口打开后请按提示完成配置。\n\n现在开始配置模型吗？"
    show_intro_dialog "$intro" "是" || return 0
    configure_model "$hermes_cmd" || return 0
    show_message "模型配置终端已经打开。\n\n完成后重新回到启动器，系统会继续引导你开始第一次对话。"
}

start_chat_flow() {
    local hermes_cmd="$1"
    local intro="接下来会打开终端启动 Hermes 本地对话入口。\n\n如果成功看到对话入口，说明安装和基础配置已经可以使用。\n\n现在开始第一次对话吗？"
    show_intro_dialog "$intro" "是" || return 0
    launch_local_chat "$hermes_cmd" || return 0
    show_message "本地对话入口已经打开。\n\n如果终端中出现 Hermes 对话界面，就说明你已经完成了首次可用配置。"
}

handle_action() {
    local action="$1"
    local hermes_cmd="$2"

    case "$action" in
        "开始安装") start_install_flow ;;
        "配置模型") start_model_flow "$hermes_cmd" ;;
        "开始第一次对话") start_chat_flow "$hermes_cmd" ;;
        "高级选项")
            local picked=""
            picked="$(maintenance_menu)" || return 0
            case "$picked" in
                "诊断问题（doctor）") run_doctor "$hermes_cmd" ;;
                "更新 Hermes") run_update "$hermes_cmd" ;;
                "重新执行完整设置") run_full_setup "$hermes_cmd" ;;
                "配置 tools") run_tools "$hermes_cmd" ;;
                "配置消息渠道") configure_gateway "$hermes_cmd" ;;
                "打开消息网关") launch_gateway "$hermes_cmd" ;;
                "打开配置文件 config.yaml") ensure_config_scaffold; open_path "$HERMES_HOME/config.yaml" ;;
                "打开环境变量 .env") ensure_config_scaffold; open_path "$HERMES_HOME/.env" ;;
                "打开日志目录") open_path "$HERMES_HOME/logs" ;;
                "打开数据目录") open_path "$HERMES_HOME" ;;
                "打开安装目录") open_path "$INSTALL_DIR" ;;
                "官方文档 / 仓库") open_official_resource ;;
                "卸载 Hermes") uninstall_hermes ;;
                *) ;;
            esac
            ;;
        "__CANCEL__"|"退出") return 1 ;;
        *) show_warning "未识别的操作：$action" ;;
    esac
    return 0
}

main() {
    if [[ "${1:-}" == "--self-test" ]]; then
        printf 'HermesHome=%s\nInstallDir=%s\nBranch=%s\n' "$HERMES_HOME" "$INSTALL_DIR" "$BRANCH"
        exit 0
    fi

    if [[ "${1:-}" == "--state-test" ]]; then
        print_state_test
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
        local action=""
        action="$(main_menu "$primary_action" "$prompt")" || exit 0
        handle_action "$action" "$hermes_cmd" || exit 0
    done
}

main "$@"
