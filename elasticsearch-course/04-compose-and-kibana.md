# 04｜使用 Compose 部署 Elasticsearch 与 Kibana

## 本节目标

- 用 Docker Compose 或 Podman Compose 启动可持久化的学习环境。
- 理解 Compose 的服务名、容器名、项目名及资源生命周期，并区分独立部署与复用已有服务。
- 在部署阶段自动生成包含稳定服务名的 TLS 证书。
- 复制 Compose 集群的 HTTP CA，并从宿主机验证 Elasticsearch API。
- 自动为 Kibana 配置 CA 和服务账户令牌，并区分机器凭据与用户密码。
- 理解启动脚本的依赖顺序、幂等性和安全边界。

## 1. 准备独立的 Compose 实验

本节不要求预先存在特定目录。先选择一个独立的实验目录，用来保存 `.env` 和 `compose.yml`。当前仓库按课程编号使用自行创建的 `c04/`：

```bash
mkdir -p c04
```

`c04/` 只是当前仓库组织实验文件的方式，不是课程预备条件。如果使用其他目录，将后文的 `c04/` 替换为实际目录即可。

### 1.1 与第 03 课的关系

第 03 课通过 `docker run` 或 `podman run` 直接管理 Elasticsearch；第 04 课则创建新的 Compose 项目。两套实验默认不是同一个 Elasticsearch 实例：

| 项目 | 第 03 课 | 第 04 课 |
| --- | --- | --- |
| 管理方式 | 直接运行容器 | Compose 项目 |
| Elasticsearch 服务 | 固定容器名 `es01` | Compose 服务名 `es01`，容器名由 Compose 生成 |
| 数据卷 | 引擎级命名卷 `esdata01` | 项目级命名卷，通常类似 `c04_esdata01` |
| `elastic` 密码 | 属于第 03 课数据卷中的安全索引 | 属于第 04 课数据卷中的安全索引 |

密码跟随 Elasticsearch 集群的安全数据，不跟随课程编号或镜像版本。因此，第 03 课生成的密码不能用于第 04 课的新集群；第 04 课需要重新取得自己的密码。Compose 示例没有固定 `container_name`，以免与第 03 课的 `es01` 容器重名。

两课默认都会占用宿主机的 `9200` 端口。如果第 03 课的 Elasticsearch 仍在运行，应先按照第 03 课采用的容器引擎停止该实例，再启动本节的独立 Compose 环境。停止容器不会删除命名卷；不要为了释放端口而清除第 03 课的数据卷。

### 1.2 本地环境变量

`c04/.env` 内容如下：

```dotenv
STACK_VERSION=9.4.2
ES_PORT=9200
KIBANA_PORT=5601
MEM_LIMIT=1073741824
```

`1073741824` 字节等于 1 GiB。这个限制只通过 `mem_limit` 应用于 Elasticsearch 服务 `es01`；当前示例没有限制 Kibana 服务 `kib01`，所以运行两者所需的主机或 Podman Machine 总内存会高于 1 GiB。可用 `docker stats` 或 `podman stats` 观察实际使用情况。

`.env` 是本机配置文件，已经被仓库根目录的 `.gitignore` 忽略，不应提交。当前文件虽然不含密码，也可能因端口、版本和资源配置而因人而异。密码和令牌同样不要写入 Git、`.env`、Compose 文件、命令历史或日志；生产环境应通过 Secret 管理系统或 Kibana keystore 注入。

可在仓库根目录验证忽略规则：

```bash
git check-ignore -v c04/.env
```

忽略规则只匹配名为 `.env` 的文件，不会阻止提交 `.env.example` 等模板。

### 1.3 Compose 文件

`c04/compose.yml` 内容如下：

