# 04｜使用 Compose 部署 Elasticsearch 与 Kibana

## 本节目标

- 用 Docker Compose 或 Podman Compose 启动可持久化的学习环境。
- 理解 Compose 的服务名、容器名、项目名及资源生命周期，并区分独立部署与复用已有服务。
- 完成 Kibana 首次注册，并区分注册令牌、服务账户令牌与用户密码。
- 理解手动注册如何扩展为 Compose 自动初始化，以及这个示例为何不是生产架构。

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
    environment:
      - discovery.type=single-node
    ports:
      - "127.0.0.1:${ES_PORT}:9200"
    volumes:
      - esdata01:/usr/share/elasticsearch/data
    mem_limit: ${MEM_LIMIT}
    healthcheck:
      test: ["CMD-SHELL", "curl -s --cacert config/certs/http_ca.crt https://localhost:9200 | grep -q 'missing authentication credentials'"]
      interval: 10s
      timeout: 10s
      retries: 60

  kib01:
    image: docker.elastic.co/kibana/kibana:${STACK_VERSION}
    ports:
      - "127.0.0.1:${KIBANA_PORT}:5601"
    volumes:
      - kibanaconfig:/usr/share/kibana/config
      - kibanadata:/usr/share/kibana/data
    depends_on:
      es01:
        condition: service_healthy

volumes:
  esdata01:
  kibanaconfig:
  kibanadata:
```

Elasticsearch 与 Kibana 必须使用完全相同的版本号。命名卷 `esdata01` 保存 Elasticsearch 数据；`kibanaconfig` 和 `kibanadata` 保存 Kibana 注册写入的 `kibana.yml`、CA 和安全存储等状态。它们都由 Compose 按项目隔离，删除或重建容器不会自动删除这些卷。

Kibana 配置卷中包含服务账户凭据，应视为敏感数据并限制访问。命名卷只是本地实验的持久化手段，不是生产环境的 Secret 管理系统。

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

再次执行 `podman compose up -d` 时，配置未变化的容器通常会继续使用；如果镜像或服务配置发生变化，Compose 可以删除旧容器并创建新容器。因此，持久数据必须放在命名卷中，不能依赖容器可写层。

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

本节后续采用主示例的**独立部署路线**：第 04 课由 Compose 同时创建新的 Elasticsearch 和 Kibana。选择延续路线时，后续密码和注册令牌命令需要针对第 03 课的 `es01` 执行。

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

如果所用 Compose 提供程序没有正确处理 `depends_on` 的健康状态条件，可以分两步启动，确认 Elasticsearch 健康后再启动 Kibana：

```bash
podman compose up -d es01
podman compose ps
podman compose up -d kib01
```

本例使用引擎管理的命名卷，适合 rootless Podman，不需要给卷添加 `:Z`。不要交替使用 `podman` 和 `sudo podman` 管理这套环境，否则会进入彼此隔离的容器、网络和卷存储。资源限制能否在 rootless 模式下生效还取决于主机的 cgroup 配置。

## 3. 手动完成 Kibana 首次注册

当前 `compose.yml` 只负责启动 Elasticsearch 和 Kibana，不会预先完成 Kibana 注册。首次打开 Kibana 时，需要使用 Elasticsearch 生成的注册令牌完成安全配对。

### 3.1 取得本集群的密码和注册令牌

Docker 用户执行：

```bash
docker compose exec es01 \
  /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic

docker compose exec es01 \
  /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana
```

Podman 用户执行：

```bash
podman compose exec es01 \
  /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic

podman compose exec es01 \
  /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana
```

这里重置的是第 04 课新集群的 `elastic` 密码。注册令牌是短期引导凭据，自动安全配置生成的令牌通常在 30 分钟内有效；过期后重新执行创建命令即可。

### 3.2 在浏览器中注册

1. 打开 `http://localhost:5601`。
2. 在 Kibana 初始化页面粘贴刚生成的注册令牌。
3. 如果页面要求验证码（verification code），按所用引擎执行以下命令。

