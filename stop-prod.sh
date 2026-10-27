#!/bin/bash
# =============================================================================
# ARL-Next 生产服务一键停止脚本 (stop-prod.sh)
#
# 作用：停止 ARL-Next 全部生产容器与系统更新守护进程 (arl-updater)，仅释放运行态
#      资源。MongoDB 数据、站点截图、备份归档等命名卷完整保留，后续执行
#      start-prod.sh 即可原地恢复服务，数据零丢失。
#
# 用法：sudo bash stop-prod.sh
#
# 设计说明：本脚本刻意不使用 set -e —— 停止流程中每一步都显式判断返回值并打印
#          提示，避免单点失败导致「停到一半」的中间态难以排查。
# =============================================================================

# ==================== 前置校验 ====================
if [ "$EUID" -ne 0 ]; then
    echo "❌ 错误：停止容器与系统守护进程需要 root 权限，请使用 sudo 运行此脚本："
    echo "👉 sudo bash stop-prod.sh"
    exit 1
fi

# 强制切换到脚本所在目录，防止因外部调用导致的相对路径报错
cd "$(dirname "$0")" || exit 1

# ==================== 并发执行锁机制 ====================
# 与 start-prod.sh 共用同一把锁：杜绝「停止」与「部署 / 在线更新」并发执行导致状态错乱
LOCK_FILE="/tmp/arl_deploy.lock"
if command -v flock &>/dev/null; then
    exec 9> "$LOCK_FILE"
    if ! flock -n 9; then
        echo "❌ 错误：检测到另一个部署、更新或卸载任务正在运行中，请稍后再试。"
        exit 1
    fi
fi

# ==================== 常量定义 ====================
COMPOSE_FILE="docker-compose.prod.yml"
PROJECT_NAME="arl-next-prod"
UPDATER_SERVICE="arl-updater.service"

# 兜底容器名清单：极端场景下（历史版本容器缺失 Compose 项目标签）按容器名精确匹配
FALLBACK_CONTAINERS=(
    "arl-frontend-prod" "arl-web-prod" "arl-puppeteer-prod" "arl-worker-prod"
    "arl-mongodb-prod" "arl-rabbitmq-prod" "arl-osint-service-prod" "arl-autoheal"
)

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

# ==================== 环境探测辅助函数 ====================

# 探测 Docker 守护进程是否就绪（timeout 兜底：卡死态 daemon 会让 docker info 无限阻塞）
docker_ready() {
    if command -v timeout &>/dev/null; then
        timeout 3 docker info &>/dev/null
    else
        docker info &>/dev/null
    fi
}

# 探测可用的 Compose 命令（v2 插件优先，独立二进制兜底）
detect_compose_cmd() {
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        COMPOSE_CMD=""
    fi
}

