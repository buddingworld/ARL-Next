#!/bin/bash
# =============================================================================
# ARL-Next 源码模式一键启动脚本 (start-local.sh)
#
# 对应容器版的 start-prod.sh：先检查环境，缺失的自动补齐，最后拉起全部服务。
# 完全脱离 Docker，适用于 Linux 服务器（推荐 Debian 12，见 deploy/source/README.md）。
#
# 幂等：可反复执行。已就绪的组件一律跳过，不会重复安装、不会覆盖已有配置。
#
# 用法：
#   sudo bash start-local.sh                  # 检查 → 补齐 → 启动
#   sudo bash start-local.sh --check-only     # 只体检，不改动任何东西
#   sudo bash start-local.sh --no-start       # 补齐环境但不启动服务
#
# 设计说明：本脚本刻意不使用 set -e —— 安装流程中大量步骤是"可选增强"，
#          单点失败不应中断整体部署；关键步骤显式调用 die() 主动中止。
# =============================================================================

# ==================== 参数解析 ====================
CHECK_ONLY=0     # 只检查不安装
NO_START=0       # 只补齐环境，不启动服务

usage() {
    cat <<'EOF'
ARL-Next 源码模式一键启动脚本

用法: sudo bash start-local.sh [选项]

选项:
  -c, --check-only  仅体检当前环境并列出缺失项，不做任何改动
      --no-start    自动补齐环境后不启动服务
  -h, --help        显示本帮助信息

脚本行为:
  1. 检查系统依赖、原生二进制（massdns / nmap / nuclei）、MongoDB、RabbitMQ、
     Node/Chromium、Python 虚拟环境、GeoIP 数据、前端构建产物、SSL 证书、
     nginx 网关配置与 systemd 服务单元
  2. 缺失的自动安装/生成；已存在的原样保留（配置与证书绝不覆盖）
  3. 启动全部服务并做健康探针校验

支持发行版: apt 系（Debian / Ubuntu）与 dnf 系（RHEL / CentOS / Rocky / AlmaLinux）
境内网络: 默认使用国内镜像源（pip 走阿里云、npm 走 npmmirror）；
          GitHub 相关下载（nuclei 模板、GeoIP）直连失败时会尝试镜像与
          本机 SOCKS5 代理（自动探测 127.0.0.1:1080，或用 ARL_SOCKS_PROXY 指定）
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--check-only) CHECK_ONLY=1 ;;
        --no-start)      NO_START=1 ;;
        -h|--help)       usage; exit 0 ;;
        *)
            echo "❌ 错误：未知参数 '$1'"
            echo ""
            usage
            exit 1
            ;;
    esac
    shift
done

# ==================== 前置校验 ====================
if [ "$EUID" -ne 0 ]; then
    echo "❌ 错误：安装系统依赖与注册服务需要 root 权限，请使用 sudo 运行此脚本："
    echo "👉 sudo bash start-local.sh"
    exit 1
fi

# 强制切换到脚本所在目录（脚本位于仓库根目录）
cd "$(dirname "$0")" || exit 1
REPO_DIR="$(pwd)"
SRC_DIR="$REPO_DIR/deploy/source"

if [ ! -f "$SRC_DIR/nginx-arl.conf" ] || [ ! -f "$SRC_DIR/arl-web.service" ]; then
    echo "❌ 错误：未找到部署模板目录 $SRC_DIR"
    echo "👉 请确认当前为完整仓库（git clone 或完整解压），而非仅拷贝了部分文件。"
    exit 1
fi

# ==================== 并发执行锁机制 ====================
# 与 start-prod.sh / stop-prod.sh / uninstall-prod.sh 共用同一把锁
LOCK_FILE="/tmp/arl_deploy.lock"
if command -v flock &>/dev/null; then
    exec 9> "$LOCK_FILE"
    if ! flock -n 9; then
        echo "❌ 错误：检测到另一个部署、更新、停止或卸载任务正在运行中，请稍后再试。"
        exit 1
    fi
fi

# ==================== 常量定义 ====================
BACKEND_DIR="$REPO_DIR/backend"
FRONTEND_DIR="$REPO_DIR/frontend"
VENV="$BACKEND_DIR/.venv"
OSINT_DIR="$BACKEND_DIR/osint_service"
OSINT_VENV="$OSINT_DIR/.venv"

NGINX_CONF_DEST="/etc/nginx/conf.d/arl.conf"
SYSTEMD_DIR="/etc/systemd/system"
ARL_UNITS=("arl-web" "arl-worker" "arl-osint" "arl-puppeteer")

MONGO_USER="admin"
MONGO_PASS="admin"
RABBIT_USER="admin"
RABBIT_PASS="admin"
# 容器通过 RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS 设置；缺失会导致长扫描任务被 broker 中断
RABBIT_CONSUMER_TIMEOUT="2592000000"

MASSDNS_VERSION="1.1.0"
NUCLEI_VERSION="3.11.0"
PUPPETEER_CORE_VERSION="10.4.0"

# 国内镜像源：直连官方源在境内常出现连接重置，故默认走镜像。
# 需要改回官方源时置空对应环境变量即可，例如：ARL_PIP_INDEX= sudo bash start-local.sh
PIP_INDEX_URL="${ARL_PIP_INDEX-https://mirrors.aliyun.com/pypi/simple/}"
NPM_REGISTRY="${ARL_NPM_REGISTRY-https://registry.npmmirror.com}"

# 境内访问 GitHub 常被重置（表现为 SSL UNEXPECTED_EOF 或镜像返回损坏内容）。
# 若本机存在 SOCKS5 代理（如 ssh -D 1080），自动作为 GitHub 相关下载的兜底通道；
# 也可用 ARL_SOCKS_PROXY=socks5://host:port 显式指定。
SOCKS_PROXY="${ARL_SOCKS_PROXY-}"

MISSING_ITEMS=()

# ==================== 通用工具 ====================
have() { command -v "$1" &>/dev/null; }

die() {
    echo ""
    echo "❌ 错误：$1"
    exit 1
}

report_ok()   { echo "  ✅ $1"; }
report_miss() {
    echo "  ❌ 缺失：$1"
    MISSING_ITEMS+=("$1")
}

# ==================== 通用加载动画指示器 ====================
run_with_spinner() {
    local msg="$1"
    shift
    "$@" > /tmp/arl_deploy_step.log 2>&1 &
    local pid=$!

    local spin='-\|/'
    local i=0

    printf "  ⚙️  %-58s" "$msg"
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\r  ⚙️  %-58s [%c]" "$msg" "${spin:$i:1}"
        sleep 0.1
    done

    wait $pid
    local status=$?
    if [ $status -eq 0 ]; then
        printf "\r  ✅ %-58s [完成]\n" "$msg"
    else
        printf "\r  ⚠️  %-58s [失败]\n" "$msg"
        echo "==================== ❌ 详细报错信息 ===================="
        cat /tmp/arl_deploy_step.log
        echo "========================================================="
    fi
    return $status
}

# ==================== 通用超时执行适配器 ====================
run_cmd_with_timeout() {
    local sec="$1"
    shift
    if command -v timeout &>/dev/null; then
        timeout "$sec" "$@"
    else
        "$@"
    fi
}

# 探测本机 SOCKS5 代理（用于 GitHub 相关下载的兜底通道）
detect_socks_proxy() {
    [ -n "$SOCKS_PROXY" ] && return 0
    if run_cmd_with_timeout 3 bash -c "</dev/tcp/127.0.0.1/1080" 2>/dev/null; then
        SOCKS_PROXY="socks5://127.0.0.1:1080"
    fi
    [ -n "$SOCKS_PROXY" ]
}