```yaml
services:
  es01:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    hostname: es01
    entrypoint: ["/bin/tini", "--", "/usr/local/bin/start-elasticsearch.sh"]
    environment:
      - discovery.type=single-node
    ports:
      - "127.0.0.1:${ES_PORT}:9200"
    volumes:
      - ./start-elasticsearch.sh:/usr/local/bin/start-elasticsearch.sh:ro
      - esconfig:/usr/share/elasticsearch/config
      - esdata01:/usr/share/elasticsearch/data
      - kibanabootstrap:/bootstrap
    mem_limit: ${MEM_LIMIT}
    healthcheck:
      test: ["CMD-SHELL", "curl -s --cacert config/certs/c04/ca/ca.crt https://localhost:9200 | grep -q 'missing authentication credentials'"]
      interval: 10s
      timeout: 10s
      retries: 60

  kib01:
    image: docker.elastic.co/kibana/kibana:${STACK_VERSION}
    environment:
      ELASTICSEARCH_HOSTS: '["https://es01:9200"]'
      ELASTICSEARCH_SSL_CERTIFICATEAUTHORITIES: /run/c04-kibana-bootstrap/http_ca.crt
      ELASTICSEARCH_SSL_VERIFICATIONMODE: full
    ports:
      - "127.0.0.1:${KIBANA_PORT}:5601"
    volumes:
      - ./start-kibana.sh:/usr/local/bin/start-kibana.sh:ro
      - kibanabootstrap:/run/c04-kibana-bootstrap:ro
      - kibanadata:/usr/share/kibana/data
    command: ["/bin/bash", "/usr/local/bin/start-kibana.sh"]
    depends_on:
      es01:
        condition: service_healthy

volumes:
  esconfig:
  esdata01:
  kibanabootstrap:
  kibanadata:
```

Elasticsearch 与 Kibana 必须使用完全相同的版本号。命名卷 `esconfig` 保存 Elasticsearch 的 `elasticsearch.yml`、keystore、文件型服务令牌和 TLS 证书，`esdata01` 保存索引与集群数据，`kibanabootstrap` 保存提供给 Kibana 的 CA 和服务账户令牌，`kibanadata` 保存 Kibana 数据。它们都由 Compose 按项目隔离，删除或重建容器不会自动删除这些卷。

`es01` 的启动脚本先生成课程专用 CA、HTTP 证书和传输证书，并准备 Kibana 服务账户令牌，再调用镜像原有入口启动 Elasticsearch。HTTP 证书的 SAN 固定包含 DNS 名称 `es01`、`localhost` 和 IP 地址 `127.0.0.1`；Kibana 通过 `https://es01:9200` 连接并使用 `full` 模式同时验证 CA 与主机名，因此不依赖可能变化的容器 IP，也不需要降低 TLS 校验等级。

启动脚本只在 `esconfig` 中不存在课程证书时生成新证书，只在 `kibanabootstrap` 中不存在令牌文件时创建服务令牌，后续启动会直接复用。对于已经迁移了完整 `esconfig` 的旧版集群，第一次采用本节新版 Compose 时会自动生成包含 `es01` 的新证书并切换 TLS 配置；`esdata01` 中的索引、安全用户、密码和 API Key 不会因此改变。宿主机客户端随后需要重新复制并信任新的 HTTP CA。

`kibanabootstrap` 中的服务账户令牌属于敏感信息，应限制卷的访问权限。命名卷只是本地实验的持久化手段，不是生产环境的 Secret 管理系统。

Compose 还需要两个同目录脚本。`start-elasticsearch.sh` 在 Elasticsearch 启动前生成或复用证书、写入 TLS 配置、创建或复用 Kibana 服务令牌并复制公开 CA，最后调用镜像原有入口：

```bash
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
```

CA 私钥和节点私钥只保存在 `esconfig` 命名卷中，不能复制到宿主机或提交到 Git。部署后供客户端信任的是公开文件 `ca.crt`。服务令牌由同一脚本离线写入 Elasticsearch 的 `service_tokens` 文件和受限共享卷，不需要先启动 Elasticsearch，也不会输出到日志。脚本最终把参数原样交还镜像入口，因此 Elasticsearch 仍按镜像默认方式运行。

`start-kibana.sh` 在每次 Kibana 容器启动时把服务令牌写入 Kibana keystore，再调用镜像原有的启动程序：

```bash
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
```

### 1.4 服务名、容器名与项目名

`es01` 和 `kib01` 首先是 Compose 文件中的**服务名**。Compose 默认根据项目名、服务名和副本序号生成实际容器名；具体分隔符可能随 Compose 提供程序不同而变化，例如 `c04-es01-1`。日常操作应优先使用稳定的服务名：

```bash
podman compose logs es01
podman compose exec es01 sh
```

Compose 也支持通过 `container_name` 指定实际容器名：

```yaml
services:
  es01:
    container_name: c04-es01
```

当前主示例没有设置 `container_name`，不是因为 Compose 不支持，而是为了避免与第 03 课的 `es01` 重名，并保留 Compose 的项目隔离和扩展能力。如果确实需要固定名称，应使用 `c04-es01`、`c04-kib01` 等不会冲突的名称；指定 `container_name` 后，该服务不能扩展为多个容器副本。

