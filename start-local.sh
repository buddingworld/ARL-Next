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

注意: 本脚本目前仅支持 apt 系发行版（Debian / Ubuntu）。
      RHEL / CentOS 请参照 deploy/source/README.md 手动部署。
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

# ==================== 包管理器探测 ====================
detect_pkg_manager() {
    if have apt-get; then
        PKG_MANAGER="apt-get"
    elif have yum || have dnf; then
        echo "❌ 错误：本脚本目前仅支持 apt 系发行版（Debian / Ubuntu）。"
        echo "👉 检测到 RHEL 系包管理器，请参照 deploy/source/README.md 手动部署。"
        exit 1
    else
        echo "❌ 错误：未识别的包管理器，请参照 deploy/source/README.md 手动部署。"
        exit 1
    fi
}

pkg_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# ==================== 1. 系统依赖与编译工具链 ====================
check_and_install_base_packages() {
    # 抽样探测：这些齐了就认为基础环境完整，跳过整个 apt 流程（避免每次 apt-get update 的开销）
    local missing=0
    local cmd
    for cmd in gcc make curl wget unzip bzip2 git openssl nginx; do
        have "$cmd" || missing=1
    done
    dpkg -s libpcap-dev &>/dev/null || missing=1
    python3 -c "import venv" &>/dev/null || missing=1

    if [ $missing -eq 0 ]; then
        report_ok "系统依赖与编译工具链已就绪"
        return 0
    fi

    report_miss "系统依赖与编译工具链（build-essential / libpcap-dev / nginx 等）"
    [ "$CHECK_ONLY" -eq 1 ] && return 0

    run_with_spinner "更新软件包列表" apt-get update -o Acquire::Retries=10 || \
        die "apt-get update 失败，请检查网络或软件源配置。"

    run_with_spinner "安装系统依赖与编译工具链" pkg_install \
        wget unzip bzip2 git curl tzdata ca-certificates \
        make gcc g++ automake autoconf libtool python3-dev \
        libxml2-dev libxslt1-dev zlib1g-dev libffi-dev libssl-dev libpcap-dev \
        python3 python3-pip python3-venv openssl nginx \
        || die "系统依赖安装失败，请查看上方报错信息。"
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
        wget -q -t 10 https://github.com/blechschmidt/massdns/archive/refs/tags/v${MASSDNS_VERSION}.tar.gz \
          || wget -q -t 10 https://gh-proxy.com/https://github.com/blechschmidt/massdns/archive/refs/tags/v${MASSDNS_VERSION}.tar.gz
        tar xf v${MASSDNS_VERSION}.tar.gz
        cd massdns-${MASSDNS_VERSION}
        make -j\$(nproc)
        cp bin/massdns /usr/local/bin/
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
        arch="$(dpkg --print-architecture)"
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
            wget -q -t 10 'https://github.com/projectdiscovery/nuclei/releases/download/v${NUCLEI_VERSION}/${zip}' -O '${zip}' \
              || wget -q -t 10 'https://gh-proxy.com/https://github.com/projectdiscovery/nuclei/releases/download/v${NUCLEI_VERSION}/${zip}' -O '${zip}'
            unzip -o -q '${zip}'
            mv nuclei /usr/local/bin/
            chmod +x /usr/local/bin/nuclei
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

    run_with_spinner "拉取 nuclei 模板库（体积较大，请耐心等待）" nuclei -update-templates \
        || die "nuclei 模板拉取失败，请检查网络后重试。"
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
    else
        report_miss "Chromium（站点截图渲染内核，需位于 /usr/bin/chromium）"
        if [ "$CHECK_ONLY" -eq 0 ]; then
            run_with_spinner "安装 Chromium 与图形依赖库" pkg_install \
                chromium libnss3 libatk-bridge2.0-0 libgtk-3-0 libx11-xcb1 libxcb-dri3-0 \
                libxcomposite1 libxdamage1 libxrandr2 libgbm1 libasound2 \
                libxshmfence1 libdrm2 libxkbcommon0 libatspi2.0-0 libcups2 \
                fontconfig fonts-wqy-zenhei fonts-wqy-microhei \
                || echo "  ⚠️  Chromium 安装失败，截图与 Web 指纹识别功能将不可用。"
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
                npm install -g "puppeteer-core@$PUPPETEER_CORE_VERSION" \
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

    run_with_spinner "升级 $label pip" "$venv_dir/bin/pip" install --upgrade pip \
        || die "$label pip 升级失败。"

    run_with_spinner "安装 $label Python 依赖" "$venv_dir/bin/pip" install -r "$req_file" \
        || die "$label Python 依赖安装失败，请查看上方报错信息。"
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
            # 并用 --no-build-isolation 让该固定版本对 ARL-NPoC 的 editable 构建真正生效
            run_with_spinner "安装 ARL-NPoC（editable）" bash -c "
                set -e
                '$VENV/bin/pip' install 'setuptools<70.0.0' wheel
                '$VENV/bin/pip' install --no-build-isolation -e '$BACKEND_DIR/ARL-NPoC/'
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
mongo_ready() {
    have mongosh || return 1
    run_cmd_with_timeout 5 mongosh "mongodb://$MONGO_USER:$MONGO_PASS@127.0.0.1:27017/?authSource=admin" \
        --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q 1
}

check_and_setup_mongodb() {
    if ! have mongod; then
        report_miss "MongoDB 7.0"
        [ "$CHECK_ONLY" -eq 1 ] && return 0

        run_with_spinner "导入 MongoDB 官方软件源" bash -c "
            set -e
            curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
                | gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor
            echo 'deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main' \
                > /etc/apt/sources.list.d/mongodb-org-7.0.list
            apt-get update -o Acquire::Retries=10
        " || die "MongoDB 软件源导入失败，请检查网络。"

        run_with_spinner "安装 MongoDB 7.0" pkg_install mongodb-org \
            || die "MongoDB 安装失败。"
    else
        report_ok "MongoDB 已安装"
    fi

    run_with_spinner "启动 MongoDB 服务" bash -c "
        systemctl enable mongod >/dev/null 2>&1
        systemctl restart mongod
    " || die "MongoDB 启动失败，请执行 'journalctl -u mongod' 排查。"

    # 等待端口就绪
    local i
    for i in $(seq 1 30); do
        if run_cmd_with_timeout 3 bash -c "</dev/tcp/127.0.0.1/27017" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    if [ "$CHECK_ONLY" -eq 1 ]; then
        if grep -qE '^[[:space:]]*authorization[[:space:]]*:[[:space:]]*enabled' /etc/mongod.conf 2>/dev/null; then
            report_ok "MongoDB 鉴权已启用"
        else
            report_miss "MongoDB 鉴权未启用（security.authorization）"
        fi
        return 0
    fi

    # 幂等创建管理员账号（对应容器的 MONGO_INITDB_ROOT_USERNAME/PASSWORD=admin）
    # 未启用鉴权时免密即可创建；已启用且账号已存在时本步静默跳过，由末尾探针兜底校验
    run_with_spinner "确保 MongoDB 管理员账号存在" bash -c "
        mongosh --quiet --eval '
            const a = db.getSiblingDB(\"admin\");
            if (!a.getUser(\"$MONGO_USER\")) {
                a.createUser({user: \"$MONGO_USER\", pwd: \"$MONGO_PASS\",
                              roles: [{role: \"root\", db: \"admin\"}]});
                print(\"created\");
            } else { print(\"exists\"); }
        ' 2>/dev/null || true
    " || true

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
        echo "      否则请执行 'mongosh' 后手动创建："
        echo "      db.getSiblingDB(\"admin\").createUser({user:\"$MONGO_USER\", pwd:\"$MONGO_PASS\", roles:[{role:\"root\", db:\"admin\"}]})"
    fi
}

# ==================== 8. RabbitMQ ====================
check_and_setup_rabbitmq() {
    if have rabbitmq-server || dpkg -s rabbitmq-server &>/dev/null; then
        report_ok "RabbitMQ 已安装"
    else
        report_miss "RabbitMQ（Celery 消息队列）"
        [ "$CHECK_ONLY" -eq 1 ] && return 0
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

    # 不阻断部署：ip2region 拉取失败时服务仍以降级模式运行
    run_with_spinner "获取 GeoIP 数据库" \
        python3 "$REPO_DIR/tools/fetch_geoip.py" --dir "$geoip_dir" \
        || echo "  ⚠️  GeoIP 获取失败，不阻断部署（归属地解析将降级）。"
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

    # 与 frontend/Dockerfile.prod 一致：使用 pnpm 与 lockfile 冻结安装
    if ! have pnpm; then
        run_with_spinner "安装 pnpm@9" npm install -g pnpm@9 || die "pnpm 安装失败。"
    fi

    if [ -f "$FRONTEND_DIR/pnpm-lock.yaml" ]; then
        run_with_spinner "安装前端依赖（pnpm，冻结 lockfile）" \
            bash -c "cd '$FRONTEND_DIR' && pnpm install --frozen-lockfile" \
            || die "前端依赖安装失败。"
    else
        run_with_spinner "安装前端依赖（pnpm）" \
            bash -c "cd '$FRONTEND_DIR' && pnpm install" \
            || die "前端依赖安装失败。"
    fi

    # prebuild 会把 mcp-server/server.py 复制进 public/mcp，随 vite build 一并产出
    run_with_spinner "构建前端产物（含 .gz 预压缩）" \
        bash -c "cd '$FRONTEND_DIR' && pnpm run build" \
        || die "前端构建失败。"

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

check_and_setup_nginx() {
    local rendered
    rendered="$(mktemp)"
    render_template "$SRC_DIR/nginx-arl.conf" > "$rendered"

    if [ -f "$NGINX_CONF_DEST" ] && cmp -s "$rendered" "$NGINX_CONF_DEST"; then
        rm -f "$rendered"
        report_ok "Nginx 网关配置已是最新"
    else
        if [ ! -f "$NGINX_CONF_DEST" ]; then
            report_miss "Nginx 网关配置 ($NGINX_CONF_DEST)"
        else
            report_miss "Nginx 网关配置已变更（旧配置将备份）"
        fi

        if [ "$CHECK_ONLY" -eq 1 ]; then
            rm -f "$rendered"
            return 0
        fi

        if [ -f "$NGINX_CONF_DEST" ]; then
            cp -f "$NGINX_CONF_DEST" "$NGINX_CONF_DEST.bak_$(date +%Y%m%d%H%M%S)"
        fi
        mv -f "$rendered" "$NGINX_CONF_DEST"
        report_ok "已安装 Nginx 网关配置"
    fi

    [ "$CHECK_ONLY" -eq 1 ] && return 0

    run_with_spinner "校验 Nginx 配置语法" nginx -t || die "Nginx 配置校验失败，请检查上方报错。"

    run_with_spinner "启动并重载 Nginx" bash -c "
        systemctl enable nginx >/dev/null 2>&1
        systemctl start nginx 2>/dev/null || true
        systemctl reload nginx
    " || die "Nginx 启动/重载失败。"
}

# ==================== 15. systemd 服务单元 ====================
check_and_setup_units() {
    local changed=0
    local unit unit_file rendered

    for unit in "${ARL_UNITS[@]}"; do
        unit_file="$SYSTEMD_DIR/$unit.service"
        rendered="$(mktemp)"
        render_template "$SRC_DIR/$unit.service" > "$rendered"

        if [ -f "$unit_file" ] && cmp -s "$rendered" "$unit_file"; then
            rm -f "$rendered"
            continue
        fi

        changed=1
        if [ "$CHECK_ONLY" -eq 1 ]; then
            rm -f "$rendered"
            report_miss "systemd 服务单元 $unit.service"
            continue
        fi

        if [ -f "$unit_file" ]; then
            cp -f "$unit_file" "$unit_file.bak_$(date +%Y%m%d%H%M%S)"
        fi
        mv -f "$rendered" "$unit_file"
        report_ok "已安装 systemd 服务单元 $unit.service"
    done

    if [ $changed -eq 0 ]; then
        report_ok "systemd 服务单元已是最新"
    elif [ "$CHECK_ONLY" -eq 0 ]; then
        systemctl daemon-reload || die "systemctl daemon-reload 失败。"
    fi

    [ "$CHECK_ONLY" -eq 1 ] && return 0

    # 确保 worker 启动脚本可执行
    chmod +x "$SRC_DIR/start-worker.sh" 2>/dev/null || true
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