# ==================== 发行版与包管理器探测 ====================
# 同时支持 apt 系（Debian / Ubuntu）与 dnf 系（RHEL / CentOS / Rocky / AlmaLinux）
detect_pkg_manager() {
    if have apt-get; then
        OS_FAMILY="debian"
        PKG_MANAGER="apt-get"
    elif have dnf; then
        OS_FAMILY="rhel"
        PKG_MANAGER="dnf"
    elif have yum; then
        OS_FAMILY="rhel"
        PKG_MANAGER="yum"
    else
        echo "❌ 错误：未识别的包管理器，请参照 deploy/source/README.md 手动部署。"
        exit 1
    fi
}

pkg_install() {
    if [ "$OS_FAMILY" = "debian" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    else
        "$PKG_MANAGER" install -y "$@"
    fi
}

# 探测 CPU 架构（Debian 用 dpkg，RHEL 用 uname，统一映射到 nuclei 的命名）
detect_arch() {
    local raw
    if have dpkg; then
        raw="$(dpkg --print-architecture 2>/dev/null)"
    else
        raw="$(uname -m 2>/dev/null)"
    fi
    case "$raw" in
        amd64|x86_64)  echo "amd64" ;;
        arm64|aarch64) echo "arm64" ;;
        *)             echo "$raw" ;;
    esac
}

# ==================== 1. 系统依赖与编译工具链 ====================
check_and_install_base_packages() {
    # 抽样探测：这些齐了就认为基础环境完整，跳过整个包管理流程（避免每次刷元数据的开销）
    local missing=0
    local cmd
    for cmd in gcc make curl wget unzip bzip2 git openssl nginx; do
        have "$cmd" || missing=1
    done
    if [ "$OS_FAMILY" = "debian" ]; then
        dpkg -s libpcap-dev &>/dev/null || missing=1
    else
        rpm -q libpcap-devel &>/dev/null || missing=1
    fi
    python3 -c "import venv" &>/dev/null || missing=1

    if [ $missing -eq 0 ]; then
        report_ok "系统依赖与编译工具链已就绪"
        return 0
    fi

    report_miss "系统依赖与编译工具链（编译器 / libpcap 开发库 / nginx 等）"
    [ "$CHECK_ONLY" -eq 1 ] && return 0

    if [ "$OS_FAMILY" = "debian" ]; then
        run_with_spinner "更新软件包列表" apt-get update -o Acquire::Retries=10 || \
            die "apt-get update 失败，请检查网络或软件源配置。"

        run_with_spinner "安装系统依赖与编译工具链" pkg_install \
            wget unzip bzip2 git curl tzdata ca-certificates \
            make gcc g++ automake autoconf libtool python3-dev \
            libxml2-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev libpcap-dev \
            python3 python3-pip python3-venv openssl nginx \
            || die "系统依赖安装失败，请查看上方报错信息。"
    else
        # RHEL 系：libpcap-devel 位于 CRB 仓库，chromium 位于 EPEL，两者都需显式启用
        run_with_spinner "启用 CRB 与 EPEL 仓库" bash -c "
            dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
            rpm -q epel-release >/dev/null 2>&1 || dnf install -y epel-release >/dev/null 2>&1 || true
            dnf makecache -y >/dev/null 2>&1 || true
        " || echo "  ⚠️  仓库启用异常，继续尝试安装..."

        run_with_spinner "安装系统依赖与编译工具链" pkg_install \
            git gcc gcc-c++ make autoconf automake libtool \
            python3-devel python3-pip \
            libpcap-devel libxml2-devel libxslt-devel zlib-devel libffi-devel openssl-devel \
            wget unzip bzip2 curl tzdata ca-certificates which procps-ng nginx \
            || die "系统依赖安装失败，请查看上方报错信息。"
    fi
}

# ==================== 2. massdns（无发行版包，需源码编译）====================
check_and_install_massdns() {
    if have massdns; then
        report_ok "massdns 已安装 ($(command -v massdns))"
        return 0
    fi

    report_miss "massdns（DNS 爆破引擎）"
    [ "$CHECK_ONLY" -eq 1 ] && return 0

    local workdir
    workdir="$(mktemp -d)"
    if run_with_spinner "编译安装 massdns v$MASSDNS_VERSION" bash -c "
        set -e
        cd '$workdir'
        # 国内 gh-proxy 镜像优先，失败回退 GitHub 直连
        wget -q -t 10 https://gh-proxy.com/https://github.com/blechschmidt/massdns/archive/refs/tags/v${MASSDNS_VERSION}.tar.gz \
          || wget -q -t 10 https://github.com/blechschmidt/massdns/archive/refs/tags/v${MASSDNS_VERSION}.tar.gz
        tar xf v${MASSDNS_VERSION}.tar.gz
        cd massdns-${MASSDNS_VERSION}
        make -j\$(nproc)
        install -m 0755 bin/massdns /usr/local/bin/
    "; then
        rm -rf "$workdir"
    else
        rm -rf "$workdir"
        die "massdns 编译失败。请确认已安装 libpcap-dev 与 gcc，并检查网络能否访问 GitHub。"
    fi

    have massdns || die "massdns 编译完成但未在 PATH 中找到，请检查 /usr/local/bin 是否在 PATH 中。"
}

# ==================== 3. nmap ====================
check_and_install_nmap() {
    if have nmap; then
        report_ok "nmap 已安装（$(nmap --version 2>/dev/null | head -n 1)）"
        return 0
    fi

    report_miss "nmap（端口与服务指纹扫描）"
    [ "$CHECK_ONLY" -eq 1 ] && return 0

    run_with_spinner "安装 nmap" pkg_install nmap || die "nmap 安装失败。"
}

# ==================== 4. nuclei + 模板 ====================
check_and_install_nuclei() {
    if have nuclei; then
        report_ok "nuclei 已安装 ($(command -v nuclei))"
    elif [ "$CHECK_ONLY" -eq 1 ]; then
        report_miss "nuclei（PoC 扫描引擎）"
    else
        report_miss "nuclei（PoC 扫描引擎）"

        local arch zip
        arch="$(detect_arch)"
        case "$arch" in
            amd64) zip="nuclei_${NUCLEI_VERSION}_linux_amd64.zip" ;;
            arm64) zip="nuclei_${NUCLEI_VERSION}_linux_arm64.zip" ;;
            *)     die "暂不支持的 CPU 架构：$arch（nuclei 官方仅提供 amd64 / arm64）" ;;
        esac

        local workdir
        workdir="$(mktemp -d)"
        if run_with_spinner "下载安装 nuclei v$NUCLEI_VERSION" bash -c "
            set -e
            cd '$workdir'
            # 国内 gh-proxy 镜像优先，失败回退 GitHub 直连
            wget -q -t 10 'https://gh-proxy.com/https://github.com/projectdiscovery/nuclei/releases/download/v${NUCLEI_VERSION}/${zip}' -O '${zip}' \
              || wget -q -t 10 'https://github.com/projectdiscovery/nuclei/releases/download/v${NUCLEI_VERSION}/${zip}' -O '${zip}'
            unzip -o -q '${zip}'
            install -m 0755 nuclei /usr/local/bin/
        "; then
            rm -rf "$workdir"
        else
            rm -rf "$workdir"
            die "nuclei 下载安装失败，请检查网络能否访问 GitHub。"
        fi
    fi

    # 模板独立检查：安装量大（数百 MB），仅在缺失时拉取
    # 服务以 root 运行，模板落在 /root/nuclei-templates，
    # 正是 backend/app/services/nuclei_template_service.py:38 的首选搜索路径
    local tpl_dir="$HOME/nuclei-templates"
    if [ -d "$tpl_dir" ] && [ -n "$(ls -A "$tpl_dir" 2>/dev/null)" ]; then
        report_ok "nuclei 模板已就绪 ($tpl_dir)"
        return 0
    fi

    report_miss "nuclei 模板库 ($tpl_dir)"
    [ "$CHECK_ONLY" -eq 1 ] && return 0

    # 模板需从 GitHub 拉取，境内直连常被重置；失败后经本机 SOCKS5 代理重试
    if ! run_with_spinner "拉取 nuclei 模板库（体积较大，请耐心等待）" nuclei -update-templates; then
        if detect_socks_proxy; then
            echo "  ⚠️  直连失败，改经 SOCKS5 代理（$SOCKS_PROXY）重试..."
            run_with_spinner "经代理拉取 nuclei 模板库" \
                env HTTPS_PROXY="$SOCKS_PROXY" HTTP_PROXY="$SOCKS_PROXY" nuclei -update-templates \
                || echo "  ⚠️  nuclei 模板拉取失败，PoC 扫描能力将受限。"
        else
            echo "  ⚠️  nuclei 模板拉取失败，PoC 扫描能力将受限。"
            echo "      如本机有 SOCKS5 代理，可执行：ARL_SOCKS_PROXY=socks5://127.0.0.1:1080 sudo bash start-local.sh"
        fi
    fi
}

