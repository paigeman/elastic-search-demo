#!/usr/bin/env bash

set -Eeuo pipefail

# All settings can be overridden for a single invocation, for example:
# ES_VERSION=9.4.2 HOST_PORT=9201 ./es-podman.sh start
ES_VERSION="${ES_VERSION:-9.4.2}"
CONTAINER_NAME="${CONTAINER_NAME:-es01}"
NETWORK_NAME="${NETWORK_NAME:-elastic}"
VOLUME_NAME="${VOLUME_NAME:-esdata01}"
HOST_PORT="${HOST_PORT:-9200}"
MEMORY_LIMIT="${MEMORY_LIMIT:-1g}"
CA_OUTPUT="${CA_OUTPUT:-${PWD}/http_ca.crt}"
IMAGE="docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}"

log() {
  printf '[es-podman] %s\n' "$*"
}

die() {
  printf '[es-podman] ERROR: %s\n' "$*" >&2
  exit 1
}

require_podman() {
  command -v podman >/dev/null 2>&1 || die '未找到 podman，请先安装并启动 Podman。'
  podman info >/dev/null 2>&1 || die '无法连接 Podman；使用 Podman Machine 时请先执行 podman machine start。'
}

container_exists() {
  podman container exists "${CONTAINER_NAME}"
}

container_is_running() {
  [[ "$(podman inspect --format '{{.State.Running}}' "${CONTAINER_NAME}")" == 'true' ]]
}

require_container() {
  container_exists || die "容器 ${CONTAINER_NAME} 不存在，请先执行 $0 start。"
}

require_running_container() {
  require_container
  container_is_running || die "容器 ${CONTAINER_NAME} 未运行，请先执行 $0 start。"
}

ensure_resources() {
  if ! podman network exists "${NETWORK_NAME}"; then
    log "创建网络 ${NETWORK_NAME}"
    podman network create "${NETWORK_NAME}"
  fi

  if ! podman volume exists "${VOLUME_NAME}"; then
    log "创建数据卷 ${VOLUME_NAME}"
    podman volume create "${VOLUME_NAME}"
  fi
}

start_container() {
  ensure_resources

  if container_exists; then
    if container_is_running; then
      log "容器 ${CONTAINER_NAME} 已在运行。"
    else
      log "启动已有容器 ${CONTAINER_NAME}"
      podman start "${CONTAINER_NAME}"
    fi
  else
    log "使用镜像 ${IMAGE} 创建并启动容器 ${CONTAINER_NAME}"
    podman run --name "${CONTAINER_NAME}" --network "${NETWORK_NAME}" \
      -p "${HOST_PORT}:9200" \
      --memory "${MEMORY_LIMIT}" \
      -v "${VOLUME_NAME}:/usr/share/elasticsearch/data" \
      -e discovery.type=single-node \
      -d "${IMAGE}"
  fi

  log "访问地址：https://localhost:${HOST_PORT}"
  log "查看日志：$0 logs"
}

stop_container() {
  if ! container_exists; then
    log "容器 ${CONTAINER_NAME} 不存在，无需停止。"
    return
  fi

  if container_is_running; then
    log "停止容器 ${CONTAINER_NAME}"
    podman stop "${CONTAINER_NAME}"
  else
    log "容器 ${CONTAINER_NAME} 已停止。"
  fi
}

restart_container() {
  require_container
  log "重启容器 ${CONTAINER_NAME}"
  podman restart "${CONTAINER_NAME}"
}

remove_container() {
  local purge_resources='false'

  case "${1:-}" in
    '')
      ;;
    --purge)
      purge_resources='true'
      ;;
    *)
      die 'remove 仅支持 --purge 选项。'
      ;;
  esac

  if container_exists; then
    log "删除容器 ${CONTAINER_NAME}"
    podman rm --force "${CONTAINER_NAME}"
  else
    log "容器 ${CONTAINER_NAME} 不存在，无需删除。"
  fi

  if [[ "${purge_resources}" == 'false' ]]; then
    log "数据卷 ${VOLUME_NAME} 和网络 ${NETWORK_NAME} 已保留。"
    return
  fi

  if podman network exists "${NETWORK_NAME}"; then
    log "删除网络 ${NETWORK_NAME}"
    podman network rm "${NETWORK_NAME}"
  fi

  if podman volume exists "${VOLUME_NAME}"; then
    log "删除数据卷 ${VOLUME_NAME}（卷内数据将无法恢复）"
    podman volume rm "${VOLUME_NAME}"
  fi
}

show_logs() {
  require_container

  if [[ "${1:-}" == '--follow' || "${1:-}" == '-f' ]]; then
    podman logs --follow "${CONTAINER_NAME}"
  else
    podman logs "${CONTAINER_NAME}"
  fi
}

