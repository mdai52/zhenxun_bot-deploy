#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.0.0"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
case "$SCRIPT_SOURCE" in
    /dev/fd/*|/proc/*/fd/*) ;;
    *)
        if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
            SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
        fi
        ;;
esac
SERVICE_NAME="zhenxun-bot"
SERVICE_USER="${ZHENXUN_USER:-zhenxun}"
SERVICE_GROUP="${ZHENXUN_GROUP:-zhenxun}"
CONFIG_FILE="/etc/zhenxun-bot-deploy.conf"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DEFAULT_WORK_DIR="/opt/zhenxun"
WORK_DIR="${ZHENXUN_WORK_DIR:-$DEFAULT_WORK_DIR}"
GITHUB_REPO="${ZHENXUN_REPO:-https://github.com/zhenxun-org/zhenxun_bot.git}"
INIT_CODEUP_URL="https://raw.githubusercontent.com/zhenxun-org/zhenxun_bot-deploy/master/init_codeup.py"
INIT_CODEUP_HELPER=""
PYPI_INDEX="${UV_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple}"
PYTHON_BIN=""
UV_BIN=""

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
export PYTHONUNBUFFERED=1
export UV_LINK_MODE=copy

if [[ -t 1 ]]; then
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    RED=$'\033[31m'
    RESET=$'\033[0m'
else
    GREEN=""
    YELLOW=""
    RED=""
    RESET=""
fi

info() {
    printf '%s[信息]%s %s\n' "$GREEN" "$RESET" "$1"
}

warn() {
    printf '%s[注意]%s %s\n' "$YELLOW" "$RESET" "$1"
}

error() {
    printf '%s[错误]%s %s\n' "$RED" "$RESET" "$1" >&2
}

die() {
    error "$1"
    exit 1
}

pause_manager() {
    printf '\n'
    read -r -p "按回车键继续..." _ || true
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local answer=""
    local suffix="[Y/n]"

    [[ "$default" == "n" ]] && suffix="[y/N]"
    read -r -p "$prompt $suffix: " answer || answer=""
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

require_root() {
    [[ "$EUID" -eq 0 ]] || die "请使用 root 账号运行，或执行 sudo bash install.sh。"
}

require_systemd() {
    command -v systemctl >/dev/null 2>&1 || die "未检测到 systemctl，本脚本需要 systemd。"
    [[ -d /run/systemd/system ]] || die "当前系统没有运行 systemd，无法管理真寻服务。"
}

refresh_paths() {
    WORK_DIR="${WORK_DIR%/}"
    BOT_DIR="${WORK_DIR}/zhenxun_bot"
    TOOL_DIR="${WORK_DIR}/.tools"
    UV_TOOL_DIR="${TOOL_DIR}/uv"
    VENV_PYTHON="${BOT_DIR}/.venv/bin/python"
}

load_config() {
    if [[ -r "$CONFIG_FILE" && -z "${ZHENXUN_WORK_DIR:-}" ]]; then
        # 该文件由 root 写入，仅包含 WORK_DIR。
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
    refresh_paths
}

save_config() {
    printf 'WORK_DIR=%q\n' "$WORK_DIR" >"$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE"
}

choose_work_dir() {
    local input=""
    printf '\n'
    info "真寻将安装到：$WORK_DIR"
    read -r -p "请输入安装目录，直接回车保持不变: " input || input=""
    if [[ -n "$input" ]]; then
        WORK_DIR="$input"
    fi
    [[ "$WORK_DIR" == /* ]] || die "安装目录必须是绝对路径。"
    refresh_paths
    save_config
}

check_architecture() {
    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64) return 0 ;;
        *) die "暂不支持当前 CPU 架构：$(uname -m)。" ;;
    esac
}

detect_distribution() {
    [[ -r /etc/os-release ]] || die "无法识别 Linux 发行版：缺少 /etc/os-release。"
    # shellcheck source=/dev/null
    source /etc/os-release
    DISTRO_ID="${ID,,}"
    DISTRO_LIKE="${ID_LIKE:-}"

    case " $DISTRO_ID $DISTRO_LIKE " in
        *debian*|*ubuntu*) DISTRO_FAMILY="debian" ;;
        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) DISTRO_FAMILY="rhel" ;;
        *arch*) DISTRO_FAMILY="arch" ;;
        *) die "暂不支持当前发行版：${PRETTY_NAME:-$DISTRO_ID}。" ;;
    esac
}

install_system_dependencies() {
    detect_distribution
    info "正在安装 Git、FFmpeg、字体和基础运行库..."

    case "$DISTRO_FAMILY" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends \
                ca-certificates curl git ffmpeg fontconfig \
                fonts-noto-cjk fonts-noto-color-emoji \
                build-essential pkg-config util-linux nano
            ;;
        rhel)
            local package_manager="dnf"
            command -v dnf >/dev/null 2>&1 || package_manager="yum"
            "$package_manager" install -y \
                ca-certificates curl git fontconfig \
                gcc gcc-c++ make pkgconf-pkg-config util-linux nano
            "$package_manager" install -y ffmpeg || warn "未能自动安装 FFmpeg，请稍后手动安装。"
            "$package_manager" install -y google-noto-sans-cjk-fonts google-noto-emoji-color-fonts \
                || warn "未能自动安装 Noto 字体，请稍后手动安装中文字体。"
            ;;
        arch)
            pacman -Sy --needed --noconfirm \
                ca-certificates curl git ffmpeg fontconfig \
                noto-fonts-cjk noto-fonts-emoji \
                base-devel util-linux nano
            ;;
    esac

    fc-cache -f >/dev/null 2>&1 || true
}

find_system_python() {
    local candidate=""
    local resolved=""
    local candidates=(python3.14 python3.13 python3.12 python3.11 python3)

    if [[ -n "$PYTHON_BIN" ]] && "$PYTHON_BIN" -c \
        'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' \
        >/dev/null 2>&1; then
        return 0
    fi

    PYTHON_BIN=""
    for candidate in "${candidates[@]}"; do
        resolved="$(command -v "$candidate" 2>/dev/null || true)"
        [[ -n "$resolved" ]] || continue
        if "$resolved" -c \
            'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' \
            >/dev/null 2>&1; then
            PYTHON_BIN="$resolved"
            break
        fi
    done

    if [[ -z "$PYTHON_BIN" ]]; then
        error "未检测到 Python 3.11 或更高版本。"
        error "请先通过系统包管理器安装 Python 3.11+ 及对应的 venv 模块。"
        return 1
    fi

    local version
    version="$($PYTHON_BIN -c 'import platform; print(platform.python_version())')"
    info "已检测到 Python $version：$PYTHON_BIN"
}

ensure_service_user() {
    local nologin_shell="/usr/sbin/nologin"
    [[ -x "$nologin_shell" ]] || nologin_shell="/sbin/nologin"
    [[ -x "$nologin_shell" ]] || nologin_shell="/bin/false"

    if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
        groupadd --system "$SERVICE_GROUP"
    fi
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system \
            --gid "$SERVICE_GROUP" \
            --home-dir "$WORK_DIR" \
            --shell "$nologin_shell" \
            "$SERVICE_USER"
    fi

    SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
    install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$WORK_DIR"
    install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$TOOL_DIR"
}

run_as_bot() {
    runuser -u "$SERVICE_USER" -- env \
        HOME="$WORK_DIR" \
        USER="$SERVICE_USER" \
        LOGNAME="$SERVICE_USER" \
        PATH="$PATH" \
        LANG="$LANG" \
        LC_ALL="$LC_ALL" \
        PYTHONUTF8=1 \
        PYTHONIOENCODING=utf-8 \
        PYTHONUNBUFFERED=1 \
        UV_LINK_MODE=copy \
        UV_INDEX_URL="$PYPI_INDEX" \
        "$@"
}

run_as_bot_in_dir() {
    local directory="$1"
    shift
    run_as_bot bash -c 'cd "$1" && shift && exec "$@"' bash "$directory" "$@"
}

install_codeup_helper() {
    local source_file=""
    local target_file="${TOOL_DIR}/init_codeup.py"
    local candidate=""
    local temporary=0

    if [[ -n "$SCRIPT_DIR" ]]; then
        source_file="${SCRIPT_DIR}/init_codeup.py"
    fi

    if [[ -n "$source_file" && -f "$source_file" ]]; then
        candidate="$source_file"
    else
        info "当前通过在线入口运行，正在下载配套的 init_codeup.py..."
        if ! candidate="$(mktemp "${TOOL_DIR}/.init_codeup.py.XXXXXX")"; then
            error "无法创建 init_codeup.py 临时文件。"
            return 1
        fi
        temporary=1
        if ! curl --fail --silent --show-error --location \
            --retry 3 --connect-timeout 15 \
            "$INIT_CODEUP_URL" -o "$candidate"; then
            rm -f -- "$candidate"
            error "init_codeup.py 下载失败，请将它与 install.sh 放在同一目录后重试。"
            return 1
        fi
    fi

    if ! "$PYTHON_BIN" -c \
        'import pathlib, sys; source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"); compile(source, sys.argv[1], "exec")' \
        "$candidate"; then
        ((temporary == 0)) || rm -f -- "$candidate"
        error "init_codeup.py 不是有效的 UTF-8 Python 脚本。"
        return 1
    fi
    if ! install -m 0500 -o "$SERVICE_USER" -g "$SERVICE_GROUP" \
        "$candidate" "$target_file"; then
        ((temporary == 0)) || rm -f -- "$candidate"
        error "无法安装 init_codeup.py。"
        return 1
    fi
    ((temporary == 0)) || rm -f -- "$candidate"

    INIT_CODEUP_HELPER="$target_file"
}

ensure_uv() {
    local system_uv=""
    system_uv="$(command -v uv 2>/dev/null || true)"
    if [[ -n "$system_uv" ]] && run_as_bot "$system_uv" --version >/dev/null 2>&1; then
        UV_BIN="$system_uv"
        info "使用系统 uv：$UV_BIN"
        return 0
    fi

    UV_BIN="${UV_TOOL_DIR}/bin/uv"
    if [[ -x "$UV_BIN" ]]; then
        info "使用已安装的 uv：$UV_BIN"
        return 0
    fi

    info "正在创建独立 uv 工具环境..."
    if ! run_as_bot "$PYTHON_BIN" -m venv "$UV_TOOL_DIR"; then
        error "无法创建 Python venv。"
        if [[ "${DISTRO_FAMILY:-}" == "debian" ]]; then
            error "请安装与 $PYTHON_BIN 对应的 venv 包，例如 python3.11-venv。"
        fi
        return 1
    fi

    run_as_bot "${UV_TOOL_DIR}/bin/python" -m pip install --upgrade pip
    run_as_bot "${UV_TOOL_DIR}/bin/python" -m pip install uv -i "$PYPI_INDEX"
    [[ -x "$UV_BIN" ]] || die "uv 安装失败。"
    info "uv 安装完成：$UV_BIN"
}

check_installed() {
    if [[ ! -f "${BOT_DIR}/pyproject.toml" || ! -d "${BOT_DIR}/zhenxun" ]]; then
        error "真寻尚未安装：$BOT_DIR"
        return 1
    fi
}

clone_bot_if_needed() {
    local source_choice=""

    if [[ -d "${BOT_DIR}/.git" ]]; then
        info "已检测到真寻仓库，跳过代码拉取和自动更新。"
        return 0
    fi
    if [[ -e "$BOT_DIR" ]]; then
        error "目标目录已存在但不是 Git 仓库：$BOT_DIR"
        error "请先移动该目录，或选择其他安装目录。"
        return 1
    fi

    printf '\n请选择首次拉取代码源：\n'
    printf ' 1. 阿里云 Codeup（默认，国内推荐）\n'
    printf ' 2. GitHub 公共仓库\n\n'
    read -r -p "请输入选项(1-2)，默认 1: " source_choice || source_choice=""
    source_choice="${source_choice:-1}"

    case "$source_choice" in
        1)
            local helper=""
            info "首次部署，正在通过 init_codeup.py 解析并拉取真寻..."
            install_codeup_helper || return 1
            helper="$INIT_CODEUP_HELPER"
            run_as_bot mkdir -p "$BOT_DIR"
            if ! run_as_bot_in_dir "$BOT_DIR" \
                "$PYTHON_BIN" "$helper" zhenxun_bot; then
                rm -rf -- "$BOT_DIR"
                return 1
            fi
            ;;
        2)
            info "首次部署，正在从 GitHub 公共仓库拉取真寻..."
            run_as_bot git clone --branch main --single-branch \
                "$GITHUB_REPO" "$BOT_DIR"
            ;;
        *)
            error "请输入 1 或 2。"
            return 1
            ;;
    esac
}

prepare_env_file() {
    local env_file="${BOT_DIR}/.env.dev"
    local example_file="${BOT_DIR}/.env.example"

    [[ -f "$example_file" ]] || die "仓库中缺少 .env.example。"
    if [[ ! -f "$env_file" ]]; then
        run_as_bot cp "$example_file" "$env_file"
        # Linux 服务器通常需要远程访问首次配置页。
        sed -i -E 's/^[[:space:]]*HOST[[:space:]]*=.*/HOST = 0.0.0.0/' "$env_file"
        chown "$SERVICE_USER:$SERVICE_GROUP" "$env_file"
        chmod 0640 "$env_file"
        info "已生成 .env.dev，并将首次配置监听地址设为 0.0.0.0。"
    fi
}

