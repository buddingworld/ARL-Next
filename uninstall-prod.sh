#!/bin/bash
# =============================================================================
# ARL-Next 生产环境一键卸载脚本 (uninstall-prod.sh)
#
# 作用：彻底移除由 start-prod.sh 部署的全部生产资源：
#       ① 容器组 / 专属网络 / 数据卷（数据卷可用 --keep-data 保留）
#       ② 阿里云私库镜像与 backup-stable 回滚快照
#       ③ 系统更新守护服务 (arl-updater.service)
#       ④ 部署过程产生的运行时临时文件
#       可选：--purge-host 回滚宿主机调优（内核参数 / Swap / Docker 调优 / 防火墙放行）
#             --purge-files 删除部署生成的本地文件（自签证书 / Basic Auth 凭据等）
#
# 用法：sudo bash uninstall-prod.sh [选项]
#
# 设计说明：本脚本刻意不使用 set -e —— 卸载流程中每一步都显式判断返回值并打印提示，
#          避免单点失败导致「卸到一半」的中间态难以排查。删除数据卷属于不可逆操作，
#          脚本会在删除前打印完整影响清单并要求二次确认。
# =============================================================================

# ==================== 参数解析 ====================
ASSUME_YES=0      # 跳过交互确认（自动化场景）
KEEP_DATA=0       # 保留数据卷（仅移除容器与镜像）
DO_BACKUP=0       # 卸载前强制创建全量备份
PURGE_HOST=0      # 回滚宿主机层面的调优配置
PURGE_FILES=0     # 删除部署生成的本地文件

usage() {
    cat <<'EOF'
ARL-Next 生产环境一键卸载脚本

用法: sudo bash uninstall-prod.sh [选项]

选项:
  -y, --yes        跳过全部交互确认（自动化场景；默认不额外备份、不回滚宿主机配置）
      --keep-data  保留数据卷（MongoDB 数据 / 站点截图 / 备份归档），仅移除容器与镜像
      --backup     卸载前自动创建一次全量数据备份，并导出到部署目录下的时间戳子目录
      --purge-host 同时回滚宿主机层面的调优（sysctl 内核参数 / 2G Swap 文件 /
                   Docker userland-proxy 调优 / firewalld 端口放行与 docker0 信任域）
      --purge-files 同时删除部署生成的本地文件（自签证书 / certs 目录 /
                   frontend/.htpasswd / 编排文件历史备份）
  -h, --help       显示本帮助信息

示例:
  sudo bash uninstall-prod.sh                 # 交互式完整卸载（含删除数据卷）
  sudo bash uninstall-prod.sh --keep-data     # 仅卸载程序，保留全部业务数据
  sudo bash uninstall-prod.sh --backup        # 卸载前先备份数据并导出到宿主机
  sudo bash uninstall-prod.sh -y --purge-host --purge-files   # 全自动彻底卸载
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)       ASSUME_YES=1 ;;
        --keep-data)    KEEP_DATA=1 ;;
        --backup)       DO_BACKUP=1 ;;
        --purge-host)   PURGE_HOST=1 ;;
        --purge-files)  PURGE_FILES=1 ;;
        -h|--help)      usage; exit 0 ;;
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
    echo "❌ 错误：卸载容器、镜像与系统守护进程需要 root 权限，请使用 sudo 运行此脚本："
    echo "👉 sudo bash uninstall-prod.sh"
    exit 1
fi

# 强制切换到脚本所在目录，防止因外部调用导致的相对路径报错
cd "$(dirname "$0")" || exit 1
DEPLOY_DIR="$(pwd)"

# ==================== 并发执行锁机制 ====================
# 与 start-prod.sh 共用同一把锁：杜绝「卸载」与「部署 / 在线更新」并发执行导致状态错乱
LOCK_FILE="/tmp/arl_deploy.lock"
if command -v flock &>/dev/null; then
    exec 9> "$LOCK_FILE"
    if ! flock -n 9; then
        echo "❌ 错误：检测到另一个部署、更新或停止任务正在运行中，请稍后再试。"
        exit 1
    fi