# 收集本项目容器名：优先 Compose 项目标签，兜底按固定容器名精确匹配
collect_project_containers() {
    local -a found=()
    local name

    while IFS= read -r name; do
        [ -n "$name" ] && found+=("$name")
    done < <(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.Names}}' 2>/dev/null)

    local item exists
    for name in "${FALLBACK_CONTAINERS[@]}"; do
        exists=0
        for item in "${found[@]}"; do
            if [ "$item" = "$name" ]; then
                exists=1
                break
            fi
        done
        # 仅在容器真实存在时补入，避免把不存在的名字带入后续命令
        if [ $exists -eq 0 ] && docker inspect -f '{{.Id}}' "$name" &>/dev/null; then
            found+=("$name")
        fi
    done

    if [ ${#found[@]} -gt 0 ]; then
        printf '%s\n' "${found[@]}"
    fi
}

# 过滤出仍处于运行态的容器
filter_running_containers() {
    local name state
    for name in $1; do
        state=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
        if [ "$state" = "true" ]; then
            printf '%s\n' "$name"
        fi
    done
}

# ==================== 主流程 ====================

echo "🚛 开始停止 ARL-Next 生产服务..."
echo ""

# 1. 环境探测
if ! command -v docker &>/dev/null; then
    echo "ℹ️  未检测到 Docker，本机不存在由 start-prod.sh 部署的容器服务，无需停止。"
    exit 0
fi

DOCKER_READY=0
if docker_ready; then
    DOCKER_READY=1
else
    echo "⚠️  Docker 守护进程未运行（容器已随守护进程一并停止）。"
fi

CONTAINERS=""
if [ "$DOCKER_READY" -eq 1 ]; then
    CONTAINERS=$(collect_project_containers)
fi

UPDATER_ACTIVE=0
if command -v systemctl &>/dev/null && systemctl is-active "$UPDATER_SERVICE" &>/dev/null; then
    UPDATER_ACTIVE=1
fi

# 非 systemd 托管环境（手动 nohup 启动）的兜底探测，避免残留进程占用 8888 端口
UPDATER_STRAY=0
if command -v pgrep &>/dev/null && pgrep -f "updater/updater.py" &>/dev/null; then
    UPDATER_STRAY=1
fi

if [ -z "$CONTAINERS" ] && [ "$UPDATER_ACTIVE" -eq 0 ] && [ "$UPDATER_STRAY" -eq 0 ]; then
    echo "ℹ️  未检测到任何运行中的 ARL-Next 服务（容器与更新守护进程均已停止），无需操作。"
    exit 0
fi

# 2. 停止系统更新守护服务
echo "🛑 [1/3] 正在停止系统更新守护服务 (arl-updater)..."
if [ "$UPDATER_ACTIVE" -eq 1 ]; then
    systemctl stop "$UPDATER_SERVICE" 2>/dev/null || true
    # 同步禁用开机自启，保证「已停止」状态在重启后依然成立；
    # start-prod.sh 部署时会自动重新 enable，无需人工恢复
    systemctl disable "$UPDATER_SERVICE" 2>/dev/null || true

    if systemctl is-active "$UPDATER_SERVICE" &>/dev/null; then
        echo "  ⚠️  系统更新守护服务停止异常，请执行 'journalctl -u $UPDATER_SERVICE' 排查。"
    else
        echo "  ✅ 系统更新守护服务已停止并禁用开机自启（start-prod.sh 会自动重新启用）"
    fi
else
    if [ "$UPDATER_STRAY" -eq 1 ]; then
        echo "  ℹ️  未检测到 systemd 托管的更新服务，正在清理手动启动的残留进程..."
    else
        echo "  ℹ️  系统更新守护服务当前未运行，跳过。"
    fi
fi

# 兜底清理脱离 systemd 托管的残留 updater 进程（如手动 nohup 启动）
if command -v pgrep &>/dev/null; then
    for pid in $(pgrep -f "updater/updater.py" 2>/dev/null); do
        [ "$pid" = "$$" ] && continue
        kill "$pid" 2>/dev/null || true
    done
fi

# 3. 停止并移除生产容器组
echo "🐳 [2/3] 正在停止生产容器组（数据卷保留）..."
if [ "$DOCKER_READY" -eq 1 ] && [ -n "$CONTAINERS" ]; then
    detect_compose_cmd
    if [ -n "$COMPOSE_CMD" ] && [ -f "$COMPOSE_FILE" ]; then
        # 容器组整体下线：移除容器与专属网络，命名卷（数据）不受影响
        # worker 容器配置了 stop_grace_period: 1m，正在执行的扫描任务会等待优雅退出
        run_with_spinner "停止并移除生产容器组" $COMPOSE_CMD -f "$COMPOSE_FILE" down --remove-orphans
    else
        echo "  ⚠️  未检测到可用的 Compose 命令或编排文件 $COMPOSE_FILE，回退为按容器名停止..."
        run_with_spinner "停止生产容器组" docker stop $CONTAINERS
    fi

    # 兜底复核：若因编排文件版本不一致导致仍有容器在跑，逐个补停
    REMAINING=$(filter_running_containers "$CONTAINERS")
    if [ -n "$REMAINING" ]; then
        echo "  ⚠️  检测到未随编排下线的残留容器，正在补停..."
        run_with_spinner "补停残留容器" docker stop $REMAINING
    fi
else
    echo "  ℹ️  未检测到运行中的生产容器，跳过。"
fi

# 4. 结果校验
echo "🔍 [3/3] 正在校验停止结果..."
STILL_RUNNING=""
if [ "$DOCKER_READY" -eq 1 ]; then
    STILL_RUNNING=$(filter_running_containers "$(collect_project_containers)")
fi

PORT_8888_BUSY=0
PORT_PID=""
if command -v ss &>/dev/null; then
    PORT_PID=$(ss -tlnp 2>/dev/null | awk '/:8888 / {print $NF}' | sed -E 's/.*pid=([0-9]+).*/\1/' | head -n 1)
elif command -v netstat &>/dev/null; then
    PORT_PID=$(netstat -tlnp 2>/dev/null | awk '/:8888 / {print $NF}' | cut -d'/' -f1 | head -n 1)
fi

# 仅在 8888 端口被 ARL 更新守护进程本身占用时才判定为残留，
# 避免宿主机上无关服务占用该端口导致误报
if [ -n "$PORT_PID" ] && [ "$PORT_PID" -gt 10 ] 2>/dev/null; then
    PORT_CMD=$(ps -p "$PORT_PID" -o cmd= 2>/dev/null || true)
    if [ -n "$PORT_CMD" ] && echo "$PORT_CMD" | grep -q "updater.py"; then
        PORT_8888_BUSY=1
    fi
fi

echo ""
if [ -n "$STILL_RUNNING" ] || [ "$PORT_8888_BUSY" -eq 1 ]; then
    echo "⚠️  停止结果存在残留，请人工确认："
    [ -n "$STILL_RUNNING" ] && echo "   仍在运行的容器：$(echo "$STILL_RUNNING" | tr '\n' ' ')"
    [ "$PORT_8888_BUSY" -eq 1 ] && echo "   8888 端口仍被占用（更新守护服务未完全退出）"
    exit 1
fi

# 统计保留的数据卷，便于用户确认数据未受影响
VOLUME_COUNT=0
if [ "$DOCKER_READY" -eq 1 ]; then
    VOLUME_COUNT=$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT_NAME" 2>/dev/null | wc -l | tr -d ' ')
fi

echo "🎉 ARL-Next 生产服务已全部停止！"
echo ""
echo "┌────────────────────────────────────────────────────────────┐"
echo "│ 📦 数据卷（MongoDB 数据 / 站点截图 / 备份归档）已完整保留   │"
echo "│ 🚀 重新启动服务：sudo bash start-prod.sh                    │"
echo "│ 🗑️  彻底卸载并清除数据：sudo bash uninstall-prod.sh         │"
echo "└────────────────────────────────────────────────────────────┘"
if [ "$VOLUME_COUNT" -gt 0 ] 2>/dev/null; then
    echo "   （本次共保留 $VOLUME_COUNT 个数据卷，服务恢复后数据原样可用）"
fi
