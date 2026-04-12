#!/bin/bash

set -uo pipefail

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
LAST_ACTION_SUMMARY="启动器已就绪"

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

show_notification() {
    local title="${1:-$APP_TITLE}"
    local message="$2"
    /usr/bin/osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
}

find_openclaw_sources() {
    local sources=()
    for dir in "$HOME/.openclaw" "$HOME/.clawdbot" "$HOME/.moldbot"; do
        [[ -d "$dir" ]] && sources+=("$dir")
    done
    printf '%s\n' "${sources[@]:-}"
}

check_openclaw_migration() {
    local sources
    sources="$(find_openclaw_sources)"
    if [[ -n "$sources" ]]; then
        show_warning "检测到旧版 OpenClaw/Clawdbot 数据目录：\n$sources\n\n如需迁移数据，请参考官方文档。"
    fi
}

quoted_line() {
    printf "%q" "$1"
}

write_temp_command_script() {
    local payload="$1"
    local title="$2"
    local log_path="${3:-}"
    local script_path
    script_path="/tmp/hermes-launcher-$(date '+%Y%m%d-%H%M%S')-$RANDOM.command"
    cat >"$script_path" <<EOF
#!/bin/bash
export HERMES_HOME=$(quoted_line "$HERMES_HOME")
export HERMES_INSTALL_DIR=$(quoted_line "$INSTALL_DIR")
export PATH=$(quoted_line "$HOME/.local/bin:$PATH")
export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1
printf '\033]0;%s\007' $(printf '%q' "$title")
$( [[ -n "$log_path" ]] && printf 'exec > >(tee -a %s) 2>&1\n' "$(quoted_line "$log_path")" )
$payload
EOF
    chmod +x "$script_path"
    printf '%s\n' "$script_path"
}

ensure_launcher_dirs() {
    mkdir -p "$HERMES_HOME" "$LAUNCHER_LOG_DIR"
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
    printf '%s/%s-%s.log\n' "$LAUNCHER_LOG_DIR" "$(date '+%Y%m%d-%H%M%S')" "$slug"
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

    if [[ ! -f "$HERMES_HOME/SOUL.md" ]]; then
        cat > "$HERMES_HOME/SOUL.md" << 'SOUL'
# Hermes Agent Persona

在这里写入你希望 Hermes 使用的沟通风格。
SOUL
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
    if pgrep -f 'hermes.*gateway$' >/dev/null 2>&1; then
        printf 'true\n'
    elif pgrep -f 'python.*gateway\.run' >/dev/null 2>&1; then
        printf 'true\n'
    else
        printf 'false\n'
    fi
}

build_status_text() {
    local hermes_cmd="$1"
    local installed_text="未检测到 Hermes"
    local model_text="未检测到完整模型配置"
    local gateway_config_text="未检测到消息渠道配置"
    local gateway_runtime_text="当前未运行"

    if is_installed "$hermes_cmd"; then
        installed_text="已检测到 Hermes"
        ensure_config_scaffold
        if [[ "$(test_model_ready)" == "true" ]]; then
            model_text="已检测到 provider 与 API Key"
        fi
        if [[ "$(detect_gateway_configured)" == "true" ]]; then
            gateway_config_text="已检测到消息渠道配置"
        fi
        if [[ "$(detect_gateway_running)" == "true" ]]; then
            gateway_runtime_text="当前正在运行"
        fi
    fi

    cat <<EOF
状态摘要
安装：$installed_text
模型：$model_text
消息渠道：$gateway_config_text
消息网关：$gateway_runtime_text

数据目录：$HERMES_HOME
安装目录：$INSTALL_DIR
Git 分支：$BRANCH
Hermes 命令：${hermes_cmd:-未找到}
最近操作：$LAST_ACTION_SUMMARY
EOF
}

run_in_terminal() {
    local payload="$1"
    local title="$2"
    local log_path="${3:-}"
    local script_path
    script_path="$(write_temp_command_script "$payload" "$title" "$log_path")"
    open -a Terminal "$script_path"
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
        local go_install=""
        go_install="$(prompt_yes_no "当前没有检测到 Hermes。是否现在安装？" "是")" || return 1
        if [[ "$go_install" == "是" ]]; then
            launch_install
        fi
        return 1
    fi
    return 0
}

launch_install() {
    local branch=""
    branch="$(choose_from_list "选择安装分支" "main" "main" "develop" "取消")" || return 0
    [[ "$branch" == "取消" ]] && return 0

    local run_setup=""
    run_setup="$(prompt_yes_no "安装完成后运行 setup 吗？（推荐首次安装选择是）" "是")" || return 0

    local log_path
    log_path="$(build_log_path "install")"
    local payload=""
    payload+="curl -fsSL $(printf '%q' \"$OFFICIAL_INSTALL_URL\") | bash -s -- --branch $(printf '%q' \"$branch\")"
    [[ "$run_setup" != "是" ]] && payload+=" --skip-setup"
    payload+="; INSTALL_EXIT=\\$?; echo; if [[ \\\"\\$INSTALL_EXIT\\\" -eq 0 ]]; then echo '安装流程已结束，可关闭此终端窗口。'; else echo '安装流程失败，请查看上方报错。'; fi; exit \\\"\\$INSTALL_EXIT\\\""

    set_last_action "已启动安装或更新（分支 $branch），日志：$log_path"
    run_in_terminal "$payload" "Hermes 安装或更新" "$log_path"
}

