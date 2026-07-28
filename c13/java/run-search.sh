#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/../.." && pwd)"
es_url="https://localhost:9200"
es_ca="${repo_root}/c04/http_ca.crt"
api_key=""
keyword=""
category=""
page_size="20"

usage() {
  cat <<'EOF'
Usage: run-search.sh --api-key <encoded-api-key> --keyword <text> [options]

Options:
  -k, --api-key <value>  API key encoded value returned by Elasticsearch
      --keyword <text>   Required product search keyword
      --category <value> Optional exact category filter
      --size <integer>   Requested result count; Java must clamp it to 1-100 (default: 20)
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
    --keyword)
      if (($# < 2)) || [[ -z "$2" ]]; then
        echo "Option $1 requires a non-empty value" >&2
        usage >&2
        exit 2
      fi
      keyword="$2"
      shift 2
      ;;
    --keyword=*)
      keyword="${1#*=}"
      if [[ -z "${keyword}" ]]; then
        echo "Option --keyword requires a non-empty value" >&2
        usage >&2
        exit 2
      fi
      shift
      ;;
    --category)
      if (($# < 2)) || [[ -z "$2" ]]; then
        echo "Option $1 requires a non-empty value" >&2
        usage >&2
        exit 2
      fi
      category="$2"
      shift 2
      ;;
    --category=*)
      category="${1#*=}"
      if [[ -z "${category}" ]]; then
        echo "Option --category requires a non-empty value" >&2
        usage >&2
        exit 2
      fi
      shift
      ;;
    --size)
      if (($# < 2)) || [[ -z "$2" ]]; then
        echo "Option $1 requires a non-empty value" >&2
        usage >&2
        exit 2
      fi
      page_size="$2"
      shift 2
      ;;
    --size=*)
      page_size="${1#*=}"
      if [[ -z "${page_size}" ]]; then
        echo "Option --size requires a non-empty value" >&2
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

if [[ -z "${keyword}" ]]; then
  echo "Option --keyword is required" >&2
  usage >&2
  exit 2
fi

if [[ ! "${page_size}" =~ ^-?[0-9]+$ ]]; then
  echo "Option --size must be an integer" >&2
  usage >&2
  exit 2
fi

if [[ ! -r "${es_ca}" ]]; then
  echo "Elasticsearch CA certificate is not readable: ${es_ca}" >&2
  echo "Copy the lesson 04 CA to c04/http_ca.crt before running this script." >&2
  exit 1
fi

if ! command -v java >/dev/null 2>&1; then
  echo "Java is required but was not found in PATH." >&2
  echo "Install or activate Java 21 before running this script." >&2
  exit 1
fi

if [[ ! -x "${script_dir}/mvnw" ]]; then
  echo "The Maven Wrapper is missing or is not executable: ${script_dir}/mvnw" >&2
  exit 1
fi

export ES_URL="${es_url}"
export ES_CA="${es_ca}"
export ES_API_KEY="${api_key}"
export ES_SEARCH_KEYWORD="${keyword}"
export ES_SEARCH_CATEGORY="${category}"
export ES_SEARCH_SIZE="${page_size}"

exec "${script_dir}/mvnw" \
  --file "${script_dir}/pom.xml" \
  --quiet \
  compile \
  exec:java
