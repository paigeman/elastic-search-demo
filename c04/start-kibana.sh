#!/usr/bin/env bash

set -euo pipefail

token_file="/run/c04-kibana-bootstrap/service_token"
ca_file="/run/c04-kibana-bootstrap/http_ca.crt"
keystore="/usr/share/kibana/bin/kibana-keystore"

if [[ ! -s "${token_file}" ]]; then
  echo "Kibana service token is missing: ${token_file}" >&2
  exit 1
fi

if [[ ! -s "${ca_file}" ]]; then
  echo "Elasticsearch HTTP CA is missing: ${ca_file}" >&2
  exit 1
fi

if [[ ! -f /usr/share/kibana/config/kibana.keystore ]]; then
  "${keystore}" create
fi

"${keystore}" add elasticsearch.serviceAccountToken \
  --stdin \
  --force <"${token_file}"

exec /usr/local/bin/kibana-docker