sync_dependencies() {
    info "正在同步生产依赖..."
    run_as_bot_in_dir "$BOT_DIR" \
        "$UV_BIN" sync --frozen --no-dev --inexact
}

install_browser() {
    info "正在安装 Playwright Chromium..."
    if [[ "${DISTRO_FAMILY:-}" == "debian" ]]; then
        (
            cd "$BOT_DIR"
            HOME="$WORK_DIR" UV_LINK_MODE=copy "$UV_BIN" run playwright install-deps chromium
        ) || warn "Playwright 系统依赖自动安装未完全成功，请根据上方提示补装。"
    fi
    run_as_bot_in_dir "$BOT_DIR" "$UV_BIN" run playwright install chromium
}

write_service_file() {
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Zhenxun Bot
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$BOT_DIR
Environment=LANG=C.UTF-8
Environment=LC_ALL=C.UTF-8
Environment=HOME=$WORK_DIR
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=PYTHONUTF8=1
Environment=PYTHONIOENCODING=utf-8
Environment=PYTHONUNBUFFERED=1
Environment=UV_LINK_MODE=copy
Environment=UV_INDEX_URL=$PYPI_INDEX
ExecStart="$UV_BIN" run zx
Restart=on-failure
RestartSec=5
TimeoutStopSec=45
KillSignal=SIGINT
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "$SERVICE_FILE"
    systemctl daemon-reload
}