Compose 使用**项目名**为容器、网络和普通命名卷建立隔离。默认项目名来自 Compose 文件所在目录，所以当前目录 `c04/` 中的逻辑卷 `esdata01` 通常会成为实际卷 `c04_esdata01`。这不是卷内容的一部分，而是 Compose 的资源命名规则。

可以在命令行指定项目名：

```bash
podman compose -p elastic-course up -d
```

也可以在 Compose 文件顶层指定：

```yaml
name: elastic-course
```

如果只想固定某个卷的实际名称，不添加项目前缀，可使用 `name`：

```yaml
volumes:
  esdata01:
    name: esdata01
```

如果该卷已经存在，而且生命周期明确由 Compose 项目之外管理，应声明为外部卷：

```yaml
volumes:
  esdata01:
    external: true
    name: esdata01
```

外部卷必须在启动前存在，Compose 不会创建它，也不会在 `compose down -v` 时删除它。

### 1.5 Compose 能否复用已有容器

“复用已有容器”需要先区分容器由谁创建和管理：

| 目标 | 是否支持 | 正确方式 |
| --- | --- | --- |
| 继续使用同一 Compose 项目创建的容器 | 支持 | 使用 `compose stop`、`compose start` 或再次执行 `compose up` |
| 让 Compose 接管由 `docker run` 或 `podman run` 创建的任意容器 | 不支持 | Compose 不会仅凭同名容器完成接管 |
| 让 Compose 服务访问已有容器 | 支持 | 让双方加入同一个外部网络，但已有容器仍由原方式管理 |
| 让新 Compose 容器挂载已有数据卷 | 支持 | 声明 `external` 卷；这复用的是数据，不是容器 |

Compose 通过项目和服务标签识别自己创建的容器。同一项目的容器停止后可以原样启动：

```bash
podman compose stop
podman compose start
```

当前主示例只有 `es01` 和 `kib01` 两个长期服务，没有需要单独处理的一次性容器。以上两条命令都不需要追加服务名：停止时 Compose 会先停止 Kibana，启动时会先启动 Elasticsearch、等待健康检查通过，再启动 Kibana。证书和服务令牌的幂等准备由 `es01` 自己的入口脚本完成。

再次执行 `podman compose up -d` 时，配置未变化的容器通常会继续使用；如果镜像或服务配置发生变化，Compose 可以删除旧容器并创建新容器。因此，索引数据、TLS 证书、keystore 和 Kibana 注册状态都必须放在命名卷中，不能依赖容器可写层。

把 `container_name` 设置成一个由第 03 课创建且仍然存在的 `es01`，只会引起名称冲突，不会让 Compose 自动接管它。

#### 延续第 03 课已有的 Elasticsearch

如果希望第 04 课沿用第 03 课的集群、密码和数据，可以保留第 03 课的 `es01`，让 Compose 只创建 Kibana，并接入第 03 课已经创建的 `elastic` 网络：

```yaml
services:
  kib01:
    image: docker.elastic.co/kibana/kibana:${STACK_VERSION}
    container_name: c04-kib01
    ports:
      - "127.0.0.1:${KIBANA_PORT}:5601"
    volumes:
      - kibanaconfig:/usr/share/kibana/config
      - kibanadata:/usr/share/kibana/data
    networks:
      - elastic

volumes:
  kibanaconfig:
  kibanadata:

networks:
  elastic:
    external: true
    name: elastic
```

这条路线不再在 Compose 中声明 `es01`，也不使用 `depends_on`，因为 Elasticsearch 不属于当前 Compose 项目。启动前必须确保：

- 第 03 课的 `es01` 正在运行，并已加入名为 `elastic` 的网络。
- Elasticsearch 和 Kibana 版本完全相同。
- 两个容器由同一个 Docker 上下文或同一个 rootless Podman 用户管理；不要混用 `podman` 与 `sudo podman`。
- Kibana 使用第 03 课集群生成的注册令牌，登录时也使用第 03 课的 `elastic` 密码。

这属于“Compose 访问已有服务”，不是“Compose 接管已有容器”。执行 `compose down` 只会移除 Kibana 及当前项目资源，不会停止或删除第 03 课的 Elasticsearch 和外部网络。

#### 只复用第 03 课的数据卷

Compose 语法允许新容器挂载第 03 课已经创建的 `esdata01`：

```yaml
services:
  es01:
    volumes:
      - esdata01:/usr/share/elasticsearch/data

volumes:
  esdata01:
    external: true
    name: esdata01
```

