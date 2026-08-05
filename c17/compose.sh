#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="${script_dir}/../c04"
compose_engine="${C17_COMPOSE_ENGINE:-}"

die() {
  printf '[c17-compose] ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ -z "${compose_engine}" ]]; then
  if command -v podman >/dev/null 2>&1; then
    compose_engine='podman'
  elif command -v docker >/dev/null 2>&1; then
    compose_engine='docker'
  else
    die '未找到 podman 或 docker，请先安装 Compose 容器引擎。'
  fi
fi

case "${compose_engine}" in
podman | docker)
  ;;
*)
  die 'C17_COMPOSE_ENGINE 只能设置为 podman 或 docker。'
  ;;
esac

command -v "${compose_engine}" >/dev/null 2>&1 ||
  die "未找到 ${compose_engine} 命令。"

[[ -f "${project_dir}/compose.yml" ]] ||
  die "未找到基础 Compose 文件：${project_dir}/compose.yml"
[[ -f "${script_dir}/compose.snapshot.yml" ]] ||
  die "未找到快照 Compose 文件：${script_dir}/compose.snapshot.yml"

cd "${project_dir}"
exec "${compose_engine}" compose \
  -f compose.yml \
  -f ../c17/compose.snapshot.yml \
  "$@"