fi

# ==================== 常量定义 ====================
COMPOSE_FILE="docker-compose.prod.yml"
PROJECT_NAME="arl-next-prod"
UPDATER_SERVICE="arl-updater.service"
UPDATER_UNIT_FILE="/etc/systemd/system/$UPDATER_SERVICE"
IMAGE_REPO_KEYWORD="owl234-arl-prod/"

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

# ==================== 环境探测辅助函数 ====================

# 探测 Docker 守护进程是否就绪（timeout 兜底：卡死态 daemon 会让 docker info 无限阻塞）
docker_ready() {
    if command -v timeout &>/dev/null; then
        timeout 3 docker info &>/dev/null
    else
        docker info &>/dev/null
    fi
}

# 卸载需要移除容器/卷，因此守护进程必须就绪；未就绪则尝试拉起
ensure_docker_ready() {
    docker_ready && return 0

    echo "⚠️  Docker 守护进程未运行，正在尝试启动以完成容器与镜像清理..."
    if command -v systemctl &>/dev/null; then
        run_cmd_with_timeout 30 systemctl start docker 2>/dev/null || true
    elif command -v service &>/dev/null; then
        run_cmd_with_timeout 30 service docker start 2>/dev/null || true
    fi

    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        docker_ready && return 0
        sleep 1
    done
    return 1
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

# ==================== 资源清单收集 ====================

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

collect_project_volumes() {
    docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT_NAME" 2>/dev/null
}

collect_project_networks() {
    docker network ls -q --filter "label=com.docker.compose.project=$PROJECT_NAME" 2>/dev/null
}

# 收集本项目镜像：阿里云私库制品 + 部署时打标的 backup-stable 回滚快照
collect_project_images() {
    {
        docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -F "$IMAGE_REPO_KEYWORD"
        docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -F ':backup-stable'
    } | grep -v '^<none>' | sort -u
}

# 判断证书是否为 start-prod.sh 自动签发的临时自签证书（O=ARL），
# 用于避免误删用户自行放置的真实域名证书
# 注：OpenSSL 1.1.1+ 的 -subject 默认输出形如 "O = ARL"（等号两侧带空格），
#     故此处使用宽松正则兼容 "O=ARL" 与 "O = ARL" 两种格式
is_self_signed_cert() {
    local crt="$1"
    [ -f "$crt" ] || return 1
    command -v openssl &>/dev/null || return 1
    openssl x509 -in "$crt" -noout -subject 2>/dev/null | grep -qE "O *= *ARL"
}

# ==================== 卸载前全量数据备份 ====================

# 通过容器内的备份服务生成归档，并导出到宿主机指定目录（返回导出成功的包数量）
export_all_backups() {
    local export_dir="$1"
    local archives f count=0

    archives=$(docker exec arl-web-prod sh -c 'ls -1 /code/backend/data/backups/*.tar.gz 2>/dev/null' || true)
    if [ -z "$archives" ]; then
        echo "0"
        return 0
    fi

    for f in $archives; do
        if docker cp "arl-web-prod:$f" "$export_dir/" >/dev/null 2>&1; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

run_pre_uninstall_backup() {
    # 备份依赖后端服务在线（容器内直连 MongoDB 执行 mongodump）
    if [ "$(docker inspect -f '{{.State.Running}}' arl-web-prod 2>/dev/null)" != "true" ]; then
        echo "❌ 错误：arl-web-prod 容器未运行，无法执行在线备份。"
        echo "👉 请先执行 'sudo bash start-prod.sh' 拉起服务后再卸载，或改用 --keep-data 保留数据卷。"
        return 1
    fi

    # 导出前预检宿主机磁盘空间，避免备份包导出中途写满磁盘
    local need_kb free_kb
    need_kb=$(docker exec arl-web-prod du -sk /code/backend/data/backups 2>/dev/null | awk '{print $1}')
    free_kb=$(df -k "$DEPLOY_DIR" | awk 'NR==2 {print $4}')
    if [ -n "$need_kb" ] && [ -n "$free_kb" ] && [ "$free_kb" -lt "$need_kb" ] 2>/dev/null; then
        echo "❌ 错误：宿主机剩余空间不足（备份数据约 $((need_kb / 1024))MB，可用 $((free_kb / 1024))MB）。"
        echo "👉 请先清理磁盘，或改用 --keep-data 保留数据卷。"
        return 1
    fi

    cat > /tmp/arl_uninstall_backup.py <<'PY'
import sys, json
sys.path.insert(0, "/code/backend")
from app.services.backup_service import create_backup_archive
res = create_backup_archive(include_screenshots=True, note="卸载前全量快照 (uninstall-prod.sh)")
print("[BACKUP_RESULT] " + json.dumps({"archive_name": res.get("archive_name"), "size": res.get("size")}, ensure_ascii=False))
PY

    if ! docker cp /tmp/arl_uninstall_backup.py arl-web-prod:/tmp/arl_uninstall_backup.py >/dev/null 2>&1; then
        echo "❌ 错误：备份脚本注入容器失败。"
        rm -f /tmp/arl_uninstall_backup.py
        return 1
    fi

    if ! run_with_spinner "执行全量数据备份（数据量大时耗时较长，请耐心等待）" \
        docker exec arl-web-prod /code/backend/.venv-docker/bin/python3 /tmp/arl_uninstall_backup.py; then
        rm -f /tmp/arl_uninstall_backup.py
        return 1
    fi
    rm -f /tmp/arl_uninstall_backup.py

    EXPORT_DIR="$DEPLOY_DIR/arl-uninstall-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$EXPORT_DIR"

    local exported
    exported=$(export_all_backups "$EXPORT_DIR")
    if [ -z "$exported" ] || [ "$exported" -eq 0 ] 2>/dev/null; then
        echo "❌ 错误：备份包导出宿主机失败，已中止卸载以保护数据。"
        echo "👉 备份归档仍完整保存在数据卷 arl_backups 中，可重试或改用 --keep-data。"
        rmdir "$EXPORT_DIR" 2>/dev/null || true
        return 1
    fi

    echo "  📦 已导出 $exported 个备份包至：$EXPORT_DIR"
    echo "  👉 重新部署后可在 Web 界面「系统设置 → 系统全量数据备份与恢复」上传该备份包并一键恢复。"
    return 0
}

# ==================== 宿主机层面回滚 (--purge-host) ====================
purge_host_configs() {
    echo "⚙️  正在回滚宿主机层面的调优配置..."

    # 1. 内核参数：移除 start-prod.sh 写入的持久化配置，并恢复内核默认值
    if [ -f /etc/sysctl.conf ]; then
        sed -i -e '/^vm\.swappiness[[:space:]]*=/d' \
               -e '/^vm\.vfs_cache_pressure[[:space:]]*=/d' \
               -e '/^vm\.overcommit_memory[[:space:]]*=/d' /etc/sysctl.conf 2>/dev/null || true
    fi
    sysctl -w vm.swappiness=60 &>/dev/null || true
    sysctl -w vm.vfs_cache_pressure=100 &>/dev/null || true
    sysctl -w vm.overcommit_memory=0 &>/dev/null || true
    echo "  ✅ 内核参数已恢复系统默认值 (swappiness=60 / vfs_cache_pressure=100 / overcommit_memory=0)"
    echo "  ℹ️  若宿主机另有 Redis / MongoDB 等依赖 overcommit_memory=1 的服务，请自行重新配置。"

    # 2. Swap 文件：仅当 fstab 中的挂载项与 start-prod.sh 写入的内容完全一致时才回收，
    #    避免误删用户自行配置的 Swap
    if [ -f /swapfile ] && grep -qxF "/swapfile none swap sw 0 0" /etc/fstab 2>/dev/null; then
        if run_cmd_with_timeout 60 swapoff /swapfile 2>/dev/null; then
            rm -f /swapfile
            sed -i '\|^/swapfile none swap sw 0 0$|d' /etc/fstab 2>/dev/null || true
            echo "  ✅ 已回收 start-prod.sh 创建的 2G Swap 文件"
        else
            echo "  ⚠️  /swapfile 关闭失败（可能内存紧张或仍在使用），已保留该文件与 fstab 配置。"
        fi
    else
        echo "  ℹ️  未检测到由本系统创建的 Swap 文件，跳过。"
    fi

    # 3. Docker 调优：移除 start-prod.sh 写入的 userland-proxy 配置
    if [ -f /etc/docker/daemon.json ] && command -v python3 &>/dev/null; then
        local removed
        removed=$(python3 - <<'PY'
import json, os
path = "/etc/docker/daemon.json"
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    print("SKIP")
    raise SystemExit(0)
if "userland-proxy" in data:
    data.pop("userland-proxy")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=4)
    os.replace(tmp, path)
    print("REMOVED")
else:
    print("SKIP")
PY
)
        if [ "$removed" = "REMOVED" ]; then
            echo "  ✅ 已移除 Docker 'userland-proxy' 调优配置（重启 Docker 后生效：systemctl restart docker）"
        else
            echo "  ℹ️  Docker 配置中未发现本系统写入的调优项，跳过。"
        fi
    fi

    # 4. 防火墙：移除 start-prod.sh 放行的端口与 docker0 信任域
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        local changed=0
        if firewall-cmd --list-ports 2>/dev/null | grep -qw "5173/tcp"; then
            firewall-cmd --permanent --remove-port=5173/tcp >/dev/null 2>&1 && changed=1
        fi
        if firewall-cmd --list-ports 2>/dev/null | grep -qw "8888/tcp"; then
            firewall-cmd --permanent --remove-port=8888/tcp >/dev/null 2>&1 && changed=1
        fi
        if firewall-cmd --zone=trusted --list-interfaces 2>/dev/null | grep -qw "docker0"; then
            firewall-cmd --permanent --zone=trusted --remove-interface=docker0 >/dev/null 2>&1 && changed=1
        fi

        if [ $changed -eq 1 ]; then
            echo "  ⚠️  正在重载 firewalld 规则并联动重启 Docker 恢复内核转发链（宿主机其他容器会短暂重启）..."
            firewall-cmd --reload >/dev/null 2>&1 || true
            if (run_cmd_with_timeout 30 systemctl restart docker &>/dev/null || run_cmd_with_timeout 30 service docker restart &>/dev/null); then
                local i
                for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
                    docker_ready && break
                    sleep 1
                done
                echo "  ✅ 防火墙规则已回收，Docker 转发链已恢复"
            else
                echo "  ⚠️  Docker 重启失败，若宿主机其他容器网络异常，请手动执行 'systemctl restart docker'"
            fi
        else
            echo "  ℹ️  未发现本系统写入的防火墙放行规则，跳过。"
        fi
    fi
}

# ==================== 部署生成文件清理 (--purge-files) ====================
purge_local_files() {
    echo "📁 正在清理部署生成的本地文件..."

    # 自签证书：仅在确认为本系统自动签发时删除，真实域名证书一律保留
    if [ -d ./ssl-certs ]; then
        if is_self_signed_cert ./ssl-certs/arl.crt; then
            rm -rf ./ssl-certs
            echo "  ✅ 已删除自动签发的临时证书目录 ssl-certs/"
        else
            echo "  ⚠️  ssl-certs/ 中检测到非自动签发的证书（疑似真实域名证书），已保留。"
        fi
    fi

    # MCP 客户端证书副本（由 start-prod.sh 从 ssl-certs 同步而来）
    if [ -f ./certs/arl.crt ] && is_self_signed_cert ./certs/arl.crt; then
        rm -rf ./certs
        echo "  ✅ 已删除 MCP 证书副本目录 certs/"
    fi

    if [ -f ./frontend/.htpasswd ]; then
        rm -f ./frontend/.htpasswd
        echo "  ✅ 已删除 Basic Auth 凭据文件 frontend/.htpasswd"
    fi

    local bak f
    bak=$(ls -1 ./docker-compose.prod.yml.bak_* 2>/dev/null || true)
    if [ -n "$bak" ]; then
        for f in $bak; do
            rm -f "$f"
        done
        echo "  ✅ 已删除编排文件历史备份 $(echo "$bak" | wc -l | tr -d ' ') 个"
    fi
}

# =============================================================================
# 主流程
# =============================================================================

echo "🗑️  ARL-Next 生产环境卸载程序"
echo ""

DOCKER_OK=0
if command -v docker &>/dev/null; then
    if ensure_docker_ready; then
        DOCKER_OK=1
    else
        echo "⚠️  Docker 守护进程无法就绪，容器 / 镜像 / 数据卷清理将被跳过（请稍后手动清理）。"
    fi
else
    echo "⚠️  未检测到 Docker，容器 / 镜像 / 数据卷清理将被跳过。"
fi
echo ""

# -------------------- 1. 影响范围预扫描 --------------------
CONTAINERS=""
VOLUMES=""
NETWORKS=""
IMAGES=""
if [ "$DOCKER_OK" -eq 1 ]; then
    CONTAINERS=$(collect_project_containers)
    VOLUMES=$(collect_project_volumes)
    NETWORKS=$(collect_project_networks)
    IMAGES=$(collect_project_images)
fi

UPDATER_INSTALLED=0
[ -f "$UPDATER_UNIT_FILE" ] && UPDATER_INSTALLED=1

count_lines() {
    if [ -z "$1" ]; then
        echo 0
    else
        echo "$1" | grep -c .
    fi
}

CONTAINER_COUNT=$(count_lines "$CONTAINERS")
VOLUME_COUNT=$(count_lines "$VOLUMES")
IMAGE_COUNT=$(count_lines "$IMAGES")

echo "📋 影响范围预扫描："
if [ "$CONTAINER_COUNT" -gt 0 ]; then
    echo "   • 容器 ($CONTAINER_COUNT): $(echo "$CONTAINERS" | tr '\n' ' ')"
else
    echo "   • 容器: 无"
fi

if [ "$KEEP_DATA" -eq 1 ]; then
    echo "   • 数据卷 ($VOLUME_COUNT): 已指定 --keep-data，将完整保留"
else
    if [ "$VOLUME_COUNT" -gt 0 ]; then
        echo "   • 数据卷 ($VOLUME_COUNT): $(echo "$VOLUMES" | tr '\n' ' ')"
        echo "     ⚠️  包含 MongoDB 全部业务数据与备份归档，删除后不可恢复！"
    else
        echo "   • 数据卷: 无"
    fi
fi

if [ "$IMAGE_COUNT" -gt 0 ]; then
    echo "   • 镜像 ($IMAGE_COUNT): 阿里云私库制品与 backup-stable 回滚快照"
else
    echo "   • 镜像: 无"
fi

if [ "$UPDATER_INSTALLED" -eq 1 ]; then
    echo "   • 系统服务: $UPDATER_SERVICE"
else
    echo "   • 系统服务: 无"
fi

if [ "$PURGE_HOST" -eq 1 ]; then
    echo "   • 宿主机配置: 内核参数 / Swap 文件 / Docker 调优 / firewalld 放行规则（已指定 --purge-host）"
fi
if [ "$PURGE_FILES" -eq 1 ]; then
    echo "   • 本地文件: 自签证书 / Basic Auth 凭据 / 编排文件历史备份（已指定 --purge-files）"
fi
echo ""

if [ "$CONTAINER_COUNT" -eq 0 ] && [ "$VOLUME_COUNT" -eq 0 ] && [ "$UPDATER_INSTALLED" -eq 0 ] \
    && [ "$PURGE_HOST" -eq 0 ] && [ "$PURGE_FILES" -eq 0 ]; then
    echo "ℹ️  未检测到任何 ARL-Next 部署痕迹，无需卸载。"
    exit 0
fi

# -------------------- 2. 二次确认 --------------------
if [ "$ASSUME_YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
        echo "❌ 错误：当前为非交互式环境，请显式追加 -y 参数以确认卸载。"
        exit 1
    fi

    if [ "$KEEP_DATA" -eq 0 ] && [ "$VOLUME_COUNT" -gt 0 ]; then
        echo "⚠️  此操作将永久删除上述全部容器、数据卷与镜像，删除后数据不可恢复！"
        read -r -p "请输入 yes 确认执行卸载（输入其他任意内容将取消）: " CONFIRM_INPUT
        if [ "$(echo "$CONFIRM_INPUT" | tr '[:upper:]' '[:lower:]')" != "yes" ]; then
            echo "操作已取消。"
            exit 0
        fi
    else
        read -r -p "确认执行卸载？[y/N]: " CONFIRM_INPUT
        case "$CONFIRM_INPUT" in
            [yY]*) ;;
            *) echo "操作已取消。"; exit 0 ;;
        esac
    fi

    # 数据卷即将被删除时，默认引导用户先做一次备份
    if [ "$KEEP_DATA" -eq 0 ] && [ "$VOLUME_COUNT" -gt 0 ] && [ "$DOCKER_OK" -eq 1 ]; then
        read -r -p "❓ 是否在删除前创建一次全量数据备份？(强烈建议) [Y/n]: " BACKUP_INPUT
        case "$BACKUP_INPUT" in
            [nN]*) DO_BACKUP=0 ;;
            *)     DO_BACKUP=1 ;;
        esac
    fi