但这只复用了 Elasticsearch 的**数据目录**，并没有复用第 03 课的容器或完整节点配置。迁移前必须理解以下限制：

- 同一个数据卷任何时候只能由一个 Elasticsearch 节点使用。必须先完全停止第 03 课的 `es01`，并确保它不会在 Compose 节点运行期间被再次启动；两个节点同时写入同一数据目录可能造成节点锁冲突或数据损坏。
- 新旧容器必须使用兼容的 Elasticsearch 版本。不能把数据卷随意挂载到更旧版本，也不能把普通容器重建当作未经评估的升级流程。
- 索引、集群元数据和安全索引位于 `esdata01` 中，因此原集群的用户和密码会随数据保留。
- 自动生成的 `http_ca.crt`、`http.p12`、`transport.p12`、`elasticsearch.yml` 和 Elasticsearch keystore 位于 `/usr/share/elasticsearch/config`，不在 `esdata01` 中。
- Elasticsearch 检测到数据目录已经存在且非空时，会跳过首次安全自动配置。第 03 课只持久化了数据卷，没有持久化配置目录；因此，新 Compose 容器仅挂载 `esdata01` 后不会自动重建与原节点等价的 TLS 配置，当前 HTTPS 健康检查、注册令牌生成和 Kibana 注册都可能失败。

要把原节点真正迁移到 Compose，至少需要在停止原节点后安全迁移并持久化其完整配置目录，或重新显式配置 TLS、keystore 和 enrollment，再让 Compose 同时挂载数据卷与配置卷。例如，准备好外部配置卷后，结构应类似：

```yaml
services:
  es01:
    volumes:
      - esdata01:/usr/share/elasticsearch/data
      - esconfig01:/usr/share/elasticsearch/config

volumes:
  esdata01:
    external: true
    name: esdata01
  esconfig01:
    external: true
    name: esconfig01
```

这里的 `esconfig01` 必须事先包含原节点完整、权限正确且受保护的配置内容，不能创建一个空卷直接覆盖镜像内的配置目录。配置目录含有私钥和 keystore，不应提交到 Git，也不能通过不受保护的普通文件复制流程处理。

因此，本课程现状下有两条安全且清晰的路线：

- **延续第 03 课**：保留原 `es01` 容器，让 Compose 只管理 Kibana 并通过外部网络访问它；数据、密码、证书和配置都继续由原容器使用。
- **学习完整 Compose 部署**：使用当前主示例创建新的项目级数据卷和全新的安全配置。

“只复用 `esdata01`”应视为节点迁移练习，不是简单的 Compose 复用开关。正式迁移前还应创建 Elasticsearch 快照；复制数据目录本身不是受支持的备份方式。

本节后续采用主示例的**独立部署路线**：第 04 课由 Compose 同时创建新的 Elasticsearch 和 Kibana。选择延续路线时，需要针对第 03 课的 `es01` 另行提供 CA、Kibana 机器凭据和用户密码，不能直接套用主示例的项目级命名卷。

## 2. 启动并观察服务

先进入实验目录，让 Compose 自动读取其中的 `.env` 和 `compose.yml`：

```bash
cd c04
```

Docker 用户执行：

```bash
docker compose config
docker compose up -d
docker compose ps
docker compose logs -f es01
```

Podman 的 `podman compose` 会调用系统中安装的外部 Compose 提供程序，例如 `podman-compose` 或 `docker-compose`。macOS 和 Windows 用户先启动 Podman Machine：

```bash
podman machine start
```

然后检查提供程序并启动：

```bash
podman info
podman compose version
podman compose config
podman compose up -d
podman compose ps
podman compose logs -f es01
```

日志跟随界面中按 `Ctrl-C` 只会退出日志查看，不会停止容器。

本例使用引擎管理的命名卷，适合 rootless Podman，不需要给卷添加 `:Z`。不要交替使用 `podman` 和 `sudo podman` 管理这套环境，否则会进入彼此隔离的容器、网络和卷存储。资源限制能否在 rootless 模式下生效还取决于主机的 cgroup 配置。

## 3. 验证自动初始化并准备访问凭据

`compose up -d` 会先由 `es01` 的入口脚本完成证书与 Kibana 机器身份配置，再启动 Elasticsearch；Elasticsearch 健康后才启动 `kib01`。整个过程不需要浏览器注册令牌、验证码或手工修改容器内配置。

### 3.1 验证自动初始化

查看服务状态和 Elasticsearch 启动日志：

```bash
podman compose ps -a
podman compose logs es01
```