reset_password() {
  require_running_container

  case "${1:---auto}" in
    --auto|-a)
      log '为 elastic 用户自动生成新密码'
      podman exec -it "${CONTAINER_NAME}" \
        /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -a
      ;;
    --interactive|-i)
      log '交互式设置 elastic 用户的新密码'
      podman exec -it "${CONTAINER_NAME}" \
        /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -i
      ;;
    *)
      die 'reset-password 仅支持 --auto（默认）或 --interactive。'
      ;;
  esac
}

copy_ca() {
  require_container
  mkdir -p "$(dirname "${CA_OUTPUT}")"
  podman cp \
    "${CONTAINER_NAME}:/usr/share/elasticsearch/config/certs/http_ca.crt" \
    "${CA_OUTPUT}"
  log "CA 证书已复制到 ${CA_OUTPUT}"
}

test_connection() {
  local password="${ELASTIC_PASSWORD:-}"

  require_running_container
  command -v curl >/dev/null 2>&1 || die '未找到 curl，无法测试 Elasticsearch。'

  if [[ ! -f "${CA_OUTPUT}" ]]; then
    log "未找到 CA 证书 ${CA_OUTPUT}，正在从容器复制。"
    copy_ca
  fi

  if [[ -z "${password}" ]]; then
    [[ -t 0 ]] || die '未设置 ELASTIC_PASSWORD，且当前终端无法交互输入密码。'
    read -r -s -p '请输入 elastic 用户密码：' password
    printf '\n'
  fi

  [[ -n "${password}" ]] || die 'elastic 用户密码不能为空。'

  log "测试 https://localhost:${HOST_PORT}"
  curl --fail-with-body --show-error \
    --cacert "${CA_OUTPUT}" \
    --user "elastic:${password}" \
    "https://localhost:${HOST_PORT}"
  printf '\n'
  log 'Elasticsearch HTTPS、证书和用户认证测试通过。'
}

show_status() {
  if ! container_exists; then
    log "容器 ${CONTAINER_NAME} 不存在。"
    return
  fi

  podman inspect --format \
    '名称={{.Name}} 状态={{.State.Status}} 镜像={{.ImageName}}' \
    "${CONTAINER_NAME}"
  podman port "${CONTAINER_NAME}" 2>/dev/null || true
}

show_help() {
  cat <<EOF
用法：$(basename "$0") <命令> [选项]

命令：
  start                         创建资源并启动容器
  stop                          停止容器
  restart                       重启容器
  remove                        删除容器，保留网络和数据卷（默认）
  remove --purge                删除容器、网络和数据卷（数据不可恢复）
  logs [-f|--follow]            查看日志，可持续跟踪
  reset-password [--auto]       自动生成 elastic 用户的新密码
  reset-password -i|--interactive
                                交互式设置 elastic 用户的新密码
  copy-ca                       复制 HTTP CA 证书
  test                          测试 HTTPS、证书和 elastic 用户认证
  status                        查看容器状态和端口映射
  help                          显示帮助

可通过环境变量覆盖默认配置：
  ES_VERSION=${ES_VERSION}
  CONTAINER_NAME=${CONTAINER_NAME}
  NETWORK_NAME=${NETWORK_NAME}
  VOLUME_NAME=${VOLUME_NAME}
  HOST_PORT=${HOST_PORT}
  MEMORY_LIMIT=${MEMORY_LIMIT}
  CA_OUTPUT=${CA_OUTPUT}

示例：
  $(basename "$0") start
  $(basename "$0") logs -f
  $(basename "$0") reset-password
  $(basename "$0") copy-ca
  ELASTIC_PASSWORD='真实密码' $(basename "$0") test
  $(basename "$0") remove --purge
EOF
}

main() {
  local command="${1:-help}"
  shift || true

  case "${command}" in
    start)
      require_podman
      start_container "$@"
      ;;
    stop)
      require_podman
      stop_container "$@"
      ;;
    restart)
      require_podman
      restart_container "$@"
      ;;
    remove|rm)
      require_podman
      remove_container "$@"
      ;;
    logs)
      require_podman
      show_logs "$@"
      ;;
    reset-password|password)
      require_podman
      reset_password "$@"
      ;;
    copy-ca)
      require_podman
      copy_ca "$@"
      ;;
    test|verify)
      require_podman
      test_connection "$@"
      ;;
    status)
      require_podman
      show_status "$@"
      ;;
    help|-h|--help)
      show_help
      ;;
    *)
      show_help >&2
      die "未知命令：${command}"
      ;;
  esac
}

main "$@"