show_access_hint() {
    local server_ip=""
    local server_port="8080"
    local configured_port=""
    local env_file="${BOT_DIR}/.env.dev"

    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "$server_ip" ]] || server_ip="服务器IP"

    if [[ -f "$env_file" ]]; then
        while IFS= read -r env_line; do
            if [[ "$env_line" =~ ^[[:space:]]*PORT[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
                configured_port="${BASH_REMATCH[1]}"
            fi
        done <"$env_file"
        if [[ "$configured_port" =~ ^[0-9]+$ ]] && \
            ((10#$configured_port >= 1 && 10#$configured_port <= 65535)); then
            server_port="$configured_port"
        fi
    fi

    printf '\n%s\n' "==============================================="
    info "真寻已启动，请进入首次配置页面："
    printf '  http://%s:%s/#/configure\n' "$server_ip" "$server_port"
    warn "请只向可信网络开放 ${server_port} 端口，完成后台配置后在菜单中重启真寻。"
    warn "QQ 协议端需要单独部署，并连接 /onebot/v11/ws。"
    printf '%s\n' "==============================================="
}

install_bot() {
    local marker=""
    local start_time="$SECONDS"

    require_systemd
    choose_work_dir
    check_architecture
    install_system_dependencies || return 1
    find_system_python || return 1
    ensure_service_user || return 1
    ensure_uv || return 1
    clone_bot_if_needed || return 1
    check_installed || return 1
    prepare_env_file || return 1

    marker="${BOT_DIR}/data/.first_sync_done"
    if [[ ! -f "$marker" ]]; then
        sync_dependencies || return 1
        install_browser || return 1
        run_as_bot mkdir -p "${BOT_DIR}/data"
        run_as_bot touch "$marker"
    else
        info "已完成首次依赖同步，跳过自动同步。"
    fi

    write_service_file || return 1
    if ask_yes_no "是否设置为开机自动启动？" "y"; then
        systemctl enable "$SERVICE_NAME"
    else
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    systemctl restart "$SERVICE_NAME"
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        error "真寻服务启动失败，最近日志如下："
        journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
        return 1
    fi

    info "部署完成，用时 $((SECONDS - start_time)) 秒。"
    show_access_hint
}

start_bot() {
    require_systemd
    check_installed || return 1
    [[ -f "$SERVICE_FILE" ]] || die "systemd 服务尚未创建，请先执行安装。"
    systemctl start "$SERVICE_NAME"
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        info "真寻已启动。"
    else
        error "真寻启动失败，请查看日志。"
        journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
        return 1
    fi
}

stop_bot() {
    require_systemd
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME"
        info "真寻已停止。"
    else
        warn "真寻当前未运行。"
    fi
}

restart_bot() {
    require_systemd
    check_installed || return 1
    systemctl restart "$SERVICE_NAME"
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        info "真寻已重启。"
    else
        error "真寻重启失败，请查看日志。"
        journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
        return 1
    fi
}

show_status() {
    require_systemd
    if [[ -d "${BOT_DIR}/.git" ]]; then
        info "安装目录：$BOT_DIR"
        local revision
        revision="$(run_as_bot git -C "$BOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
        [[ -n "$revision" ]] && info "当前版本：$revision"
    else
        warn "真寻尚未安装。"
    fi

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        info "运行状态：运行中"
    else
        warn "运行状态：未运行"
    fi
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "开机启动：已启用"
    else
        warn "开机启动：未启用"
    fi
    systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || true
}

view_logs() {
    require_systemd
    info "显示最近 100 行日志，按 Ctrl+C 返回。"
    journalctl -u "$SERVICE_NAME" -n 100 -f || true
}

edit_config() {
    check_installed || return 1
    local env_file="${BOT_DIR}/.env.dev"
    [[ -f "$env_file" ]] || prepare_env_file

    local editor="${EDITOR:-}"
    if [[ -z "$editor" ]]; then
        if command -v nano >/dev/null 2>&1; then
            editor="nano"
        else
            editor="vi"
        fi
    fi

    "$editor" "$env_file"
    chown "$SERVICE_USER:$SERVICE_GROUP" "$env_file"
    chmod 0640 "$env_file"
    if ask_yes_no "配置已保存，是否立即重启真寻？" "y"; then
        restart_bot
    fi
}

manual_update() {
    local was_active=0
    local origin_url=""

    require_systemd
    check_installed || return 1
    find_system_python || return 1
    ensure_service_user || return 1
    ensure_uv || return 1

    systemctl is-active --quiet "$SERVICE_NAME" && was_active=1
    ((was_active == 0)) || systemctl stop "$SERVICE_NAME"

    info "正在手动检查 main 分支更新..."
    origin_url="$(run_as_bot git -C "$BOT_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ "$origin_url" == *codeup.aliyun.com* ]]; then
        local helper=""
        if ! install_codeup_helper; then
            ((was_active == 0)) || systemctl start "$SERVICE_NAME"
            return 1
        fi
        helper="$INIT_CODEUP_HELPER"
        if ! run_as_bot_in_dir "$BOT_DIR" \
            "$PYTHON_BIN" "$helper" zhenxun_bot --update; then
            error "从 Codeup 获取远程更新失败。"
            ((was_active == 0)) || systemctl start "$SERVICE_NAME"
            return 1
        fi
    elif ! run_as_bot git -C "$BOT_DIR" fetch origin main; then
        error "获取远程更新失败。"
        ((was_active == 0)) || systemctl start "$SERVICE_NAME"
        return 1
    fi
    if [[ "$origin_url" != *codeup.aliyun.com* ]] && \
        ! run_as_bot git -C "$BOT_DIR" merge --ff-only origin/main; then
        error "无法快进更新；请先处理本地代码修改。"
        ((was_active == 0)) || systemctl start "$SERVICE_NAME"
        return 1
    fi

    if ! sync_dependencies || ! install_browser || ! write_service_file; then
        error "更新后的环境配置失败，请检查上方错误。"
        ((was_active == 0)) || systemctl start "$SERVICE_NAME"
        return 1
    fi
    ((was_active == 0)) || systemctl start "$SERVICE_NAME"
    info "手动更新完成。普通启动不会自动更新代码。"
}

dependency_menu() {
    check_installed || return 1
    find_system_python || return 1
    ensure_service_user || return 1
    ensure_uv || return 1
    [[ -x "$VENV_PYTHON" ]] || sync_dependencies || return 1

    while true; do
        printf '%s\n' \
            "===============================================" \
            "               依赖管理（.venv）" \
            "===============================================" \
            " 1. 安装依赖" \
            " 2. 卸载依赖" \
            " 3. 查看已安装依赖" \
            " 4. 搜索已安装依赖" \
            " 5. 按锁文件重新同步" \
            "" \
            " 0. 返回主菜单" \
            "==============================================="

        local choice=""
        local input=""
        local packages=()
        read -r -p "请输入选项(0-5): " choice || return 0
        case "$choice" in
            1)
                read -r -p "请输入依赖名，多个依赖用空格分隔: " input
                IFS=' ' read -r -a packages <<<"$input"
                ((${#packages[@]} > 0)) && run_as_bot \
                    "$UV_BIN" pip install "${packages[@]}" --python "$VENV_PYTHON"
                pause_manager
                ;;
            2)
                read -r -p "请输入依赖名，多个依赖用空格分隔: " input
                IFS=' ' read -r -a packages <<<"$input"
                ((${#packages[@]} > 0)) && run_as_bot \
                    "$UV_BIN" pip uninstall "${packages[@]}" --python "$VENV_PYTHON"
                pause_manager
                ;;
            3)
                run_as_bot "$UV_BIN" pip list --python "$VENV_PYTHON"
                pause_manager
                ;;
            4)
                read -r -p "请输入依赖名: " input
                [[ -z "$input" ]] || run_as_bot \
                    "$UV_BIN" pip show "$input" --python "$VENV_PYTHON"
                pause_manager
                ;;
            5)
                sync_dependencies
                pause_manager
                ;;
            0) return 0 ;;
            *)
                error "请输入 0-5。"
                pause_manager
                ;;
        esac
    done
}

autostart_menu() {
    require_systemd
    printf '\n1. 启用开机启动\n2. 关闭开机启动\n0. 返回\n\n'
    local choice=""
    read -r -p "请选择(0-2): " choice || return 0
    case "$choice" in
        1)
            systemctl enable "$SERVICE_NAME"
            info "已启用开机启动。"
            ;;
        2)
            systemctl disable "$SERVICE_NAME"
            info "已关闭开机启动；不会停止当前进程。"
            ;;
        0) return 0 ;;
        *) error "请输入 0-2。" ;;
    esac
}

