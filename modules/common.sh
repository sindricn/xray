#!/bin/bash

#================================================================
# 公共库模块 - Common Library
# 功能：统一日志系统、错误处理、工具函数
# 参考：s-hy2 最佳实践
#================================================================

# 严格模式（不使用 -e，保持错误处理可控）
set -uo pipefail

#================================================================
# 日志系统 - Logging System
#================================================================

# 日志级别
readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARN=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_FATAL=4

# 当前日志级别（默认 INFO）
LOG_LEVEL=${LOG_LEVEL:-$LOG_LEVEL_INFO}

# 日志文件
LOG_FILE="${LOG_FILE:-/var/log/xray-manager.log}"
LOG_DIR="$(dirname "$LOG_FILE")"

# 初始化日志目录
init_log_dir() {
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
    fi
}

# 日志函数 - 分级日志输出
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local pid=$$

    # 根据日志级别输出
    if [[ $level -ge $LOG_LEVEL ]]; then
        local level_name=""
        local color=""

        case $level in
            $LOG_LEVEL_DEBUG)
                level_name="DEBUG"
                color="${BLUE}"
                ;;
            $LOG_LEVEL_INFO)
                level_name="INFO "
                color="${CYAN}"
                ;;
            $LOG_LEVEL_WARN)
                level_name="WARN "
                color="${YELLOW}"
                ;;
            $LOG_LEVEL_ERROR)
                level_name="ERROR"
                color="${RED}"
                ;;
            $LOG_LEVEL_FATAL)
                level_name="FATAL"
                color="${RED}"
                ;;
        esac

        # 终端输出（彩色）
        echo -e "${color}[${level_name}]${NC} $message"

        # 文件输出（无颜色）
        if [[ -w "$LOG_DIR" ]] || [[ -w "$LOG_FILE" ]]; then
            echo "[$timestamp] [$level_name] [PID:$pid] $message" >> "$LOG_FILE" 2>/dev/null || true
        fi
    fi
}

# 便捷日志函数
log_debug() { log $LOG_LEVEL_DEBUG "$@"; }
log_info() { log $LOG_LEVEL_INFO "$@"; }
log_warn() { log $LOG_LEVEL_WARN "$@"; }
log_error() { log $LOG_LEVEL_ERROR "$@"; }
log_fatal() { log $LOG_LEVEL_FATAL "$@"; }

# 兼容旧的打印函数（逐步迁移）
print_info() { log_info "$@"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; log_info "[SUCCESS] $*"; }
print_error() { log_error "$@"; }
print_warning() { log_warn "$@"; }

#================================================================
# 错误处理 - Error Handling
#================================================================

# 错误退出函数
error_exit() {
    local message="$1"
    local exit_code="${2:-1}"

    log_fatal "$message"

    # 调用清理函数（如果存在）
    if declare -f cleanup >/dev/null; then
        cleanup
    fi

    exit "$exit_code"
}

# 信号捕获 - 自动清理
setup_signal_handlers() {
    trap 'error_exit "脚本被中断 (SIGINT)" 130' INT
    trap 'error_exit "脚本被终止 (SIGTERM)" 143' TERM
    trap 'handle_error ${LINENO} ${BASH_LINENO} "$BASH_COMMAND" $?' ERR
}

# 错误处理函数 - 调用栈跟踪
handle_error() {
    local lineno=$1
    local bash_lineno=$2
    local command=$3
    local error_code=$4

    log_error "命令执行失败 (退出码: $error_code)"
    log_error "  行号: $lineno"
    log_error "  命令: $command"

    # 打印调用栈
    log_debug "调用栈:"
    local frame=0
    while caller $frame; do
        ((frame++))
    done | while read line func file; do
        log_debug "  $file:$line ($func)"
    done
}

# 临时文件管理
declare -a TEMP_FILES=()

create_temp_file() {
    local temp_file=$(mktemp) || error_exit "无法创建临时文件"
    chmod 600 "$temp_file"
    TEMP_FILES+=("$temp_file")
    echo "$temp_file"
}

cleanup_temp_files() {
    for temp_file in "${TEMP_FILES[@]}"; do
        if [[ -f "$temp_file" ]]; then
            rm -f "$temp_file"
            log_debug "清理临时文件: $temp_file"
        fi
    done
    TEMP_FILES=()
}

# 清理函数（可被覆盖）
cleanup() {
    cleanup_temp_files
}

#================================================================
# 工具函数 - Utility Functions
#================================================================

# 检查命令是否存在
require_command() {
    local command=$1
    local package=${2:-$command}

    if ! command -v "$command" &>/dev/null; then
        error_exit "未找到命令: $command (请安装: $package)"
    fi
}

# 检查 root 权限
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "此脚本必须以 root 权限运行"
    fi
}