预期只有 `es01` 和 `kib01` 两个容器，两者都为运行状态，且 `es01` 为 `healthy`。Elasticsearch 日志开头应包含：

```text
Elasticsearch certificates and Kibana bootstrap files are ready
```

首次启动时，`start-elasticsearch.sh` 生成包含 `es01` SAN 的持久化证书，创建 `elastic/kibana/c04-kibana` 文件型服务令牌，并把令牌原文与公开 HTTP CA 写入受限的 `kibanabootstrap` 卷。再次执行 `compose start`、`compose restart` 或 `compose up` 时，脚本都会复用已有文件。

### 3.2 重置用户密码并验证 Elasticsearch API

启动脚本创建的是 Kibana 机器凭据，不是浏览器用户密码。重置本章独立集群的 `elastic` 用户密码：

```bash
# Docker
docker compose exec es01 \
  /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic

# Podman
podman compose exec es01 \
  /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic
```

启动脚本生成的 HTTP CA 位于 Elasticsearch 配置卷中，并已把公开 CA 提供给 Kibana，但宿主机上的 `curl` 无法直接读取命名卷；要通过 `https://localhost:9200` 调用 API，需要先像第 03 课一样，把本集群的 CA 证书复制到当前目录。只复制 `ca.crt`，不要复制同目录中的 `ca.key`。

Docker 用户执行：

```bash
docker compose cp \
  es01:/usr/share/elasticsearch/config/certs/c04/ca/ca.crt \
  ./http_ca.crt
```

Podman 用户执行：

```bash
podman compose cp \
  es01:/usr/share/elasticsearch/config/certs/c04/ca/ca.crt \
  ./http_ca.crt
```

然后设置连接变量，并让 `curl` 提示输入刚刚重置得到的密码：

```bash
export ES_URL=https://localhost:9200
export ES_CA="$PWD/http_ca.crt"

curl --cacert "$ES_CA" -u elastic "$ES_URL"
```

第 03 课和第 04 课是两个独立集群，各自生成自己的 CA；第 03 课复制出的证书不能用于验证第 04 课的 HTTPS 连接。不要用 `curl -k` 绕过证书校验。本例生成的 `http_ca.crt` 已被仓库根目录的 `.gitignore` 忽略，不应提交到 Git。

### 3.3 登录 Kibana

打开 `http://localhost:5601`。自动初始化完成后应直接进入登录页，不会出现粘贴注册令牌或输入验证码的页面。使用用户名 `elastic` 和第 3.2 节重置得到的密码登录。

Kibana 后台使用启动脚本创建的 `elastic/kibana` 服务账户令牌连接 Elasticsearch；浏览器用户仍然使用自己的用户凭据。两条认证通道的区别见第 4 节。

### 3.4 等待 Kibana 完全就绪

Elasticsearch 健康并启动 Kibana 后，Kibana 仍需要建立连接、迁移保存对象并初始化插件。浏览器如果在这个短暂窗口内访问 Kibana，可能看到：

```json
{"statusCode":503,"error":"Service Unavailable","message":"License information could not be obtained from Elasticsearch. Please check the logs for further details."}
```

这个响应通常表示许可证模块暂时还没有从 Elasticsearch 的 `/_license` 接口取得信息，不等于许可证无效，也不表示自动初始化失败。

按所用引擎观察 Kibana 日志：

```bash
# Docker
docker compose logs -f kib01

# Podman
podman compose logs -f kib01
```

看到以下日志后，说明 Kibana 已经取得许可证信息：

```text
[status.plugins.licensing] licensing plugin is now available: License fetched
```

也可以从宿主机检查状态接口：

```bash
curl --silent --output /dev/null \
  --write-out '%{http_code}\n' \
  http://127.0.0.1:5601/api/status
```

`/api/status` 是 **Kibana API**，监听在 Kibana 的 `5601` 端口。这里是在宿主机终端执行 `curl`，不是在 Kibana Dev Tools 中执行普通的 `GET /api/status`。返回 `200` 后刷新 `http://localhost:5601`；根路径返回 `302` 通常只是跳转到登录页，也是正常现象。

登录 Kibana 后，如果要在 Dev Tools Console 中调用同一个 Kibana API，必须添加 `kbn:` 前缀：

```http
GET kbn:/api/status
```

Dev Tools 中不带 `kbn:` 的请求默认发给 Elasticsearch。因此：

```http
# 错误：请求会发往 Elasticsearch 的 9200 端口
GET /api/status

# 正确：请求发往 Kibana 自己的 API
GET kbn:/api/status
```