```bash
# Docker
docker compose exec kib01 bin/kibana-verification-code

# Podman
podman compose exec kib01 bin/kibana-verification-code
```

4. 注册完成后，先按第 3.3 节等待 Kibana 完全就绪，再使用用户名 `elastic` 和第 3.1 节重置得到的密码登录。

注册发生在浏览器首次初始化页面，不是在现有 `.env` 或 `compose.yml` 中。注册成功后，Kibana 将与 Elasticsearch 通信所需的信任配置和服务账户凭据写入自己的配置；本例通过 `kibanaconfig` 和 `kibanadata` 卷持久化这些状态。后续重启或重建 Kibana 容器时不再持续使用那枚短期注册令牌。

### 3.3 等待 Kibana 完全就绪

提交注册令牌后，Kibana 还需要保存安全配置、建立 Elasticsearch 连接并初始化许可证及其他插件。浏览器如果在这个短暂窗口内访问 Kibana，可能看到：

```json
{"statusCode":503,"error":"Service Unavailable","message":"License information could not be obtained from Elasticsearch. Please check the logs for further details."}
```

这个响应通常表示许可证模块暂时还没有从 Elasticsearch 的 `/_license` 接口取得信息，不等于许可证无效，也不表示必须重新生成注册令牌或用户密码。

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

如果 503 持续存在，应检查 `compose ps` 和 Elasticsearch、Kibana 日志中的连接、TLS 或认证错误，再根据具体原因处理；不要把重置密码、重新注册或删除数据卷作为第一步。

日志中若同时出现 `FleetEncryptedSavedObjectEncryptionKeyRequired`，这是缺少 `xpack.encryptedSavedObjects.encryptionKey` 导致的独立 Fleet 配置问题，不是这个瞬时许可证 503 的原因。它主要影响 Fleet、Elastic Agent、告警和其他需要加密 Saved Objects 的功能；基础登录、Dev Tools 和许可证获取可以已经正常。需要使用 Fleet 时，应生成至少 32 个字符的稳定密钥并通过 Kibana keystore 或 Secret 管理系统配置，不要把密钥提交到 Git。

## 4. 区分 Kibana 凭据与用户登录凭据

注册令牌、Kibana 服务账户令牌和用户密码都参与安全流程，但它们属于不同主体：

| 凭据 | 代表谁 | 主要用途 | 生命周期 | 能否登录 Kibana |
| --- | --- | --- | --- | --- |
| Kibana 注册令牌 | 一次初始化操作 | 让 Kibana 找到并信任 Elasticsearch，取得后续服务通信所需的配置 | 短期有效，过期后重新生成 | 不能 |
| Kibana 服务账户令牌 | Kibana 机器身份 `elastic/kibana` | 让 Kibana 后台维护系统索引、迁移和任务等内部数据 | 不会自动过期，需要主动撤销 | 不能 |
| `elastic` 用户密码 | 人类用户 `elastic` | 登录 Kibana，或直接调用 Elasticsearch HTTP API | 重置前持续有效 | 能 |

### 4.1 Kibana 服务端自己的凭据

Kibana 本身是一个长期运行的服务。即使还没有用户打开浏览器，它也要启动、迁移 `.kibana*` 系统索引并运行后台任务，所以必须拥有独立的机器身份。

首次注册可概括为：

```text
注册令牌
  └─ 首次安全配对 ─→ Kibana 获得 CA 信任配置和服务账户令牌
                         └─ 后续启动 ─→ 以 elastic/kibana 身份访问 Elasticsearch
```

注册完成后，Kibana 服务端使用 `elastic/kibana` 服务账户令牌访问 Elasticsearch。这个令牌配置在 Kibana 服务端，不提供给浏览器用户，也不能用来登录 Kibana。它虽然能作为 Bearer Token 调用 Elasticsearch，但只能获得服务账户固定的权限，不等同于 `elastic` 超级用户。