fi

# -------------------- 3. 卸载前备份 --------------------
if [ "$DO_BACKUP" -eq 1 ]; then
    echo ""
    echo "💾 正在创建卸载前全量数据备份..."
    if ! run_pre_uninstall_backup; then
        echo "❌ 备份失败，已中止卸载（数据未被改动）。"
        exit 1
    fi
fi

echo ""
echo "🚀 开始执行卸载..."

# -------------------- 4. 停止并移除容器组 --------------------
if [ "$DOCKER_OK" -eq 1 ] && [ "$CONTAINER_COUNT" -gt 0 ]; then
    detect_compose_cmd
    if [ -n "$COMPOSE_CMD" ] && [ -f "$COMPOSE_FILE" ]; then
        if [ "$KEEP_DATA" -eq 1 ]; then
            run_with_spinner "移除容器组与专属网络（保留数据卷）" \
                $COMPOSE_CMD -f "$COMPOSE_FILE" down --remove-orphans
        else
            run_with_spinner "移除容器组、专属网络与数据卷" \
                $COMPOSE_CMD -f "$COMPOSE_FILE" down --remove-orphans --volumes
        fi
    else
        echo "  ⚠️  未检测到可用的 Compose 命令或编排文件 $COMPOSE_FILE，回退为按容器名移除..."
        run_with_spinner "移除生产容器" docker rm -f $CONTAINERS
    fi

    # 兜底复核：编排文件版本不一致时可能残留容器，逐个强制移除
    REMAINING=$(collect_project_containers)
    if [ -n "$REMAINING" ]; then
        run_with_spinner "强制清理残留容器" docker rm -f $REMAINING
    fi