在 Kibana 尚未完全就绪、登录页还不可用时，无法依赖 Dev Tools 检查状态，应继续使用宿主机上的 `curl`。

如果 503 持续存在，应检查 `compose ps -a` 以及 Elasticsearch、Kibana 日志中的连接、TLS 或认证错误；不要把重置密码或删除数据卷作为第一步。若 Elasticsearch 启动脚本失败，先检查 `esconfig` 中是否存在 HTTP CA，以及 `kibanabootstrap` 是否可写；若 Kibana 报认证错误，检查 keystore 中是否存在 `elasticsearch.serviceAccountToken` 这个键名，不要输出令牌值。

日志中若同时出现 `FleetEncryptedSavedObjectEncryptionKeyRequired`，这是缺少 `xpack.encryptedSavedObjects.encryptionKey` 导致的独立 Fleet 配置问题，不是这个瞬时许可证 503 的原因。它主要影响 Fleet、Elastic Agent、告警和其他需要加密 Saved Objects 的功能；基础登录、Dev Tools 和许可证获取可以已经正常。需要使用 Fleet 时，应生成至少 32 个字符的稳定密钥并通过 Kibana keystore 或 Secret 管理系统配置，不要把密钥提交到 Git。

## 4. 区分 Kibana 凭据与用户登录凭据

本节自动化流程使用 Kibana 服务账户令牌和用户密码；浏览器注册令牌只用于另一种首次配对方案，这三者属于不同主体：

| 凭据 | 代表谁 | 主要用途 | 生命周期 | 能否登录 Kibana |
| --- | --- | --- | --- | --- |
| Kibana 注册令牌 | 一次初始化操作 | 手动注册方案中完成首次安全配对；本节自动化流程不使用 | 短期有效，过期后重新生成 | 不能 |
| Kibana 服务账户令牌 | Kibana 机器身份 `elastic/kibana` | 让 Kibana 后台维护系统索引、迁移和任务等内部数据 | 不会自动过期，需要主动撤销 | 不能 |
| `elastic` 用户密码 | 人类用户 `elastic` | 登录 Kibana，或直接调用 Elasticsearch HTTP API | 重置前持续有效 | 能 |

### 4.1 Kibana 服务端自己的凭据

Kibana 本身是一个长期运行的服务。即使还没有用户打开浏览器，它也要启动、迁移 `.kibana*` 系统索引并运行后台任务，所以必须拥有独立的机器身份。

本节的自动机器身份配置可以概括为：

```text
start-elasticsearch.sh 生成或复用证书、创建或复用服务令牌并复制 CA
  └─ es01 使用证书启动并通过健康检查
       └─ start-kibana.sh 把令牌写入 Kibana keystore
            └─ Kibana 以 elastic/kibana 身份访问 Elasticsearch
```

Kibana 服务端使用 `elastic/kibana` 服务账户令牌访问 Elasticsearch。这个令牌由 Elasticsearch 启动脚本创建，经受限共享卷传递，再由 Kibana 启动脚本写入 keystore；它不提供给浏览器用户，也不能用来登录 Kibana。它虽然能作为 Bearer Token 调用 Elasticsearch，但只能获得服务账户固定的权限，不等同于 `elastic` 超级用户。

这条通道主要服务于 Kibana 自身：

```text
Kibana 后台任务 ── elastic/kibana 服务账户令牌 ──→ Elasticsearch
```

也可以使用内置用户 `kibana_system` 及其专用密码替代服务账户令牌，但它同样是 Kibana 服务端凭据，不是人类用户的登录账号。本节的自动化流程采用服务账户令牌。

### 4.2 用户登录 Kibana 的凭据

用户登录 Kibana 是另一条认证通道。本节默认启用 Basic 认证，用户在 Kibana 登录页输入 `elastic` 和对应密码。浏览器把凭据提交给 Kibana，由 Kibana 通过 Elasticsearch HTTP 安全接口验证；浏览器不直接访问 Elasticsearch 的 `9200` 端口。

登录成功后，浏览器持有 Kibana 会话。用户在 Discover、Dev Tools 或仪表盘中发起操作时，请求路径是：

```text
浏览器
  └─ 用户登录和 Kibana 会话 ─→ Kibana
                                 └─ 用户认证上下文 ─→ Elasticsearch HTTP API
```