run_hermes_action() {
    local hermes_cmd="$1"
    local label="$2"
    local args="$3"
    local keep_note="${4:-命令执行结束后，可关闭窗口。}"
    require_hermes "$hermes_cmd" || return 0

    local log_path
    log_path="$(build_log_path "$label")"
    local payload=""
    payload+="cd $(printf '%q' "$INSTALL_DIR"); "
    payload+="$(printf '%q' "$hermes_cmd") $args; "
    if [[ -n "$keep_note" ]]; then
        payload+="echo; echo $(printf '%q' "$keep_note")"
    fi

    set_last_action "已启动 $label，日志：$log_path"
    show_notification "$APP_TITLE" "$label 已启动"
    run_in_terminal "$payload" "Hermes $label" "$log_path"
}

configure_model() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "模型配置" "model"
}

configure_provider() {
    local hermes_cmd="$1"
    local env_path="$HERMES_HOME/.env"
    ensure_config_scaffold

    local provider=""
    provider="$(choose_from_list "选择 AI Provider" "openrouter" \
        "openrouter" \
        "anthropic" \
        "openai" \
        "google" \
        "取消")" || return 0
    [[ "$provider" == "取消" ]] && return 0

    local api_key=""
    api_key="$(prompt_text "请输入 $provider 的 API Key：" "")" || return 0
    [[ -z "$api_key" ]] && show_warning "API Key 不能为空。" && return 0

    local key_var=""
    case "$provider" in
        openrouter) key_var="OPENROUTER_API_KEY" ;;
        anthropic)  key_var="ANTHROPIC_API_KEY" ;;
        openai)     key_var="OPENAI_API_KEY" ;;
        google)     key_var="GOOGLE_API_KEY" ;;
    esac

    if [[ -f "$env_path" ]] && grep -q "^${key_var}=" "$env_path" 2>/dev/null; then
        # Update existing line
        local tmp_env
        tmp_env="$(mktemp)"
        sed "s|^${key_var}=.*|${key_var}=${api_key}|" "$env_path" > "$tmp_env"
        mv "$tmp_env" "$env_path"
    else
        printf '%s=%s\n' "$key_var" "$api_key" >> "$env_path"
    fi

    show_message "$provider 的 API Key 已写入 .env 文件。"
    show_notification "$APP_TITLE" "$provider API Key 配置完成"
    set_last_action "已配置 $provider API Key"
}

check_gateway_readiness() {
    local installed="$1"
    if [[ -z "$installed" ]]; then
        show_warning "请先安装 Hermes。"
        return
    fi

    local env_path="$HERMES_HOME/.env"
    local config_path="$HERMES_HOME/config.yaml"
    local report=""

    # Check config
    if [[ -f "$config_path" ]]; then
        if grep -Eq '^[[:space:]]*model[[:space:]]*:' "$config_path" 2>/dev/null; then
            report+="模型配置：已配置\n"
        else
            report+="模型配置：未配置\n"
        fi
    else
        report+="配置文件：不存在\n"
    fi

    # Check API key
    if [[ -f "$env_path" ]] && grep -Eq '^[[:space:]]*[A-Z0-9_]*API_KEY[[:space:]]*=[[:space:]]*[^#[:space:]]+' "$env_path" 2>/dev/null; then
        report+="API Key：已配置\n"
    else
        report+="API Key：未配置\n"
    fi

    # Check messaging platforms
    local platforms_found=0
    for token_var in TELEGRAM_BOT_TOKEN DISCORD_BOT_TOKEN SLACK_BOT_TOKEN; do
        if grep -q "^${token_var}=" "$env_path" 2>/dev/null; then
            platforms_found=$((platforms_found + 1))
        fi
    done
    if [[ $platforms_found -gt 0 ]]; then
        report+="消息渠道：已配置 ($platforms_found 个平台)\n"
    else
        report+="消息渠道：未配置\n"
    fi

    # Check gateway running
    if detect_gateway_running | grep -q "true"; then
        report+="消息网关：正在运行\n"
    else
        report+="消息网关：未运行\n"
    fi

    show_message "$(printf 'Hermes 状态检查：\n\n%b' "$report")"
}

