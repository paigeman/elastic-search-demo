#!/usr/bin/env bash

set -euo pipefail

config_dir="/usr/share/elasticsearch/config"
cert_dir="${config_dir}/certs/c04"
ca_dir="${cert_dir}/ca"
http_dir="${cert_dir}/http"
transport_dir="${cert_dir}/transport"
elasticsearch_yml="${config_dir}/elasticsearch.yml"
certutil="/usr/share/elasticsearch/bin/elasticsearch-certutil"
begin_marker="# BEGIN C04 MANAGED SECURITY"
end_marker="# END C04 MANAGED SECURITY"

mkdir -p "${ca_dir}" "${http_dir}" "${transport_dir}"

if [[ ! -s "${ca_dir}/ca.crt" || ! -s "${ca_dir}/ca.key" ]]; then
  ca_zip="${cert_dir}/.ca.zip"
  rm -f "${ca_zip}"
  "${certutil}" ca \
    --silent \
    --pem \
    --days 1095 \
    --out "${ca_zip}"
  unzip -oq "${ca_zip}" -d "${cert_dir}"
  rm -f "${ca_zip}"
fi

generate_certificate() {
  local name="$1"
  local target_dir="$2"
  local certificate="${target_dir}/${name}.crt"
  local private_key="${target_dir}/${name}.key"
  local certificate_zip="${cert_dir}/.${name}.zip"

  if [[ -s "${certificate}" && -s "${private_key}" ]]; then
    return
  fi

  rm -f "${certificate_zip}"
  "${certutil}" cert \
    --silent \
    --pem \
    --days 825 \
    --ca-cert "${ca_dir}/ca.crt" \
    --ca-key "${ca_dir}/ca.key" \
    --name "${name}" \
    --dns "es01,localhost" \
    --ip "127.0.0.1" \
    --out "${certificate_zip}"
  unzip -oq "${certificate_zip}" -d "${cert_dir}"
  mv "${cert_dir}/${name}/${name}.crt" "${certificate}"
  mv "${cert_dir}/${name}/${name}.key" "${private_key}"
  rmdir "${cert_dir:?}/${name}"
  rm -f "${certificate_zip}"
}

generate_certificate "es01-http" "${http_dir}"
generate_certificate "es01-transport" "${transport_dir}"

temporary_yml="$(mktemp "${config_dir}/.elasticsearch.yml.XXXXXX")"

awk -v begin_marker="${begin_marker}" -v end_marker="${end_marker}" '
  $0 == "#----------------------- BEGIN SECURITY AUTO CONFIGURATION -----------------------" {
    skip = 1
    next
  }
  $0 == "#----------------------- END SECURITY AUTO CONFIGURATION -------------------------" {
    skip = 0
    next
  }
  $0 == begin_marker {
    skip = 1
    next
  }
  $0 == end_marker {
    skip = 0
    next
  }
  !skip {
    print
  }
' "${elasticsearch_yml}" >"${temporary_yml}"

cat >>"${temporary_yml}" <<EOF

${begin_marker}
xpack.security.enabled: true
xpack.security.enrollment.enabled: false

xpack.security.http.ssl:
  enabled: true
  key: certs/c04/http/es01-http.key
  certificate: certs/c04/http/es01-http.crt
  certificate_authorities: [certs/c04/ca/ca.crt]

xpack.security.transport.ssl:
  enabled: true
  verification_mode: certificate
  key: certs/c04/transport/es01-transport.key
  certificate: certs/c04/transport/es01-transport.crt
  certificate_authorities: [certs/c04/ca/ca.crt]
${end_marker}
EOF

mv "${temporary_yml}" "${elasticsearch_yml}"
chmod 750 "${cert_dir}" "${ca_dir}" "${http_dir}" "${transport_dir}"
chmod 600 "${ca_dir}/ca.key" "${http_dir}/es01-http.key" \
  "${transport_dir}/es01-transport.key"
chmod 644 "${ca_dir}/ca.crt" "${http_dir}/es01-http.crt" \
  "${transport_dir}/es01-transport.crt" "${elasticsearch_yml}"

service_account="elastic/kibana"
token_name="c04-kibana"
token_id="${service_account}/${token_name}"
token_file="/bootstrap/service_token"
ca_target="/bootstrap/http_ca.crt"
service_tokens="/usr/share/elasticsearch/bin/elasticsearch-service-tokens"

if [[ ! -s "${token_file}" ]]; then
  if "${service_tokens}" list | grep -Fxq "${token_id}"; then
    "${service_tokens}" delete "${service_account}" "${token_name}" >/dev/null
  fi

  create_output="$("${service_tokens}" create "${service_account}" "${token_name}")"
  service_token="${create_output##*= }"
  if [[ -z "${service_token}" || "${service_token}" == "${create_output}" ]]; then
    echo "Unable to parse the generated Kibana service token" >&2
    exit 1
  fi

  umask 077
  printf '%s' "${service_token}" >"${token_file}"
fi

cp "${ca_dir}/ca.crt" "${ca_target}"
chmod 600 "${token_file}"
chmod 644 "${ca_target}"

echo "Elasticsearch certificates and Kibana bootstrap files are ready"

exec /usr/local/bin/docker-entrypoint.sh "$@"