这条通道主要服务于 Kibana 自身：

```text
Kibana 后台任务 ── elastic/kibana 服务账户令牌 ──→ Elasticsearch
```

也可以使用内置用户 `kibana_system` 及其专用密码替代服务账户令牌，但它同样是 Kibana 服务端凭据，不是人类用户的登录账号。本节的注册流程采用服务账户令牌。

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

## 5. 是否可以把注册自动化进 Compose

可以，但不能只增加一个静态注册令牌字段。Elasticsearch 必须先启动并健康，才能动态生成注册令牌；普通 `depends_on` 只负责启动依赖，不能把一个服务的命令输出安全地注入另一个服务。

Kibana 提供非交互式初始化命令：

```bash
bin/kibana-setup --enrollment-token <token> --silent
```

直接把令牌写入 `.env` 或 `compose.yml` 并不合适：它是敏感信息、会过期，而且新集群的令牌只能在 Elasticsearch 启动后生成。

需要一键初始化时，可扩展一个只运行一次的 `setup` 服务，按以下顺序编排：

```text
es01 健康
  └─→ setup 创建或安全写入 Kibana 服务凭据和 CA 配置
        └─→ setup 成功退出
              └─→ kib01 启动并使用服务账户凭据连接 es01
```

自动化版本至少需要处理以下事项：

- 通过共享卷或受限文件向 Kibana 提供 Elasticsearch CA，而不是关闭 TLS 校验。
- 为 Kibana 配置 `ELASTICSEARCH_HOSTS` 和服务账户令牌，或使用 `kibana_system` 的专用密码；不要让 Kibana 后台使用 `elastic` 超级用户密码。
- 通过 Compose Secret、外部 Secret 管理系统或 Kibana keystore 保存长期凭据，避免明文环境变量和进程列表泄露。
- 让 `setup` 幂等，并让 Kibana 等待 `service_completed_successfully`，以便重启和重复执行 Compose 时不会不断创建新凭据。

本节保留手动注册作为主线，是为了展示 Elastic 官方单节点快速入门使用的安全配对过程，并让学习者观察三类凭据的区别。自动化初始化适合作为完成本节后的进阶改造。

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

停止并删除本节容器和默认网络，同时保留 Elasticsearch 数据卷：

```bash
# Docker
docker compose down

# Podman
podman compose down
```

不要随意添加 `-v`。`compose down -v` 会同时删除第 04 课的 Elasticsearch 数据卷以及 Kibana 配置和数据卷，其中的索引、用户密码、注册配置和安全状态都会丢失。命名卷能跨容器重建保留数据，但它不是备份或 Secret 管理系统。

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
- `docker compose ps` 或 `podman compose ps` 显示 Elasticsearch 健康、Kibana 正在运行。
- 能完成浏览器注册并用 `elastic` 登录 Kibana，在开发工具中查看集群健康状态。
- 能从宿主机访问 Kibana `5601` 端口并等待 `/api/status` 返回 `200`，也能在 Dev Tools 中使用 `GET kbn:/api/status`，并区分注册后的瞬时许可证 503 与独立的 Fleet 加密密钥错误。
- 能说明 1 GiB 限制只应用于 `es01`，而不是整个 Compose 项目。
- 能解释注册令牌、Kibana 服务账户令牌与用户密码的区别，以及 Kibana 后台请求和用户请求为何使用不同身份。
- 能描述用户通过 Basic 方式登录 Kibana 后，请求如何由 Kibana 代理到 Elasticsearch HTTP API 并按用户权限授权。
- 能描述将注册流程自动化时需要的 `setup` 服务、CA、Secret 和幂等性要求。

## 参考资料

- [Elastic：在 Docker 中启动单节点集群](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-basic)
- [Elastic：使用 Docker 安装与配置 Kibana](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-kibana-with-docker)
- [Elastic：`kibana-setup` 命令](https://www.elastic.co/docs/reference/kibana/commands/kibana-setup)
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