fi

# -------------------- 5. 清理数据卷与网络 --------------------
if [ "$DOCKER_OK" -eq 1 ]; then
    if [ "$KEEP_DATA" -eq 0 ]; then
        LEFT_VOLUMES=$(collect_project_volumes)
        if [ -n "$LEFT_VOLUMES" ]; then
            run_with_spinner "清理残留数据卷" docker volume rm $LEFT_VOLUMES
        fi
    fi

    LEFT_NETWORKS=$(collect_project_networks)
    if [ -n "$LEFT_NETWORKS" ]; then
        run_with_spinner "清理残留网络" docker network rm $LEFT_NETWORKS
    fi

    # -------------------- 6. 清理镜像 --------------------
    IMAGES=$(collect_project_images)
    if [ -n "$IMAGES" ]; then
        # 镜像可能被宿主机其他项目复用，清理失败不阻断卸载流程
        run_with_spinner "清理 ARL-Next 镜像与回滚快照" docker rmi $IMAGES
    fi
fi

# -------------------- 7. 移除系统更新守护服务 --------------------
echo "🛑 正在移除系统更新守护服务 ($UPDATER_SERVICE)..."
if [ "$UPDATER_INSTALLED" -eq 1 ] && command -v systemctl &>/dev/null; then
    systemctl stop "$UPDATER_SERVICE" 2>/dev/null || true
    systemctl disable "$UPDATER_SERVICE" 2>/dev/null || true
    rm -f "$UPDATER_UNIT_FILE"
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "$UPDATER_SERVICE" 2>/dev/null || true
    echo "  ✅ 系统更新守护服务已停止、禁用并删除"