在登录阶段，Kibana 代表用户将 Basic 用户名和密码提交给 Elasticsearch HTTP API 完成认证。登录成功后，Kibana 使用由该用户凭据建立的认证状态代理后续请求，浏览器通过 Kibana 会话继续操作，不需要直接连接 Elasticsearch，也不需要在每次页面请求中重新填写密码。

Elasticsearch 最终以该用户身份完成认证和授权，因此使用 `elastic` 登录时拥有 `elastic` 的权限；换成低权限用户后，同一个 Kibana 界面只能执行该用户获准的操作。

更严格地说，不应把所有认证方式描述成“Kibana 在每次请求中重复发送用户原始密码”：Kibana 还支持 Token、SAML、OpenID Connect、PKI 和 Kerberos 等提供程序，这些方式可能使用访问令牌或其他认证上下文。共同点是用户请求按登录用户身份授权，而不是按 Kibana 服务账户身份授权。

### 4.3 两类凭据不能互相替代

- Kibana 服务账户令牌解决“服务启动后如何执行内部工作”，不能让用户登录。
- 用户密码解决“这个人是谁、允许访问哪些数据”，不应配置成 Kibana 的后台服务凭据。
- Kibana 代理用户请求时不会把 `elastic/kibana` 的服务权限借给用户，也不会用服务账户令牌绕过用户角色。
- 直接使用 `curl -u elastic:密码 https://localhost:9200` 与通过 Kibana 操作的最终授权身份可以相同，但网络路径不同：前者直接访问 Elasticsearch，后者经过 Kibana 代理。

## 5. 自动初始化如何工作

本例不生成短期注册令牌，而是直接为 Kibana 创建长期机器身份。启动顺序如下：

```text
start-elasticsearch.sh 生成或复用证书和服务令牌，并复制 HTTP CA
  └─ es01 使用证书启动并通过 HTTPS 健康检查
       └─ kib01 把令牌写入 keystore，并以 full 模式连接 https://es01:9200
```

这个设计解决了以下问题：

- `ELASTICSEARCH_HOSTS` 固定为 Compose 服务名，不记录动态容器 IP。
- HTTP 证书明确包含 `es01` SAN，CA 通过只读共享卷提供，Kibana 保持完整 TLS 校验。
- 服务令牌不出现在 `.env`、Compose 环境变量、进程参数或日志中。
- Kibana 从 keystore 读取服务令牌，不把机器凭据写进普通配置文件。
- Elasticsearch 启动脚本只在课程证书缺失时生成证书，重复启动不会反复换 CA。
- 同一脚本只在共享令牌文件缺失时创建令牌，重复启动不会不断增加凭据。
- `service_healthy` 确保 Kibana 只在 Elasticsearch 初始化完成并健康后启动。
- Compose 只有两个长期服务，因此日常暂停和恢复可以直接使用不带服务名的 `compose stop` 与 `compose start`。

`kibanabootstrap` 仍然保存了令牌原文，因此只是适合本地课程的受限共享卷。生产环境应换成 Compose Secret、容器编排平台 Secret 或外部 Secret 管理系统，并建立令牌轮换与撤销流程。

## 6. Kibana 初识

- **开发工具 / 控制台（Dev Tools / Console）**：执行 REST API，是后续主要实验界面。
- **发现（Discover）**：浏览与筛选文档，需要先创建数据视图（data view）。
- **仪表盘 / Lens（Dashboards / Lens）**：构建可视化和仪表盘。
- **技术栈管理（Stack Management）**：管理索引、数据视图、用户角色、API 密钥等。

在开发工具中运行：

```http
GET /
GET /_cluster/health
GET /_cat/nodes?v
```

这些不带 `kbn:` 前缀的请求调用 Elasticsearch API，并以当前登录用户的身份执行，不使用 Kibana 的服务账户权限替代用户授权。

Console 也能调用 Kibana API，但必须使用 `kbn:` 前缀：

```http
GET kbn:/api/status
```

可以把两类请求理解为：

```text
GET /_cluster/health  ─→ Elasticsearch API
GET kbn:/api/status  ─→ Kibana API
```

## 7. 停止、清理与生产边界

停止并删除本节容器和默认网络，同时保留 Elasticsearch 数据、安全配置以及 Kibana 状态：

```bash
# Docker
docker compose down

# Podman
podman compose down
```

不带 `-v` 的 `compose down` 只删除容器和默认网络，`esconfig`、`esdata01`、`kibanabootstrap` 和 `kibanadata` 四个命名卷都会保留，之后执行 `compose up -d` 可以重新挂载它们。不要随意添加 `-v`；`compose down -v` 会删除这四个卷，其中的索引、TLS 证书、keystore、Kibana 服务令牌和保存对象都会丢失。命名卷能跨容器重建保留状态，但它不是备份或 Secret 管理系统。