assert_safe_work_dir() {
    case "$WORK_DIR" in
        ""|/|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            die "拒绝删除不安全的工作目录：$WORK_DIR"
            ;;
    esac
    [[ "$BOT_DIR" == "$WORK_DIR/"* ]] || die "Bot 目录不在工作目录内，拒绝删除。"
}

uninstall_bot() {
    require_systemd
    warn "卸载将删除 $BOT_DIR（包括 .env.dev、data 和日志）。"
    warn "系统软件包、服务账号以及外部数据库不会被删除。"
    local confirmation=""
    read -r -p "如已备份数据，请输入 DELETE 继续: " confirmation || return 0
    if [[ "$confirmation" != "DELETE" ]]; then
        info "已取消卸载。"
        return 0
    fi

    assert_safe_work_dir
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f -- "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf -- "$BOT_DIR" "$UV_TOOL_DIR"
    info "真寻程序和独立 uv 环境已删除。"
}

show_menu() {
    while true; do
        printf '%s\n' \
            "===============================================" \
            "  真寻 Bot Linux 一键部署管理器 v${SCRIPT_VERSION}" \
            "===============================================" \
            " 工作目录：$WORK_DIR" \
            "" \
            " 1. 首次部署 / 修复环境" \
            " 2. 启动真寻" \
            " 3. 停止真寻" \
            " 4. 重启真寻" \
            " 5. 查看状态" \
            " 6. 查看实时日志" \
            " 7. 编辑 .env.dev" \
            " 8. 依赖管理" \
            " 9. 手动更新代码" \
            "10. 设置开机启动" \
            "11. 卸载真寻" \
            "" \
            " 0. 退出" \
            "==============================================="

        local choice=""
        read -r -p "请输入选项(0-11): " choice || return 0
        case "$choice" in
            1) install_bot || true; pause_manager ;;
            2) start_bot || true; pause_manager ;;
            3) stop_bot || true; pause_manager ;;
            4) restart_bot || true; pause_manager ;;
            5) show_status || true; pause_manager ;;
            6) view_logs || true ;;
            7) edit_config || true; pause_manager ;;
            8) dependency_menu || true ;;
            9) manual_update || true; pause_manager ;;
            10) autostart_menu || true; pause_manager ;;
            11) uninstall_bot || true; pause_manager ;;
            0) return 0 ;;
            *) error "请输入 0-11。"; pause_manager ;;
        esac
    done
}

main() {
    require_root
    load_config
    show_menu
}

main "$@"