else
    echo "  ℹ️  未检测到 systemd 托管的更新守护服务，跳过。"
fi

# 兜底清理脱离 systemd 托管的残留 updater 进程（如手动 nohup 启动）
if command -v pgrep &>/dev/null; then
    for pid in $(pgrep -f "updater/updater.py" 2>/dev/null); do
        [ "$pid" = "$$" ] && continue
        kill "$pid" 2>/dev/null || true
    done
fi

# -------------------- 8. 宿主机配置回滚（可选） --------------------
if [ "$PURGE_HOST" -eq 1 ]; then
    purge_host_configs
fi

# -------------------- 9. 本地生成文件清理（可选） --------------------
if [ "$PURGE_FILES" -eq 1 ]; then
    purge_local_files
fi

# -------------------- 10. 临时文件清理 --------------------
# 保留 /tmp/arl_dockerd.log 的删除时机与 start-prod.sh 一致：卸载后已无排障价值，一并清理
rm -f /tmp/arl_pull_step.log /tmp/arl_deploy_step.log /tmp/arl_dockerd.log \
      /tmp/arl_update_token /tmp/arl_update.log /tmp/arl_uninstall_backup.py 2>/dev/null || true

# -------------------- 11. 结果校验与汇总 --------------------
echo ""
echo "🔍 正在校验卸载结果..."