# 用户确认
confirm() {
    local prompt="${1:-确认操作}"
    local default="${2:-n}"

    local yn_prompt="[y/N]"
    [[ "$default" == "y" ]] && yn_prompt="[Y/n]"

    read -p "$prompt $yn_prompt: " response
    response=${response:-$default}

    [[ "$response" =~ ^[Yy]$ ]]
}

# IP 地址验证
validate_ip() {
    local ip=$1
    local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

    if [[ ! $ip =~ $ip_regex ]]; then
        return 1
    fi

    # 验证每个字段 <= 255
    local IFS='.'
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        if [[ $octet -gt 255 ]]; then
            return 1
        fi
    done

    return 0
}

# 域名验证
validate_domain() {
    local domain=$1
    local domain_regex='^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'

    [[ $domain =~ $domain_regex ]]
}

# 端口验证
validate_port() {
    local port=$1

    if [[ ! $port =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if [[ $port -lt 1 || $port -gt 65535 ]]; then
        return 1
    fi

    return 0
}

# 邮箱验证
validate_email() {
    local email=$1
    local email_regex='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'

    [[ $email =~ $email_regex ]]
}

# UUID 验证
validate_uuid() {
    local uuid=$1
    local uuid_regex='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    [[ $uuid =~ $uuid_regex ]]
}

# 路径安全验证（防目录遍历）
validate_path() {
    local path=$1

    # 不允许 .. 和绝对路径开头的 /
    if [[ $path =~ \.\. ]] || [[ $path =~ ^/ ]]; then
        return 1
    fi

    return 0
}

# 输入清理（防注入）
sanitize_input() {
    local input="$1"

    # 移除危险字符
    input="${input//;/}"   # 移除分号
    input="${input//|/}"   # 移除管道
    input="${input//&/}"   # 移除 &
    input="${input//\$/}"  # 移除 $
    input="${input//\`/}"  # 移除反引号
    input="${input//\(/}"  # 移除 (
    input="${input//\)/}"  # 移除 )
    input="${input//\{/}"  # 移除 {
    input="${input//\}/}"  # 移除 }
    input="${input//\[/}"  # 移除 [
    input="${input//\]/}"  # 移除 ]
    input="${input//</}"   # 移除 <
    input="${input//>/}"   # 移除 >

    echo "$input"
}

# 获取公网 IP
get_public_ip() {
    local ip=""

    # 尝试多个服务
    ip=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null) || \
    ip=$(curl -s -4 --max-time 5 icanhazip.com 2>/dev/null) || \
    ip=$(curl -s -4 --max-time 5 api.ipify.org 2>/dev/null) || \
    ip=$(curl -s -4 --max-time 5 ipinfo.io/ip 2>/dev/null)

    if [[ -z "$ip" ]]; then
        log_warn "无法获取公网 IP"
        return 1
    fi

    if ! validate_ip "$ip"; then
        log_warn "获取的公网 IP 格式不正确: $ip"
        return 1
    fi

    echo "$ip"
}

# 检查端口是否被占用
check_port_in_use() {
    local port=$1

    if ss -tunlp | grep -q ":$port "; then
        return 0  # 端口被占用
    fi

    return 1  # 端口未被占用
}

# 生成随机字符串
generate_random_string() {
    local length=${1:-16}
    local chars='A-Za-z0-9!@#$%^&*()_+'

    tr -dc "$chars" < /dev/urandom | head -c "$length"
}

# 生成安全密码
generate_secure_password() {
    local length=${1:-16}
    generate_random_string "$length"
}

# 检查系统类型
get_os_type() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$ID"
    elif [[ -f /etc/redhat-release ]]; then
        echo "centos"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# 检查系统版本
get_os_version() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$VERSION_ID"
    else
        echo "unknown"
    fi
}

# 进度条显示
show_progress() {
    local current=$1
    local total=$2
    local width=${3:-50}

    local percent=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))

    printf "\r["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' ' '
    printf "] %3d%% (%d/%d)" "$percent" "$current" "$total"

    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

# 等待任务完成（带超时）
wait_for_condition() {
    local condition_command="$1"
    local timeout=${2:-30}
    local interval=${3:-1}

    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        if eval "$condition_command"; then
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_warn "等待超时: $condition_command"
    return 1
}

# 重试执行（带指数退避）
retry_with_backoff() {
    local max_attempts=${1:-3}
    local initial_delay=${2:-1}
    shift 2
    local command="$@"

    local attempt=1
    local delay=$initial_delay

    while [[ $attempt -le $max_attempts ]]; do
        log_debug "尝试执行 (第 $attempt 次): $command"

        if eval "$command"; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warn "执行失败，${delay}秒后重试..."
            sleep "$delay"
            delay=$((delay * 2))
        fi

        attempt=$((attempt + 1))
    done

    log_error "执行失败，已达到最大重试次数: $max_attempts"
    return 1
}

#================================================================
# 初始化
#================================================================

# 初始化日志
init_log_dir

# 设置信号处理
setup_signal_handlers

# 注册清理函数
trap cleanup EXIT

log_debug "公共库加载完成"
