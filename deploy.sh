#!/bin/bash

# ==============================================================================
# 闲鱼监控系统 - 服务器一键部署脚本 (Docker)
#
# 适用环境：Linux 服务器，已安装 docker 与 docker compose (v2)。
#
# 功能：
#   1. 检查 docker / docker compose 环境
#   2. 从 .env.example 生成 .env（如不存在）
#   3. 准备 config.json 与数据目录（data/state/logs/images/jsonl/price_history）
#   4. 拉取镜像（ghcr.io 失败时自动回退到南京大学镜像）
#   5. 启动服务并检查健康状态
#
# 用法：
#   bash deploy.sh              # 拉取预构建镜像并部署（推荐）
#   bash deploy.sh --build      # 使用源码本地构建镜像（docker-compose.dev.yaml）
#   bash deploy.sh --update     # 更新到最新镜像并重启
#   bash deploy.sh --logs       # 查看实时日志
#   bash deploy.sh --down       # 停止并移除容器
# ==============================================================================

set -euo pipefail

# ---------- 颜色输出 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; }
step()  { echo -e "\n${BLUE}==>${NC} ${YELLOW}$*${NC}"; }

# ---------- 定位脚本目录 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="docker-compose.yaml"
DEV_COMPOSE_FILE="docker-compose.dev.yaml"
IMAGE_GHCR="ghcr.io/usagi-org/ai-goofish:latest"
IMAGE_MIRROR="ghcr.nju.edu.cn/usagi-org/ai-goofish:latest"
DATA_DIRS=(data state logs images jsonl price_history)

# ---------- 检测 docker compose 命令 ----------
detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE="docker-compose"
    else
        error "未检测到 docker compose。请先安装 Docker Compose v2。"
        exit 1
    fi
}

check_docker() {
    step "检查 Docker 环境"
    if ! command -v docker >/dev/null 2>&1; then
        error "未检测到 docker。请先安装 Docker：https://docs.docker.com/engine/install/"
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        error "无法连接 Docker 守护进程。请确认 Docker 已启动，且当前用户有权限（可能需要 sudo 或将用户加入 docker 组）。"
        exit 1
    fi
    detect_compose
    info "Docker 与 ${COMPOSE} 就绪"
}

# ---------- 准备配置文件 ----------
prepare_config() {
    step "准备配置文件"

    # .env
    if [ ! -f ".env" ]; then
        if [ -f ".env.example" ]; then
            cp .env.example .env
            warn "已从 .env.example 生成 .env —— 请务必编辑 .env 填入 OPENAI_API_KEY 等配置后再正式使用！"
            ENV_CREATED=1
        else
            error "缺少 .env.example，无法生成 .env"
            exit 1
        fi
    else
        info ".env 已存在，跳过"
    fi

    # config.json
    if [ ! -f "config.json" ]; then
        if [ -f "config.json.example" ]; then
            cp config.json.example config.json
            info "已从 config.json.example 生成 config.json"
        else
            echo "[]" > config.json
            info "已创建空 config.json"
        fi
    else
        info "config.json 已存在，跳过"
    fi

    # prompts 目录（compose 挂载需要存在）
    if [ ! -d "prompts" ]; then
        mkdir -p prompts
        warn "prompts 目录不存在，已创建空目录（请确认 config.json 引用的 prompt 文件存在）"
    fi
}

# ---------- 准备数据目录 ----------
prepare_dirs() {
    step "准备数据目录"
    for d in "${DATA_DIRS[@]}"; do
        mkdir -p "$d"
    done
    info "已确保目录存在：${DATA_DIRS[*]}"
}

# ---------- 拉取镜像（带镜像回退）----------
pull_image() {
    step "拉取镜像"
    if docker pull "$IMAGE_GHCR"; then
        info "已从 ghcr.io 拉取镜像"
    else
        warn "ghcr.io 拉取失败，尝试南京大学镜像源…"
        if docker pull "$IMAGE_MIRROR"; then
            docker tag "$IMAGE_MIRROR" "$IMAGE_GHCR"
            info "已从镜像源拉取并重新打标签为 ${IMAGE_GHCR}"
        else
            error "镜像拉取失败。请检查网络，或使用 'bash deploy.sh --build' 从源码本地构建。"
            exit 1
        fi
    fi
}

# ---------- 启动服务 ----------
start_service() {
    step "启动服务"
    $COMPOSE -f "$COMPOSE_FILE" up -d
}

start_service_build() {
    step "本地构建并启动服务（源码模式）"
    $COMPOSE -f "$DEV_COMPOSE_FILE" up -d --build
}

# ---------- 健康检查 ----------
get_port() {
    local port=8000
    if [ -f ".env" ]; then
        local p
        p="$(grep -E '^SERVER_PORT=' .env | tail -n1 | cut -d= -f2 | tr -d '[:space:]' || true)"
        [ -n "$p" ] && port="$p"
    fi
    echo "$port"
}

health_check() {
    step "健康检查"
    local port host tries=0 max=30
    port="$(get_port)"
    host="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -z "$host" ] && host="127.0.0.1"

    echo -n "等待服务就绪"
    while [ "$tries" -lt "$max" ]; do
        if curl -fsS "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
            echo ""
            info "服务已就绪 🎉"
            echo -e "\n${GREEN}访问地址：${NC} http://${host}:${port}"
            echo -e "${GREEN}默认账号：${NC} admin / admin123 （请尽快在 .env 中修改 WEB_USERNAME / WEB_PASSWORD）"
            echo -e "${GREEN}查看日志：${NC} bash deploy.sh --logs"
            return 0
        fi
        echo -n "."
        sleep 2
        tries=$((tries + 1))
    done
    echo ""
    warn "等待超时，服务可能仍在启动中。请手动查看日志：bash deploy.sh --logs"
}

print_env_reminder() {
    if [ "${ENV_CREATED:-0}" = "1" ]; then
        echo -e "\n${YELLOW}================= 重要提醒 =================${NC}"
        echo -e "${YELLOW}检测到 .env 是本次新生成的，AI 分析功能需要有效的 API Key 才能工作。${NC}"
        echo -e "${YELLOW}请编辑 .env 填入 OPENAI_API_KEY / OPENAI_BASE_URL / OPENAI_MODEL_NAME，${NC}"
        echo -e "${YELLOW}并修改默认 Web 密码，然后执行：bash deploy.sh --update${NC}"
        echo -e "${YELLOW}===========================================${NC}"
    fi
}

# ---------- 子命令 ----------
cmd_deploy() {
    check_docker
    prepare_config
    prepare_dirs
    pull_image
    start_service
    health_check
    print_env_reminder
}

cmd_build() {
    check_docker
    prepare_config
    prepare_dirs
    start_service_build
    health_check
    print_env_reminder
}

cmd_update() {
    check_docker
    prepare_dirs
    pull_image
    start_service
    health_check
}

cmd_logs() {
    detect_compose
    $COMPOSE -f "$COMPOSE_FILE" logs -f app
}

cmd_down() {
    detect_compose
    $COMPOSE -f "$COMPOSE_FILE" down
    info "服务已停止"
}

# ---------- 入口 ----------
main() {
    local action="${1:-deploy}"
    case "$action" in
        ""|deploy)  cmd_deploy ;;
        --build)    cmd_build ;;
        --update)   cmd_update ;;
        --logs)     cmd_logs ;;
        --down)     cmd_down ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
            ;;
        *)
            error "未知参数：$action"
            echo "用法：bash deploy.sh [--build|--update|--logs|--down|--help]"
            exit 1
            ;;
    esac
}

main "$@"
