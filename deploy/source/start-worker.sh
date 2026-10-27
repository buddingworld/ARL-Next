#!/bin/bash
# =============================================================================
# ARL-Next 源码模式 Worker 启动脚本
#
# 对应容器版的 backend/start_worker_prod.sh，差异仅在于：
#   1. 依赖探针指向 127.0.0.1（原生 MongoDB / RabbitMQ），而非容器网络别名
#   2. 不再用 sed 改写 config.yaml —— 源码模式下配置本身已指向本机
#   3. 解释器路径由脚本位置推导，部署目录可任意迁移
#
# 进程构成（与容器一致）：light / heavy / github 三个 Celery 队列
#   + Celery Beat 定时调度 + app.scheduler 监控调度引擎（前台常驻）
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKEND_DIR="$REPO_DIR/backend"
VENV="$BACKEND_DIR/.venv"

if [ ! -x "$VENV/bin/python" ]; then
    echo "❌ 错误：未找到虚拟环境 $VENV，请先按 deploy/source/README.md 创建。"
    exit 1
fi

echo "🚀 等待数据库和消息队列就绪..."
bash "$BACKEND_DIR/wait-for-it.sh" 127.0.0.1:27017 -t 60
bash "$BACKEND_DIR/wait-for-it.sh" 127.0.0.1:5672 -t 60

cd "$BACKEND_DIR"

echo "🚀 正在后台拉起 Celery 任务处理器..."
# 获取配置中的并发数量，异常捕获防止 MongoDB 未就绪时导致的 Bash 崩溃
read_concurrency() {
    local value
    value=$("$VENV/bin/python" -c "
try:
    from app.utils.performance_config import get_performance_config
    print(get_performance_config().get('$1', 1))
except Exception:
    print(1)
" 2>/dev/null || echo 1)
    # 非纯数字一律回退为 1，避免 [ ] 比较抛 integer expression expected
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then value=1; fi
    echo "$value"
}

HEAVY=$(read_concurrency celery_heavy_concurrency)
LIGHT=$(read_concurrency celery_light_concurrency)
GITHUB=$(read_concurrency github_concurrency)

# OOM 优先级分层（语义：数值越大越先被内核牺牲）
#   - github 队列是短周期 API 轮询，失败重试代价低 → 700，优先被牺牲
#   - 扫描队列（heavy / light）承载长耗时任务，被杀需从头重跑 → 500，更晚被牺牲
# 裸机 root 下权限比容器内更宽（可写低于基线甚至负值），此处刻意沿用容器基线值，
# 保持两种部署模式的 OOM 取舍行为一致。
OOM_ADJ_SCAN=500
OOM_ADJ_GITHUB=700
OOM_ADJ_WRAPPER=("$VENV/bin/python" "$BACKEND_DIR/run_worker_with_oom_adj.py")

if [ "$HEAVY" -gt 0 ] || [ "$LIGHT" -gt 0 ]; then
    echo "Starting HEAVY workers: $HEAVY, LIGHT workers: $LIGHT"

    if [ "$LIGHT" -gt 0 ]; then
        # 轻任务队列：更大的 tasks-per-child 与 300MB 内存熔断
        "${OOM_ADJ_WRAPPER[@]}" "$OOM_ADJ_SCAN" "$VENV/bin/celery" \
            -A app.celerytask.celery worker -Q arltask_light -n arltask_light \
            -c "$LIGHT" --max-tasks-per-child=50 --max-memory-per-child=300000 -l info &
    fi

    if [ "$HEAVY" -gt 0 ]; then
        # 重任务队列：严格限制 max-tasks-per-child=5 与 500MB 内存优雅熔断
        "${OOM_ADJ_WRAPPER[@]}" "$OOM_ADJ_SCAN" "$VENV/bin/celery" \
            -A app.celerytask.celery worker -Q arltask,arltask_heavy -n arltask_heavy \
            -c "$HEAVY" --max-tasks-per-child=5 --max-memory-per-child=500000 -l info &
    fi
else
    echo "Both Concurrency is 0, sleep"
    sleep 3600000000
fi

# GitHub 扫描队列（并发数由系统设置统一控制，设为 0 可显式停用）
if [ "$GITHUB" -gt 0 ]; then
    echo "Starting GitHub workers: $GITHUB"
    "${OOM_ADJ_WRAPPER[@]}" "$OOM_ADJ_GITHUB" "$VENV/bin/celery" \
        -A app.celerytask.celery worker -Q arlgithub -n arlgithub \
        -c "$GITHUB" --max-tasks-per-child=100 --max-memory-per-child=300000 -l info &
else
    echo "GitHub worker disabled (github_concurrency=0)"
fi

# Celery Beat 定时任务调度器
"$VENV/bin/celery" -A app.celerytask.celery beat -l info &

echo "🚀 正在前台拉起 ARL 监控任务调度引擎..."
exec "$VENV/bin/python" -m app.scheduler