RESIDUAL=""
if [ "$DOCKER_OK" -eq 1 ]; then
    LEFT_C=$(collect_project_containers)
    [ -n "$LEFT_C" ] && RESIDUAL="${RESIDUAL}      容器: $(echo "$LEFT_C" | tr '\n' ' ')\n"
    # --keep-data 时数据卷属于预期保留项，不计入残留告警
    if [ "$KEEP_DATA" -eq 0 ]; then
        LEFT_V=$(collect_project_volumes)
        [ -n "$LEFT_V" ] && RESIDUAL="${RESIDUAL}      数据卷: $(echo "$LEFT_V" | tr '\n' ' ')\n"
    fi
fi
[ -f "$UPDATER_UNIT_FILE" ] && RESIDUAL="${RESIDUAL}      系统服务: $UPDATER_SERVICE\n"

echo ""
if [ -n "$RESIDUAL" ]; then
    echo "⚠️  卸载完成，但以下资源未能清理干净，请人工确认："
    printf "%b" "$RESIDUAL"
else
    echo "🎉 ARL-Next 已成功卸载！"
fi

echo ""
echo "┌────────────────────────────────────────────────────────────┐"
echo "│ 📁 部署目录本身未删除，如需彻底清理请手动执行：             │"
echo "│    cd .. && rm -rf $(basename "$DEPLOY_DIR")"
echo "└────────────────────────────────────────────────────────────┘"
echo "   部署目录: $DEPLOY_DIR"

if [ "$KEEP_DATA" -eq 1 ] && [ "$VOLUME_COUNT" -gt 0 ]; then
    echo ""
    echo "   ℹ️  数据卷已按 --keep-data 保留，重新部署后数据原样可用。"
    echo "       如需彻底清除，请执行：docker volume rm $(echo "$VOLUMES" | tr '\n' ' ')"
fi

if [ "$PURGE_HOST" -ne 1 ]; then
    echo ""
    echo "   ℹ️  宿主机层面的调优（内核参数 / Swap / Docker 调优 / 防火墙放行）未回滚，"
    echo "       如需一并还原请执行：sudo bash uninstall-prod.sh --purge-host"
fi