check_launcher_update() {
    local current_dir
    current_dir="$(cd "$(dirname "$0")" && pwd)"
    local remote_url="https://raw.githubusercontent.com/yxxxxx1/hermes-agent-launcher/main/HermesMacGuiLauncher.command"

    local tmp_file
    tmp_file="$(mktemp)"
    if curl -fsSL "$remote_url" -o "$tmp_file" 2>/dev/null; then
        local remote_ver remote_hash local_hash
        remote_hash="$(shasum -a 256 "$tmp_file" | awk '{print $1}')"
        local_hash="$(shasum -a 256 "$current_dir/HermesMacGuiLauncher.command" | awk '{print $1}')"
        rm -f "$tmp_file"

        if [[ "$remote_hash" != "$local_hash" ]]; then
            local do_update=""
            do_update="$(prompt_yes_no "检测到启动器有新版本，是否更新？" "是")" || return 0
            if [[ "$do_update" == "是" ]]; then
                curl -fsSL "$remote_url" -o "$current_dir/HermesMacGuiLauncher.command"
                chmod +x "$current_dir/HermesMacGuiLauncher.command"
                show_message "启动器已更新，请重新打开。"
                exit 0
            fi
        else
            show_message "当前已是最新版本。"
        fi
    else
        show_warning "检查更新失败，请检查网络连接。"
    fi
}

launch_local_chat() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "本地对话" "" ""
}

configure_gateway() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "消息渠道配置" "gateway setup"
}

launch_gateway() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "消息网关" "gateway" "保持这个终端窗口打开，消息渠道才能持续在线。"
}

run_doctor() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "doctor" "doctor"
}

run_update() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "update" "update"
}

run_tools() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "tools" "tools"
}

run_full_setup() {
    local hermes_cmd="$1"
    run_hermes_action "$hermes_cmd" "完整 setup" "setup"
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
    choose_from_list "维护与文件" "运行 doctor" \
        "运行 doctor" \
        "运行 update" \
        "配置 tools" \
        "完整 setup" \
        "打开 config.yaml" \
        "打开 .env" \
        "打开 SOUL.md" \
        "打开日志目录" \
        "打开数据目录" \
        "打开安装目录" \
        "检查启动器更新" \
        "官方文档 / 仓库" \
        "卸载 / 重装" \
        "返回"
}

main_menu() {
    local hermes_cmd="$1"
    local prompt="$2"
    if [[ -z "$hermes_cmd" ]]; then
        prompt+="\n\n⚠ 未检测到 Hermes，请先安装"
    fi
    choose_from_list "$prompt" "安装 / 更新 Hermes" \
        "安装 / 更新 Hermes" \
        "配置 AI Provider" \
        "模型配置" \
        "打开本地对话" \
        "配置消息渠道" \
        "打开消息网关" \
        "状态检查" \
        "维护与文件" \
        "退出"
}

handle_action() {
    local action="$1"
    local hermes_cmd="$2"

    case "$action" in
        "安装 / 更新 Hermes") launch_install ;;
        "配置 AI Provider") configure_provider "$hermes_cmd" ;;
        "模型配置") configure_model "$hermes_cmd" ;;
        "打开本地对话") launch_local_chat "$hermes_cmd" ;;
        "配置消息渠道") configure_gateway "$hermes_cmd" ;;
        "打开消息网关") launch_gateway "$hermes_cmd" ;;
        "状态检查") check_gateway_readiness "$hermes_cmd" ;;
        "维护与文件")
            local picked=""
            picked="$(maintenance_menu)" || return 0
            case "$picked" in
                "运行 doctor") run_doctor "$hermes_cmd" ;;
                "运行 update") run_update "$hermes_cmd" ;;
                "配置 tools") run_tools "$hermes_cmd" ;;
                "完整 setup") run_full_setup "$hermes_cmd" ;;
                "打开 config.yaml") ensure_config_scaffold; open_path "$HERMES_HOME/config.yaml" ;;
                "打开 .env") ensure_config_scaffold; open_path "$HERMES_HOME/.env" ;;
                "打开 SOUL.md") ensure_config_scaffold; open_path "$HERMES_HOME/SOUL.md" ;;
                "打开日志目录") open_path "$HERMES_HOME/logs" ;;
                "打开数据目录") open_path "$HERMES_HOME" ;;
                "打开安装目录") open_path "$INSTALL_DIR" ;;
                "检查启动器更新") check_launcher_update ;;
                "官方文档 / 仓库") open_official_resource ;;
                "卸载 / 重装") uninstall_hermes ;;
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

    if [[ "$(uname -s)" != "Darwin" ]]; then
        show_warning "这个启动器只用于 macOS。当前系统不是 macOS。"
        exit 1
    fi

    ensure_launcher_dirs
    set_last_action "启动器已就绪"

    # First-run detection
    if [[ ! -f "$HERMES_HOME/.launcher_init" ]]; then
        show_message "欢迎使用 Hermes Agent macOS 启动器！\n\n如需安装 Hermes，请选择「安装 / 更新 Hermes」。"
        : >"$HERMES_HOME/.launcher_init"
    fi

    # Check for legacy OpenClaw data
    check_openclaw_migration

    while true; do
        local hermes_cmd=""
        if hermes_cmd="$(resolve_hermes_command 2>/dev/null)"; then
            ensure_config_scaffold
        else
            hermes_cmd=""
        fi

        local prompt=""
        prompt="$(build_status_text "$hermes_cmd")"
        local action=""
        action="$(main_menu "$hermes_cmd" "$prompt")" || exit 0
        handle_action "$action" "$hermes_cmd" || exit 0
    done
}

main "$@"
