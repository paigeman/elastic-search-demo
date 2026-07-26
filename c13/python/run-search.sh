#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
es_url="https://localhost:9200"
es_ca="${repo_root}/c04/http_ca.crt"
api_key=""

usage() {
  cat <<'EOF'
Usage: run-search.sh --api-key <encoded-api-key>

Options:
  -k, --api-key <value>  API key encoded value returned by Elasticsearch
  -h, --help             Show this help message
EOF
}

while (($# > 0)); do
  case "$1" in
    -k | --api-key)
      if (($# < 2)) || [[ -z "$2" ]]; then
        echo "Option $1 requires a non-empty value" >&2
        usage >&2
        exit 2
      fi
      api_key="$2"
      shift 2
      ;;
    --api-key=*)
      api_key="${1#*=}"
      if [[ -z "${api_key}" ]]; then
        echo "Option --api-key requires a non-empty value" >&2
        usage >&2
        exit 2
      fi
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${api_key}" ]]; then
  echo "Option --api-key is required" >&2
  usage >&2
  exit 2
fi

if [[ ! -r "${es_ca}" ]]; then
  echo "Elasticsearch CA certificate is not readable: ${es_ca}" >&2
  echo "Copy the lesson 04 CA to c04/http_ca.crt before running this script." >&2
  exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required but was not found in PATH" >&2
  exit 1
fi

export ES_URL="${es_url}"
export ES_CA="${es_ca}"
export ES_API_KEY="${api_key}"

exec uv run \
  --project "${script_dir}" \
  --locked \
  python "${script_dir}/search_products.py"