这个示例只有一个节点、一个本地数据卷，没有跨主机容灾、可信企业证书、备份、集中日志、监控告警或容量规划。生产环境至少要重新设计：

- 多节点与故障域、节点角色和分片策略。
- Secret 管理、最小权限、TLS 证书生命周期和凭据轮换。
- 持久卷性能、快照仓库和恢复演练。
- 资源限制、启动检查、监控告警与升级流程。

## 练习与验收

- `.env` 已被 Git 忽略，`compose.yml` 可以被提交且不含密码或令牌。
- 能说明第 03 课和第 04 课为何使用不同的数据卷及 `elastic` 密码。
- 能解释 `container_name` 的作用与扩展限制，以及 `c04_` 资源前缀来自哪个项目名。
- 能区分复用 Compose 自己创建的容器、通过外部网络访问已有容器，以及通过外部卷复用数据。
- `docker compose ps -a` 或 `podman compose ps -a` 只显示 Elasticsearch 与 Kibana，且 Elasticsearch 健康、Kibana 正在运行。
- 能把本集群的 `http_ca.crt` 复制到宿主机，并使用 `curl --cacert` 验证 Elasticsearch API。
- 无需浏览器注册即可用 `elastic` 登录 Kibana，并在开发工具中查看集群健康状态。
- 能从宿主机访问 Kibana `5601` 端口并等待 `/api/status` 返回 `200`，也能在 Dev Tools 中使用 `GET kbn:/api/status`，并区分启动过程中的瞬时许可证 503 与独立的 Fleet 加密密钥错误。
- 能说明 1 GiB 限制只应用于 `es01`，而不是整个 Compose 项目。
- 能解释本节为何不使用注册令牌，以及 Kibana 服务账户令牌与用户密码为何不能互相替代。
- 能描述用户通过 Basic 方式登录 Kibana 后，请求如何由 Kibana 代理到 Elasticsearch HTTP API 并按用户权限授权。
- 能说明 Elasticsearch 启动脚本如何生成并复用包含 `es01` 的证书，以及如何幂等创建服务令牌、共享 CA。

## 参考资料

- [Elastic：在 Docker 中启动单节点集群](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-basic)
- [Elastic：使用 Docker 安装与配置 Kibana](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-kibana-with-docker)
- [Elastic：服务账户与服务账户令牌](https://www.elastic.co/docs/deploy-manage/users-roles/cluster-or-deployment-auth/service-accounts)
- [Elastic：Kibana 用户认证与 Basic 提供程序](https://www.elastic.co/docs/deploy-manage/users-roles/cluster-or-deployment-auth/kibana-authentication)
- [Elastic：Kibana 连接 Elasticsearch 的服务凭据](https://www.elastic.co/docs/reference/kibana/configuration-reference/general-settings)
- [Elastic：Fleet 常见问题与 Saved Objects 加密密钥](https://www.elastic.co/docs/troubleshoot/ingest/fleet/common-problems)
- [Elastic：`kibana-encryption-keys` 命令](https://www.elastic.co/docs/reference/kibana/commands/kibana-encryption-keys)
- [Elastic：在 Dev Tools Console 中区分 Elasticsearch 与 Kibana API](https://www.elastic.co/docs/explore-analyze/query-filter/tools/console)
- [Elastic：Kibana 状态 API](https://www.elastic.co/docs/api/doc/kibana/v8/operation/operation-get-status)
- [Elastic：安全自动配置及跳过条件](https://www.elastic.co/docs/deploy-manage/security/self-auto-setup)
- [Elastic：Docker 中的 Elasticsearch 配置目录](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-configure)
- [Elastic：数据目录与备份注意事项](https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/path)
- [Compose 规范：服务与 `container_name`](https://compose-spec.github.io/compose-spec/spec.html#container_name)
- [Docker Compose：项目名与资源隔离](https://docs.docker.com/compose/how-tos/project-name/)
- [Docker Compose：连接已有外部网络](https://docs.docker.com/compose/how-tos/networking/#use-an-existing-network)
- [Podman：`podman compose` 提供程序说明](https://docs.podman.io/en/stable/markdown/podman-compose.1.html)

上一节：[03｜容器部署](./03-container-installation.md)｜下一节：[05｜REST API](./05-rest-api-and-dev-tools.md)