# ==================== 5. Node.js / Chromium / puppeteer-core ====================
check_and_install_render_stack() {
    # 5.1 Node.js
    if have node && have npm; then
        report_ok "Node.js 已安装 ($(node --version 2>/dev/null))"
    else
        report_miss "Node.js / npm（截图渲染服务与前端构建）"
        if [ "$CHECK_ONLY" -eq 0 ]; then
            run_with_spinner "安装 Node.js 与 npm" pkg_install nodejs npm \
                || die "Node.js 安装失败。"
        fi
    fi

    # 5.2 Chromium 与图形依赖库
    # puppeteer_server.js:102 硬编码 executablePath=/usr/bin/chromium，路径必须一致
    if [ -x /usr/bin/chromium ]; then
        report_ok "Chromium 已安装 ($(/usr/bin/chromium --version 2>/dev/null))"
    elif [ -x /usr/bin/chromium-browser ]; then
        # RHEL 系（EPEL）的二进制名为 chromium-browser，软链到硬编码路径即可
        report_miss "Chromium 软链 /usr/bin/chromium（二进制已存在于 chromium-browser）"
        if [ "$CHECK_ONLY" -eq 0 ]; then
            ln -sf /usr/bin/chromium-browser /usr/bin/chromium
            report_ok "已创建软链 /usr/bin/chromium -> /usr/bin/chromium-browser"
        fi
    else
        report_miss "Chromium（站点截图渲染内核，需位于 /usr/bin/chromium）"
        if [ "$CHECK_ONLY" -eq 0 ]; then
            if [ "$OS_FAMILY" = "debian" ]; then
                run_with_spinner "安装 Chromium 与图形依赖库" pkg_install \
                    chromium libnss3 libatk-bridge2.0-0 libgtk-3-0 libx11-xcb1 libxcb-dri3-0 \
                    libxcomposite1 libxdamage1 libxrandr2 libgbm1 libasound2 \
                    libxshmfence1 libdrm2 libxkbcommon0 libatspi2.0-0 libcups2 \
                    fontconfig fonts-wqy-zenhei fonts-wqy-microhei \
                    || echo "  ⚠️  Chromium 安装失败，截图与 Web 指纹识别功能将不可用。"
            else
                # RHEL 系：chromium 来自 EPEL，图形依赖由 dnf 自动解析
                run_with_spinner "安装 Chromium 与中文字体" pkg_install \
                    chromium fontconfig wqy-zenhei-fonts \
                    || echo "  ⚠️  Chromium 安装失败，截图与 Web 指纹识别功能将不可用。"
            fi

            # 安装后补齐硬编码路径的软链
            if [ ! -e /usr/bin/chromium ] && [ -x /usr/bin/chromium-browser ]; then
                ln -sf /usr/bin/chromium-browser /usr/bin/chromium
                report_ok "已创建软链 /usr/bin/chromium -> /usr/bin/chromium-browser"
            fi
        fi
    fi

    # 5.3 全局 puppeteer-core
    local node_modules_root=""
    have npm && node_modules_root="$(npm root -g 2>/dev/null)"
    if [ -n "$node_modules_root" ] && [ -d "$node_modules_root/puppeteer-core" ]; then
        report_ok "puppeteer-core 已安装 ($node_modules_root/puppeteer-core)"
    else
        report_miss "puppeteer-core@$PUPPETEER_CORE_VERSION（全局 npm 包）"
        if [ "$CHECK_ONLY" -eq 0 ] && have npm; then
            run_with_spinner "安装 puppeteer-core@$PUPPETEER_CORE_VERSION" \
                npm install -g --registry="$NPM_REGISTRY" "puppeteer-core@$PUPPETEER_CORE_VERSION" \
                || echo "  ⚠️  puppeteer-core 安装失败，截图与 Web 指纹识别功能将不可用。"
        fi
    fi
}

# ==================== 6. Python 虚拟环境 ====================
# 通过 requirements.txt 的 md5 戳记判断是否需要重装依赖：
# 既能跳过重复安装，又能在上游依赖变更后自动跟进。
venv_is_current() {
    local venv_dir="$1"
    local req_file="$2"
    local stamp="$venv_dir/.arl_req_stamp"
    local req_hash=""

    [ -f "$req_file" ] && req_hash="$(md5sum "$req_file" | awk '{print $1}')"
    [ -x "$venv_dir/bin/python" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$req_hash" ]
}

prepare_venv() {
    local venv_dir="$1"
    local req_file="$2"
    local label="$3"

    if [ ! -x "$venv_dir/bin/python" ]; then
        run_with_spinner "创建 $label 虚拟环境" python3 -m venv "$venv_dir" \
            || die "$label 虚拟环境创建失败（请确认已安装 python3-venv）。"
    fi

    # 国内 PyPI 镜像优先；镜像不可用时自动回退官方源
    local -a idx=()
    [ -n "$PIP_INDEX_URL" ] && idx=(-i "$PIP_INDEX_URL")

    run_with_spinner "升级 $label pip" "$venv_dir/bin/pip" install "${idx[@]}" --upgrade pip \
        || die "$label pip 升级失败。"

    if ! run_with_spinner "安装 $label Python 依赖" "$venv_dir/bin/pip" install "${idx[@]}" -r "$req_file"; then
        echo "  ⚠️  国内镜像安装失败，回退官方 PyPI 重试..."
        run_with_spinner "安装 $label Python 依赖（官方源）" "$venv_dir/bin/pip" install -r "$req_file" \
            || die "$label Python 依赖安装失败，请查看上方报错信息。"
    fi
}

# 戳记须在全部安装步骤成功后才写入，避免半成品被误判为已就绪
mark_venv_current() {
    local venv_dir="$1"
    local req_file="$2"
    [ -f "$req_file" ] && md5sum "$req_file" | awk '{print $1}' > "$venv_dir/.arl_req_stamp"
}

check_and_setup_python_envs() {
    # 6.1 后端主环境
    if venv_is_current "$VENV" "$BACKEND_DIR/requirements.txt"; then
        report_ok "后端虚拟环境已就绪（依赖无变化）"
    else
        report_miss "后端虚拟环境 / Python 依赖"
        if [ "$CHECK_ONLY" -eq 0 ]; then
            prepare_venv "$VENV" "$BACKEND_DIR/requirements.txt" "后端"

            # 对齐 Dockerfile.prod:73-79：setuptools 固定 <70.0.0，
            # 并用 --no-build-isolation 让该固定版本对 ARL-NPoC 的 editable 构建真正生效。
            # 注意：本步同样必须带镜像参数，否则会退回官方 PyPI 而触发连接重置。
            local idx_flag=""
            [ -n "$PIP_INDEX_URL" ] && idx_flag="-i $PIP_INDEX_URL"

            run_with_spinner "安装 ARL-NPoC（editable）" bash -c "
                set -e
                '$VENV/bin/pip' install $idx_flag 'setuptools<70.0.0' wheel
                '$VENV/bin/pip' install $idx_flag --no-build-isolation -e '$BACKEND_DIR/ARL-NPoC/'
            " || die "ARL-NPoC 安装失败。"

            mark_venv_current "$VENV" "$BACKEND_DIR/requirements.txt"
        fi
    fi

    # 6.2 osint-service 独立环境
    if venv_is_current "$OSINT_VENV" "$OSINT_DIR/requirements.txt"; then
        report_ok "osint-service 虚拟环境已就绪（依赖无变化）"
    else
        report_miss "osint-service 虚拟环境 / Python 依赖"
        if [ "$CHECK_ONLY" -eq 0 ]; then
            prepare_venv "$OSINT_VENV" "$OSINT_DIR/requirements.txt" "osint-service"
            mark_venv_current "$OSINT_VENV" "$OSINT_DIR/requirements.txt"
        fi
    fi
}

# ==================== 7. MongoDB ====================
MONGO_VERSION="7.0.45"

# 用后端 venv 的 pymongo 探测（不依赖 mongosh —— RHEL 系未必装得上）
mongo_ready() {
    [ -x "$VENV/bin/python" ] || return 1
    run_cmd_with_timeout 20 "$VENV/bin/python" - <<PY 2>/dev/null
import sys
try:
    from pymongo import MongoClient
    MongoClient("mongodb://$MONGO_USER:$MONGO_PASS@127.0.0.1:27017/?authSource=admin",
                serverSelectionTimeoutMS=8000).admin.command("ping")
except Exception:
    sys.exit(1)
sys.exit(0)
PY
}

# 幂等创建管理员账号：已存在则跳过，未启用鉴权时免密创建
create_mongo_user() {
    "$VENV/bin/python" - <<PY
import sys
from pymongo import MongoClient

# 已启用鉴权且账号存在的情况
try:
    MongoClient("mongodb://$MONGO_USER:$MONGO_PASS@127.0.0.1:27017/?authSource=admin",
                serverSelectionTimeoutMS=8000).admin.command("ping")
    print("EXISTS")
    sys.exit(0)
except Exception:
    pass

# 未启用鉴权时免密创建
try:
    c = MongoClient("mongodb://127.0.0.1:27017/?directConnection=true",
                    serverSelectionTimeoutMS=8000)
    c.admin.command("createUser", "$MONGO_USER", pwd="$MONGO_PASS",
                    roles=[{"role": "root", "db": "admin"}])
    print("CREATED")
except Exception as exc:
    print("FAILED: %s" % exc)
    sys.exit(1)
PY
}

# RHEL 系走官方 tarball：绕开 MongoDB 7.0 仓库密钥的 SHA1 自签名被现代加密策略拒绝的问题，
# 改用 HTTPS + 官方 SHA256 强校验，安全性不低于 RPM GPG，且不改动系统加密策略
install_mongodb_tarball() {
    local dist="rhel90"
    local tgz="mongodb-linux-x86_64-${dist}-${MONGO_VERSION}.tgz"
    local base="https://fastdl.mongodb.org/linux"
    local prefix="/usr/local/mongodb"

    run_with_spinner "下载 MongoDB $MONGO_VERSION（$dist）" bash -c "
        set -e
        cd /tmp
        rm -f '$tgz' '$tgz.sha256'
        curl -fSL -m 900 -o '$tgz' '$base/$tgz'
        curl -fSL -m 60 -o '$tgz.sha256' '$base/$tgz.sha256'
    " || die "MongoDB 下载失败，请检查网络能否访问 fastdl.mongodb.org。"

    local expected actual
    expected="$(awk '{print $1}' "/tmp/$tgz.sha256")"
    actual="$(sha256sum "/tmp/$tgz" | awk '{print $1}')"
    if [ "$expected" != "$actual" ]; then
        die "MongoDB 安装包 SHA256 校验失败（期望 $expected / 实际 $actual），已中止安装。"
    fi
    echo "  ✅ MongoDB 安装包 SHA256 校验通过"

    run_with_spinner "解压安装 MongoDB 到 $prefix" bash -c "
        set -e
        rm -rf /tmp/mongo_extract '$prefix'
        mkdir -p /tmp/mongo_extract
        tar xzf '/tmp/$tgz' -C /tmp/mongo_extract
        src=\$(find /tmp/mongo_extract -maxdepth 1 -type d -name 'mongodb-*' | head -1)
        [ -n \"\$src\" ] || exit 1
        mv \"\$src\" '$prefix'
        ln -sf '$prefix/bin/mongod' /usr/local/bin/mongod
        rm -rf /tmp/mongo_extract '/tmp/$tgz' '/tmp/$tgz.sha256'
    " || die "MongoDB 解压安装失败。"

    # SELinux：经 /tmp 解压再 mv 会带入 user_tmp_t 上下文，systemd 会以 203/EXEC 拒绝执行
    if have getenforce && [ "$(getenforce 2>/dev/null)" != "Disabled" ]; then
        chcon -R -t bin_t "$prefix/bin" 2>/dev/null || true
        run_cmd_with_timeout 30 semanage fcontext -a -t bin_t "$prefix/bin(/.*)?" >/dev/null 2>&1 || true
        echo "  ✅ 已修正 SELinux 上下文为 bin_t（避免 systemd 203/EXEC）"
    fi

    # 运行用户与目录
    id mongod >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d /var/lib/mongo mongod
    mkdir -p /var/lib/mongo /var/log/mongodb
    # 清掉可能由 root 手动运行 mongod 留下的日志文件（属主为 root 时 mongod 用户无权写入）
    rm -f /var/log/mongodb/mongod.log
    chown -R mongod:mongod /var/lib/mongo /var/log/mongodb
    chmod 755 /var/lib/mongo /var/log/mongodb

    cat > /etc/mongod.conf <<'EOF'
storage:
  dbPath: /var/lib/mongo
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
net:
  port: 27017
  bindIp: 127.0.0.1
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
EOF

    # Type=simple 而非 forking+--fork：日志直接进 journald，且避免 fork 后子进程失败被漏判
    cat > /etc/systemd/system/mongod.service <<'EOF'
[Unit]
Description=MongoDB Database Server
After=network-online.target
Wants=network-online.target

[Service]
User=mongod
Group=mongod
Type=simple
ExecStart=/usr/local/bin/mongod --config /etc/mongod.conf
Restart=on-failure
RestartSec=3
LimitNOFILE=64000
LimitNPROC=64000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

check_and_setup_mongodb() {
    if ! have mongod; then
        report_miss "MongoDB 7.0"
        [ "$CHECK_ONLY" -eq 1 ] && return 0

        if [ "$OS_FAMILY" = "debian" ]; then
            run_with_spinner "导入 MongoDB 官方软件源" bash -c "
                set -e
                curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
                    | gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor
                echo 'deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main' \
                    > /etc/apt/sources.list.d/mongodb-org-7.0.list
                apt-get update -o Acquire::Retries=10
            " || die "MongoDB 软件源导入失败，请检查网络。"

            # 只装 server 与 shell：mongodb-org-tools 依赖缺失的 mongodb-database-tools，
            # 且备份功能不在源码模式范围内
            run_with_spinner "安装 MongoDB 7.0" pkg_install mongodb-org-server mongodb-mongosh \
                || die "MongoDB 安装失败。"
        else
            install_mongodb_tarball
        fi
    else
        report_ok "MongoDB 已安装"
    fi

    # 体检模式：只读探测，绝不重启服务或改动配置
    if [ "$CHECK_ONLY" -eq 1 ]; then
        if systemctl is-active --quiet mongod 2>/dev/null; then
            report_ok "MongoDB 服务运行中"
        else
            report_miss "MongoDB 服务未运行"
        fi
        if grep -qE '^[[:space:]]*authorization[[:space:]]*:[[:space:]]*enabled' /etc/mongod.conf 2>/dev/null; then
            report_ok "MongoDB 鉴权已启用"
        else
            report_miss "MongoDB 鉴权未启用（security.authorization）"
        fi
        return 0
    fi

    run_with_spinner "启动 MongoDB 服务" bash -c "
        systemctl enable mongod >/dev/null 2>&1
        systemctl reset-failed mongod >/dev/null 2>&1 || true
        systemctl restart mongod
    " || die "MongoDB 启动失败，请执行 'journalctl -u mongod -n 50' 排查。"

    # 等待端口就绪
    local i
    for i in $(seq 1 30); do
        if run_cmd_with_timeout 3 bash -c "</dev/tcp/127.0.0.1/27017" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    # 幂等创建管理员账号（对应容器的 MONGO_INITDB_ROOT_USERNAME/PASSWORD=admin）
    run_with_spinner "确保 MongoDB 管理员账号存在" create_mongo_user || true

    # 启用鉴权：仅在确无 security 节点时追加，绝不改写已有配置
    if grep -qE '^[[:space:]]*authorization[[:space:]]*:[[:space:]]*enabled' /etc/mongod.conf 2>/dev/null; then
        report_ok "MongoDB 鉴权已启用"
    elif grep -qE '^[[:space:]]*security[[:space:]]*:' /etc/mongod.conf 2>/dev/null; then
        echo "  ⚠️  /etc/mongod.conf 已存在 security 节点，本脚本不擅自改写。"
        echo "      请自行确认其中包含 'authorization: enabled'。"
    else
        run_with_spinner "启用 MongoDB 鉴权" bash -c "
            printf '\nsecurity:\n  authorization: enabled\n' >> /etc/mongod.conf
            systemctl restart mongod
        " || die "MongoDB 启用鉴权失败。"
        sleep 3
    fi

    # 监听面核查：只提示不改写（已存在的实例可能承载其他业务）
    if grep -qE '^[[:space:]]*bindIp[[:space:]]*:.*0\.0\.0\.0' /etc/mongod.conf 2>/dev/null; then
        echo "  ⚠️  mongod 监听 0.0.0.0，数据库将暴露于公网，建议改为 127.0.0.1 后重启。"
    fi

    if mongo_ready; then
        report_ok "MongoDB 连接正常（$MONGO_USER@127.0.0.1:27017）"
    else
        echo "  ⚠️  MongoDB 已启动，但用默认凭据连接失败。"
        echo "      若你在 backend/config.yaml 中自定义过账号密码，请忽略本条；"
        echo "      否则请手动创建："
        echo "      mongosh --eval 'db.getSiblingDB(\"admin\").createUser({user:\"$MONGO_USER\",pwd:\"$MONGO_PASS\",roles:[{role:\"root\",db:\"admin\"}]})'"
    fi
}

# ==================== 8. RabbitMQ ====================
check_and_setup_rabbitmq() {
    local installed=0
    if have rabbitmq-server; then
        installed=1
    elif [ "$OS_FAMILY" = "debian" ] && dpkg -s rabbitmq-server &>/dev/null; then
        installed=1
    elif [ "$OS_FAMILY" = "rhel" ] && rpm -q rabbitmq-server &>/dev/null; then
        installed=1
    fi

    if [ $installed -eq 1 ]; then
        report_ok "RabbitMQ 已安装"
    else
        report_miss "RabbitMQ（Celery 消息队列）"
        [ "$CHECK_ONLY" -eq 1 ] && return 0

        if [ "$OS_FAMILY" = "rhel" ]; then
            # RHEL 系基础源不含 RabbitMQ，需启用 CentOS Messaging SIG 仓库
            # （RabbitMQ 官方 Cloudsmith 源目前无 el10 路径，直接返回 404）
            run_with_spinner "启用 RabbitMQ 仓库（CentOS Messaging SIG）" bash -c "
                rpm -q centos-release-rabbitmq-4 >/dev/null 2>&1 || dnf install -y centos-release-rabbitmq-4
            " || die "RabbitMQ 仓库启用失败。"
        fi

        run_with_spinner "安装 RabbitMQ" pkg_install rabbitmq-server || die "RabbitMQ 安装失败。"
    fi

    if [ "$CHECK_ONLY" -eq 1 ]; then
        if grep -q "consumer_timeout" /etc/rabbitmq/rabbitmq.conf 2>/dev/null; then
            report_ok "RabbitMQ consumer_timeout 已配置"
        else
            report_miss "RabbitMQ consumer_timeout（缺失会导致长扫描任务被中断）"
        fi
        return 0
    fi

    # 关键项：容器通过 RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS 设置超长消费超时。
    # 缺失时长时间扫描任务会被 broker 以 ack 超时强制中断，且只在跑长任务时才暴露。
    if ! grep -q "consumer_timeout" /etc/rabbitmq/rabbitmq.conf 2>/dev/null; then
        mkdir -p /etc/rabbitmq
        [ -f /etc/rabbitmq/rabbitmq.conf ] && \
            cp -f /etc/rabbitmq/rabbitmq.conf "/etc/rabbitmq/rabbitmq.conf.bak_$(date +%Y%m%d%H%M%S)"
        echo "consumer_timeout = $RABBIT_CONSUMER_TIMEOUT" >> /etc/rabbitmq/rabbitmq.conf
        echo "  ✅ 已写入 consumer_timeout = $RABBIT_CONSUMER_TIMEOUT"
    else
        report_ok "RabbitMQ consumer_timeout 已配置"
    fi

    run_with_spinner "启动 RabbitMQ 服务" bash -c "
        systemctl enable rabbitmq-server >/dev/null 2>&1
        systemctl restart rabbitmq-server
    " || die "RabbitMQ 启动失败，请执行 'journalctl -u rabbitmq-server' 排查。"

    # 等待就绪
    local i
    for i in $(seq 1 30); do
        if run_cmd_with_timeout 3 bash -c "</dev/tcp/127.0.0.1/5672" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    # 幂等创建账号（对应容器的 RABBITMQ_DEFAULT_USER/PASS=admin）
    run_with_spinner "确保 RabbitMQ 账号与权限" bash -c "
        rabbitmqctl add_user '$RABBIT_USER' '$RABBIT_PASS' 2>/dev/null \
          || rabbitmqctl change_password '$RABBIT_USER' '$RABBIT_PASS' >/dev/null 2>&1 || true
        rabbitmqctl set_user_tags '$RABBIT_USER' administrator >/dev/null 2>&1 || true
        rabbitmqctl set_permissions -p / '$RABBIT_USER' '.*' '.*' '.*' >/dev/null 2>&1 || true
    " || true
}

# ==================== 9. GeoIP 数据 ====================
# GeoIP 兜底下载：官方直链（raw.githubusercontent.com）境内会被 SSL 重置，
# 脚本内置镜像 ghproxy.cn 实测会返回损坏内容（sha256 不匹配），
# 因此按「gh-proxy.com → jsDelivr → 本机 SOCKS5 代理」重试，
# 且每个通道都必须通过 GEOIP_VERSIONS.json 里的 sha256 强校验才落盘。
fetch_geoip_fallback() {
    local geoip_dir="$1"
    local name="ip2region_v4.xdb"
    local meta_file="$geoip_dir/GEOIP_VERSIONS.json"
    local dest="$geoip_dir/$name"

    [ -f "$meta_file" ] || return 1

    local raw_url expect_sha
    raw_url=$(python3 -c "import json;print(json.load(open('$meta_file'))['$name']['url'])" 2>/dev/null) || return 1
    expect_sha=$(python3 -c "import json;print(json.load(open('$meta_file'))['$name']['sha256'])" 2>/dev/null) || return 1
    [ -n "$raw_url" ] && [ -n "$expect_sha" ] || return 1

    local tmp
    tmp="$(mktemp)"

    local -a urls=(
        "https://gh-proxy.com/$raw_url"
        "https://cdn.jsdelivr.net/gh/lionsoul2014/ip2region@master/data/$name"
    )

    local url
    for url in "${urls[@]}"; do
        rm -f "$tmp"
        if run_cmd_with_timeout 300 curl -fSL -o "$tmp" "$url" 2>/dev/null \
           && [ "$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')" = "$expect_sha" ]; then
            mv -f "$tmp" "$dest"
            echo "  ✅ GeoIP 经镜像下载并通过 sha256 校验"
            return 0
        fi
    done

    if detect_socks_proxy; then
        rm -f "$tmp"
        if run_cmd_with_timeout 300 curl -fSL --socks5-hostname "${SOCKS_PROXY#socks5://}" \
               -o "$tmp" "$raw_url" 2>/dev/null \
           && [ "$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')" = "$expect_sha" ]; then
            mv -f "$tmp" "$dest"
            echo "  ✅ GeoIP 经 SOCKS5 代理下载并通过 sha256 校验"
            return 0
        fi
    fi

    rm -f "$tmp"
    return 1
}

check_and_fetch_geoip() {
    local geoip_dir="$BACKEND_DIR/GeoLite2"

    if [ -f "$geoip_dir/ip2region_v4.xdb" ]; then
        report_ok "GeoIP 数据库已就绪"
        if [ ! -f "$geoip_dir/GeoLite2-City.mmdb" ]; then
            echo "  ℹ️  未检测到 GeoLite2-City.mmdb（城市级解析降级）。"
            echo "      如需精确解析：MAXMIND_LICENSE_KEY=<你的key> python3 tools/fetch_geoip.py --dir $geoip_dir"
        fi
        return 0
    fi

    report_miss "GeoIP 数据库（ip2region / GeoLite2）"
    [ "$CHECK_ONLY" -eq 1 ] && return 0

    if [ ! -f "$REPO_DIR/tools/fetch_geoip.py" ]; then
        echo "  ⚠️  未找到 tools/fetch_geoip.py，跳过 GeoIP 预填充（归属地解析将降级）。"
        return 0
    fi

    # 先走脚本自带逻辑（官方直链 + 内置镜像）
    if run_with_spinner "获取 GeoIP 数据库" \
        python3 "$REPO_DIR/tools/fetch_geoip.py" --dir "$geoip_dir"; then
        return 0
    fi

    # 不阻断部署：兜底通道也失败时服务仍以降级模式运行
    echo "  ⚠️  官方源获取失败（境内常见 SSL 重置），尝试镜像兜底通道..."
    if fetch_geoip_fallback "$geoip_dir"; then
        return 0
    fi

    echo "  ⚠️  GeoIP 获取失败，不阻断部署（归属地解析将降级）。"
    echo "      如本机有 SOCKS5 代理，可执行：ARL_SOCKS_PROXY=socks5://127.0.0.1:1080 sudo bash start-local.sh"
}

# ==================== 10. 主机名别名 ====================
# 源码中有 3 处硬编码的容器主机名，用 /etc/hosts 别名覆盖即可零代码改动
check_and_setup_hosts() {
    local missing=0
    local alias_name
    for alias_name in mongodb osint-service arl-puppeteer; do
        if ! grep -qE "^127\.0\.0\.1[[:space:]]+.*\b${alias_name}\b" /etc/hosts 2>/dev/null; then
            missing=1
        fi
    done

    if [ $missing -eq 0 ]; then
        report_ok "容器主机名别名已配置 (/etc/hosts)"
        return 0
    fi

    report_miss "容器主机名别名（mongodb / osint-service / arl-puppeteer）"
    [ "$CHECK_ONLY" -eq 1 ] && return 0

    cat >> /etc/hosts <<'EOF'

# ARL-Next 源码模式：兼容源码中硬编码的容器主机名
127.0.0.1 mongodb osint-service arl-puppeteer
EOF
    report_ok "已写入 /etc/hosts 别名"
}

# ==================== 11. 后端配置 ====================
check_and_setup_config() {
    local conf="$BACKEND_DIR/config.yaml"

    if [ -f "$conf" ]; then
        # 已存在则绝不覆盖：该文件被 .gitignore 忽略，可能含真实凭据与 API Key
        report_ok "后端配置已存在（保留不覆盖）: backend/config.yaml"
        # 提示仍指向容器路径的历史遗留
        if grep -q "/code/backend" "$conf" 2>/dev/null; then
            echo "  ⚠️  检测到配置中仍含容器路径 /code/backend，请改为本机路径："
            echo "      sed -i 's#/code/backend/#$REPO_DIR/backend/#g' $conf"
        fi
        return 0
    fi

    report_miss "后端配置 backend/config.yaml"
    [ "$CHECK_ONLY" -eq 1 ] && return 0

    cp "$BACKEND_DIR/config.yaml.example" "$conf" || die "生成 backend/config.yaml 失败。"

    # 模板使用容器发布端口与容器内绝对路径，此处改写为本机形态
    sed -i \
        -e 's#127.0.0.1:27018#127.0.0.1:27017#g' \
        -e 's#127.0.0.1:5673#127.0.0.1:5672#g' \
        -e "s#/code/backend/#$REPO_DIR/backend/#g" \
        "$conf" || die "改写 backend/config.yaml 路径失败。"

    report_ok "已生成 backend/config.yaml（端口与路径已本地化）"
}

# ==================== 12. 前端构建产物 ====================
check_and_build_frontend() {
    if [ -f "$FRONTEND_DIR/dist/index.html" ]; then
        report_ok "前端构建产物已就绪 (frontend/dist)"
        return 0
    fi

    report_miss "前端构建产物 frontend/dist"
    [ "$CHECK_ONLY" -eq 1 ] && return 0

    have node || die "未安装 Node.js，无法构建前端。"
    have npm || die "未安装 npm，无法构建前端。"

    # Node 会按物理内存推导默认堆上限，低内存机器上压得极低
    # （实测 923MB 内存 → 474MB 上限），vite 构建会报 "Reached heap limit" 直接失败——
    # 且因为是 V8 自限而非系统 OOM，dmesg 里查不到任何记录，极易误判为系统内存不足。
    # 这里按「物理内存 + Swap」的一半放宽堆上限，让构建能借 Swap 跑完。
    local total_mb swap_mb heap_mb
    total_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    swap_mb=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')
    heap_mb=$(( ( ${total_mb:-2048} + ${swap_mb:-0} ) / 2 ))
    [ "$heap_mb" -lt 1024 ] && heap_mb=1024
    [ "$heap_mb" -gt 4096 ] && heap_mb=4096
    export NODE_OPTIONS="--max-old-space-size=$heap_mb"
    echo "  ℹ️  前端构建堆上限设为 ${heap_mb}MB（物理内存 ${total_mb:-?}MB + Swap ${swap_mb:-0}MB）"

    # 与 frontend/Dockerfile.prod 一致：使用 pnpm 与 lockfile 冻结安装
    if ! have pnpm; then
        run_with_spinner "安装 pnpm@9" npm install -g --registry="$NPM_REGISTRY" pnpm@9 \
            || die "pnpm 安装失败。"
    fi

    if [ -f "$FRONTEND_DIR/pnpm-lock.yaml" ]; then
        run_with_spinner "安装前端依赖（pnpm，冻结 lockfile）" \
            bash -c "cd '$FRONTEND_DIR' && pnpm install --frozen-lockfile --registry='$NPM_REGISTRY'" \
            || die "前端依赖安装失败。"
    else
        run_with_spinner "安装前端依赖（pnpm）" \
            bash -c "cd '$FRONTEND_DIR' && pnpm install --registry='$NPM_REGISTRY'" \
            || die "前端依赖安装失败。"
    fi

    # prebuild 会把 mcp-server/server.py 复制进 public/mcp，随 vite build 一并产出
    run_with_spinner "构建前端产物（含 .gz 预压缩）" \
        bash -c "cd '$FRONTEND_DIR' && pnpm run build" \
        || die "前端构建失败。若报 'Reached heap limit'，请增大 Swap 后重试（构建需要约 1GB 可用内存）。"

    [ -f "$FRONTEND_DIR/dist/index.html" ] || die "前端构建完成但未找到 frontend/dist/index.html。"
}

# ==================== 13. SSL 证书 ====================
check_and_setup_ssl() {
    if [ -f "$REPO_DIR/ssl-certs/arl.crt" ] && [ -f "$REPO_DIR/ssl-certs/arl.key" ]; then
        report_ok "SSL 证书已存在（保留不覆盖）"
        return 0
    fi

    report_miss "SSL 证书 (ssl-certs/arl.crt, arl.key)"
    [ "$CHECK_ONLY" -eq 1 ] && return 0

    mkdir -p "$REPO_DIR/ssl-certs"
    run_with_spinner "生成自签名 SSL 证书" openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
        -subj "/C=CN/ST=GD/L=SZ/O=ARL/CN=localhost" \
        -keyout "$REPO_DIR/ssl-certs/arl.key" \
        -out "$REPO_DIR/ssl-certs/arl.crt" \
        || die "自签名证书生成失败（请确认已安装 openssl）。"

    chmod 644 "$REPO_DIR/ssl-certs/arl.crt" "$REPO_DIR/ssl-certs/arl.key"
    report_ok "已生成自签名证书（浏览器首次访问需手动信任）"
}

# ==================== 14. Nginx 网关配置 ====================
# 模板中的 /opt/arl-next 是文档约定路径，此处替换为实际部署路径。
# 转义 & —— sed 替换串中的 & 代表"整个匹配内容"，路径含 & 时会写坏配置。
render_template() {
    sed "s|/opt/arl-next|${REPO_DIR//&/\\&}|g" "$1"
}

# SELinux 是否处于强制模式（决定是否需要打标签/放行端口）
selinux_enforcing() {
    have getenforce && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]
}

# RHEL 系 SELinux 放行：nginx 受 httpd_t 约束，需显式允许非标准端口与内容目录，
# 否则表现为「配置语法 ok 但服务起不来」，且报错只有一句 Permission denied，极易误判为权限位问题
configure_selinux_for_nginx() {
    selinux_enforcing || return 0

    # 1. 放行 nginx 绑定 5173（http_port_t 默认只含 80/81/443/488/8008/8009/8443/9000）
    run_cmd_with_timeout 30 semanage port -a -t http_port_t -p tcp 5173 2>/dev/null \
        || run_cmd_with_timeout 30 semanage port -m -t http_port_t -p tcp 5173 2>/dev/null \
        || true

    # 2. 前端产物与证书目录需标记为 httpd 可读（默认 usr_t 会被拒绝）
    run_cmd_with_timeout 30 semanage fcontext -a -t httpd_sys_content_t \
        "$FRONTEND_DIR/dist(/.*)?" >/dev/null 2>&1 || true
    run_cmd_with_timeout 30 semanage fcontext -a -t httpd_sys_content_t \
        "$REPO_DIR/ssl-certs(/.*)?" >/dev/null 2>&1 || true
    restorecon -R "$FRONTEND_DIR/dist" "$REPO_DIR/ssl-certs" >/dev/null 2>&1 || true

    # 3. 允许 nginx 反向代理到本机后端。
    #    默认 httpd_can_network_connect=off，表现为 502 Bad Gateway，
    #    且 nginx error.log 里只有一句 connect() failed (13: Permission denied)，极易误判为后端没起。
    if ! run_cmd_with_timeout 30 getsebool httpd_can_network_connect 2>/dev/null | grep -q "on$"; then
        run_cmd_with_timeout 30 setsebool -P httpd_can_network_connect on >/dev/null 2>&1 || true
        echo "  ✅ 已放行 SELinux httpd_can_network_connect（nginx 反向代理后端）"
    fi

    echo "  ✅ 已配置 SELinux：放行 5173 端口并标记前端产物/证书目录"
}

check_and_setup_nginx() {
    # 注意：暂存文件必须建在目标目录内再 mv。
    # 若用 mktemp 建在 /tmp 再 mv 过去，文件会带着 user_tmp_t 上下文，
    # nginx 以 httpd_t 读取时会报 Permission denied 而无法启动。
    local staged="$NGINX_CONF_DEST.new"

    render_template "$SRC_DIR/nginx-arl.conf" > "$staged"

    if [ -f "$NGINX_CONF_DEST" ] && cmp -s "$staged" "$NGINX_CONF_DEST"; then
        rm -f "$staged"
        report_ok "Nginx 网关配置已是最新"
    else
        if [ ! -f "$NGINX_CONF_DEST" ]; then
            report_miss "Nginx 网关配置 ($NGINX_CONF_DEST)"
        else
            report_miss "Nginx 网关配置已变更（旧配置将备份）"
        fi

        if [ "$CHECK_ONLY" -eq 1 ]; then
            rm -f "$staged"
            return 0
        fi

        if [ -f "$NGINX_CONF_DEST" ]; then
            cp -f "$NGINX_CONF_DEST" "$NGINX_CONF_DEST.bak_$(date +%Y%m%d%H%M%S)"
        fi
        mv -f "$staged" "$NGINX_CONF_DEST"
        restorecon -F "$NGINX_CONF_DEST" >/dev/null 2>&1 || true
        report_ok "已安装 Nginx 网关配置"
    fi

    [ "$CHECK_ONLY" -eq 1 ] && return 0

    configure_selinux_for_nginx

    run_with_spinner "校验 Nginx 配置语法" nginx -t || die "Nginx 配置校验失败，请检查上方报错。"

    # nginx 未运行时 start 即生效；已在运行时 reload 平滑加载
    run_with_spinner "启动并重载 Nginx" bash -c "
        systemctl enable nginx >/dev/null 2>&1
        systemctl reset-failed nginx >/dev/null 2>&1 || true
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx
        else
            systemctl start nginx
        fi
    " || die "Nginx 启动失败，请执行 'journalctl -u nginx -n 30' 排查。"
}

# ==================== 15. systemd 服务单元 ====================
check_and_setup_units() {
    local changed=0
    local unit unit_file staged

    for unit in "${ARL_UNITS[@]}"; do
        unit_file="$SYSTEMD_DIR/$unit.service"
        # 同样在目标目录内暂存再 mv，避免带入 /tmp 的 SELinux 上下文
        staged="$unit_file.new"
        render_template "$SRC_DIR/$unit.service" > "$staged"

        if [ -f "$unit_file" ] && cmp -s "$staged" "$unit_file"; then
            rm -f "$staged"
            continue
        fi

        changed=1
        if [ "$CHECK_ONLY" -eq 1 ]; then
            rm -f "$staged"
            report_miss "systemd 服务单元 $unit.service"
            continue
        fi

        if [ -f "$unit_file" ]; then
            cp -f "$unit_file" "$unit_file.bak_$(date +%Y%m%d%H%M%S)"
        fi
        mv -f "$staged" "$unit_file"
        restorecon -F "$unit_file" >/dev/null 2>&1 || true
        report_ok "已安装 systemd 服务单元 $unit.service"
    done

    if [ $changed -eq 0 ]; then
        report_ok "systemd 服务单元已是最新"
    elif [ "$CHECK_ONLY" -eq 0 ]; then
        systemctl daemon-reload || die "systemctl daemon-reload 失败。"
    fi

    [ "$CHECK_ONLY" -eq 1 ] && return 0

    # 确保脚本可执行：
    # - start-worker.sh 由 systemd 直接调用
    # - wait-for-it.sh 在仓库中是 100644，而它内部会以 `timeout $0 --child ...` 重新执行自身，
    #   缺少执行位会导致 "Permission denied" 使 worker 反复崩溃重启
    #   （容器内由 Dockerfile 显式 chmod +x，源码模式必须在此补齐）
    chmod +x "$SRC_DIR/start-worker.sh" "$BACKEND_DIR/wait-for-it.sh" 2>/dev/null || true
}

# ==================== 16. 启动服务 ====================
start_services() {
    echo "🚀 正在启动 ARL-Next 服务..."
    local unit
    for unit in "${ARL_UNITS[@]}"; do
        systemctl enable "$unit" >/dev/null 2>&1 || true
        if systemctl is-active --quiet "$unit"; then
            echo "  ✅ $unit 已在运行"
        elif systemctl start "$unit"; then
            echo "  ✅ $unit 已启动"
        else
            echo "  ❌ $unit 启动失败，请执行 'journalctl -u $unit -n 50 --no-pager' 排查"
        fi
    done
}

# ==================== 17. 健康探针 ====================
verify_health() {
    echo "⏳ 正在等待后端 API 就绪 (动态健康探针检测)..."

    local max_wait=90 waited=0
    while [ $waited -lt $max_wait ]; do
        if curl -s -m 3 http://127.0.0.1:5000/ >/dev/null 2>&1; then
            echo "  ✅ 后端服务已就绪 (耗时 $waited 秒)"
            break
        fi
        sleep 2
        waited=$((waited + 2))
        printf "\r  ⏳ 健康探针探测中... (%d / %d 秒)" "$waited" "$max_wait"
    done
    echo ""

    if [ $waited -ge $max_wait ]; then
        echo "  ⚠️  后端等待超时，请检查：journalctl -u arl-web -n 50 --no-pager"
    fi

    # 前端网关 TLS 握手探测
    local i
    for i in $(seq 1 5); do
        if curl -k -s -m 3 -o /dev/null https://127.0.0.1:5173/ 2>/dev/null; then
            echo "  ✅ 前端网关 (5173) TLS 握手正常"
            return 0
        fi
        sleep 2
    done
    echo "  ⚠️  前端网关 5173 握手失败，请检查：systemctl status nginx"
    return 1
}

# =============================================================================
# 主流程
# =============================================================================

echo "🔧 ARL-Next 源码模式一键启动"
echo "   部署目录: $REPO_DIR"
if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "   运行模式: 仅体检（不做任何改动）"
elif [ "$NO_START" -eq 1 ]; then
    echo "   运行模式: 补齐环境（不启动服务）"
else
    echo "   运行模式: 检查 → 补齐 → 启动"
fi
echo ""

detect_pkg_manager

echo "📋 正在检查环境..."
check_and_install_base_packages
check_and_install_massdns
check_and_install_nmap
check_and_install_nuclei
check_and_install_render_stack
check_and_setup_python_envs
check_and_setup_mongodb
check_and_setup_rabbitmq
check_and_fetch_geoip
check_and_setup_hosts
check_and_setup_config
check_and_build_frontend
check_and_setup_ssl
check_and_setup_nginx
check_and_setup_units

# -------------------- 体检模式收尾 --------------------
if [ "$CHECK_ONLY" -eq 1 ]; then
    echo ""
    if [ ${#MISSING_ITEMS[@]} -eq 0 ]; then
        echo "🎉 环境体检通过：所有组件均已就绪，可直接执行 'sudo bash start-local.sh' 启动服务。"
        exit 0
    fi
    echo "⚠️  环境体检发现 ${#MISSING_ITEMS[@]} 项缺失："
    local_item=""
    for local_item in "${MISSING_ITEMS[@]}"; do
        echo "   • $local_item"
    done
    echo ""
    echo "👉 执行 'sudo bash start-local.sh' 可自动补齐上述缺失项并启动服务。"
    exit 0
fi

# -------------------- 启动服务 --------------------
if [ "$NO_START" -eq 1 ]; then
    echo ""
    echo "✅ 环境已补齐。已按 --no-start 跳过服务启动。"
    echo "👉 手动启动：sudo systemctl start ${ARL_UNITS[*]}"
    exit 0
fi

echo ""
start_services
echo ""

if ! verify_health; then
    echo ""
    echo "⚠️  部分服务未通过健康检查，请按上方提示排查后重试。"
    exit 1
fi

# -------------------- 访问信息 --------------------
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$LOCAL_IP" ]; then
    LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
fi
if [ -z "$LOCAL_IP" ]; then
    LOCAL_IP="127.0.0.1"
fi
LOCAL_IP=$(echo "$LOCAL_IP" | xargs)

PUBLIC_IP=$(curl -s --max-time 1.5 ifconfig.me 2>/dev/null || echo "")
PUBLIC_IP=$(echo "$PUBLIC_IP" | xargs)

echo "🎉 ARL-Next 源码模式启动完成！"
echo "👉 请通过浏览器访问以下地址之一登录系统："
echo "   - 本地/局域网访问: https://$LOCAL_IP:5173"
if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "$LOCAL_IP" ]; then
    echo "   - 公网访问:        https://$PUBLIC_IP:5173"
fi
echo "   （首次使用自签名证书，浏览器会提示不安全，选择继续访问即可）"
echo ""
echo "┌────────────────────────────────────────────────────────────┐"
echo "│ 🔑 默认登录凭据：admin / arlpass                            │"
echo "│ 📊 服务状态：systemctl status arl-web arl-worker arl-osint  │"
echo "│              arl-puppeteer                                  │"
echo "│ 📜 查看日志：journalctl -u arl-worker -f                    │"
echo "│ 🔄 重启全栈：systemctl restart arl-web arl-worker arl-osint │"
echo "│              arl-puppeteer                                  │"
echo "│ 📖 部署文档：deploy/source/README.md                        │"
echo "└────────────────────────────────────────────────────────────┘"
