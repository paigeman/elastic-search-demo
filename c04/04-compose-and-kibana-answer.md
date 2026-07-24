# 04｜使用 Compose 部署 Elasticsearch 与 Kibana：练习与验收答案

建议先独立完成自动化部署，再使用本页逐项核对。用户密码和服务账户令牌均不得写入本文件或提交到 Git。

## 1. 验证 `.env` 已被忽略且 Compose 文件不含凭据

在仓库根目录执行：

```bash
git check-ignore -v c04/.env
git status --short --ignored c04
```

第一条命令应显示命中仓库根目录 `.gitignore` 中的 `.env` 规则。第二条命令中，`c04/.env` 应带有 `!!` 标记，表示它已被忽略；`c04/compose.yml` 则可以作为普通文件提交。

当前 `compose.yml` 只引用版本号、端口和内存限制等非敏感变量，没有保存 `elastic` 密码、服务账户令牌或 API Key。Elasticsearch 启动脚本把证书创建到 `esconfig` 卷，把服务令牌写入 Elasticsearch 配置及 `kibanabootstrap` 卷，再由 Kibana 启动脚本写入 keystore。变量引用本身不等于凭据泄露，但向 `.env` 添加密码或令牌仍不安全。

本机验收时，`git check-ignore -v c04/.env` 的结果为：

```text
.gitignore:16:.env  c04/.env
```

## 2. 第 03 课与第 04 课为何使用不同的数据卷和密码

第 03 课的 Elasticsearch 是用 `docker run` 或 `podman run` 直接创建的，数据保存在引擎级命名卷 `esdata01` 中。第 04 课由 Compose 创建独立项目，逻辑卷 `esdata01` 默认会被命名为带项目前缀的实际卷，例如 `c04_esdata01`。

`elastic` 用户密码保存在 Elasticsearch 集群的安全索引中，安全索引又位于该集群的数据卷内。因此两个独立数据卷代表两个独立集群，各自拥有自己的安全状态和 `elastic` 密码。密码不由课程编号、容器名或镜像版本决定，所以不能直接拿第 03 课的密码登录第 04 课的新集群。

两课默认还会同时映射宿主机的 `9200` 端口。启动第 04 课前应停止第 03 课容器，但不需要删除第 03 课的数据卷。

## 3. `container_name`、扩展限制与 `c04_` 前缀

`es01` 和 `kib01` 是 Compose 的服务名。未设置 `container_name` 时，Compose 根据“项目名、服务名、副本序号”生成实际容器名，例如：

```text
c04-es01-1
c04-kib01-1
```

设置 `container_name` 可以固定容器名，但会绕过 Compose 的默认命名方式，并使该服务不能扩展为多个容器副本。因此日常管理应优先使用稳定的服务名，例如 `podman compose logs es01`，而不依赖实际容器名。

`c04_` 是 Compose 默认项目名 `c04` 产生的资源前缀。默认项目名来自 `compose.yml` 所在目录，也可以用 `-p`、`COMPOSE_PROJECT_NAME` 或 Compose 顶层 `name` 改写。普通命名卷和网络会带项目名前缀，例如 `c04_esconfig`、`c04_esdata01` 和 `c04_default`。

## 4. 三种“复用”的区别

| 场景 | 做法 | 资源由谁管理 |
| --- | --- | --- |
| 复用同一 Compose 项目的容器 | 使用 `compose stop`、`compose start` 或再次执行 `compose up` | 仍由原 Compose 项目管理 |
| 访问已有容器 | 把 Compose 服务与已有容器接入同一个外部网络 | Compose 只管理自己创建的服务，不能接管已有容器 |
| 复用已有数据卷 | 将卷声明为 `external: true` 并指定实际卷名 | Compose 创建新容器，但不创建或删除该外部卷 |

同名不代表接管。把 `container_name` 写成已经存在的容器名只会产生名称冲突。

外部网络复用的是连接能力，已有容器仍按原来的方式启停。外部卷复用的是数据，不是容器；挂载 Elasticsearch 旧数据卷前必须停止旧节点、确认版本兼容并迁移完整安全配置。数据目录不能被两个节点同时写入，复制数据目录也不能替代受支持的快照备份。

当前 Compose 使用 `esconfig`、`esdata01`、`kibanabootstrap` 和 `kibanadata` 四个命名卷。`compose down` 不带 `-v` 时只删除容器和默认网络，这四个卷及其中的 TLS 配置、索引数据、服务令牌和 Kibana 状态都会保留；`compose down -v` 才会连同项目命名卷一起删除。旧版部署如果没有 `esconfig`，即使 `esdata01` 仍在，也不能在迁移 Elasticsearch keystore 等完整配置之前直接重建 Elasticsearch 容器。

## 5. Compose 服务运行状态

检查命令为：

```bash
podman compose ps -a
podman compose ps -a --format json
```

Docker 环境可将 `podman` 替换为 `docker`。验收时只应看到两个服务：`es01` 的状态为 `running`、健康状态为 `healthy`，`kib01` 为 `running`，并且端口只绑定到本机回环地址。

本机验收结果为：

```text
c04-es01-1  es01   running   healthy   127.0.0.1:9200->9200/tcp
c04-kib01-1 kib01  running             127.0.0.1:5601->5601/tcp
```

Kibana 没有在当前 Compose 文件中配置容器健康检查，所以其 `Health` 字段为空；`running` 加上 `/api/status` 返回 `200` 可以证明它已经就绪。

## 6. 验证自动初始化、复制 CA 并查看集群健康状态

先确认 Elasticsearch 启动时已完成初始化，且日志没有输出私钥或令牌值：

```bash
podman compose logs es01
```

日志开头应包含：

```text
Elasticsearch certificates and Kibana bootstrap files are ready
```

HTTP 证书的 SAN 包含 `es01`、`localhost` 和 `127.0.0.1`，因此 Kibana 可以使用 `full` 模式同时验证 CA 和主机名，不需要 `certificate` 兼容模式。

再重置第 04 课集群自己的用户登录密码：

```bash
podman compose exec es01 \
  /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic
```

从宿主机直接调用 Elasticsearch API 前，复制第 04 课集群自己的 HTTP CA：

```bash
podman compose cp \
  es01:/usr/share/elasticsearch/config/certs/c04/ca/ca.crt \
  ./http_ca.crt

export ES_URL=https://localhost:9200
export ES_CA="$PWD/http_ca.crt"

curl --cacert "$ES_CA" -u elastic "$ES_URL"
```

`curl` 会提示输入本节重置得到的 `elastic` 密码。第 03 课的证书属于另一个独立集群，不能用于验证第 04 课的 HTTPS 连接；也不应使用 `curl -k` 关闭证书校验。Docker 用户将命令中的 `podman` 替换为 `docker`。

打开 `http://localhost:5601` 应直接看到登录页，不需要注册令牌或验证码。用用户名 `elastic` 和刚重置得到的密码登录，在 Dev Tools 中执行：

```http
GET /_cluster/health
```

成功响应应包含 `cluster_name`、`status`、`number_of_nodes` 等字段。课程中的单节点集群可能因为副本无法分配而显示 `yellow`；这表示所有主分片都已分配，但至少一个副本未分配，不等于 Elasticsearch 无法读写。

Kibana 后台已经使用 Elasticsearch 启动脚本创建的 `elastic/kibana` 服务账户令牌；它与用户登录密码无关。不得读取、打印或提交 `kibanabootstrap` 中的令牌原文。

## 7. Kibana 状态 API、瞬时 503 与 Fleet 错误

从宿主机检查 Kibana 自身的 API：

```bash
curl --silent --output /dev/null \
  --write-out '%{http_code}\n' \
  http://127.0.0.1:5601/api/status
```

本机验收返回：

```text
200
```

登录 Kibana 后，在 Dev Tools 中调用同一个 Kibana API 必须使用 `kbn:` 前缀：

```http
GET kbn:/api/status
```

不带 `kbn:` 的 `GET /api/status` 会被 Dev Tools 当作 Elasticsearch API 发往 `9200`，因此不是正确的 Kibana 状态检查方式。

自动启动后短暂出现的许可证 `503` 通常表示 Kibana 尚未完成连接、保存对象迁移或许可证读取。应先等待日志出现 `License fetched`，或等待 `/api/status` 返回 `200`。如果 `503` 持续存在，再检查 Elasticsearch 健康状态以及 Elasticsearch、Kibana 日志中的 TLS、连接和认证错误。

`FleetEncryptedSavedObjectEncryptionKeyRequired` 则表示没有为加密 Saved Objects 配置稳定密钥，主要影响 Fleet、告警等功能。它与启动时许可证尚未加载造成的瞬时 `503` 是两个独立问题；不能通过反复重置用户密码或重新创建服务令牌来解决 Fleet 密钥错误。

## 8. 1 GiB 内存限制的作用范围

`MEM_LIMIT=1073741824` 等于 1 GiB，并通过以下配置只应用于 `es01`：

```yaml
services:
  es01:
    mem_limit: ${MEM_LIMIT}
```

`kib01` 没有 `mem_limit`，因此该值既不是 Kibana 的限制，也不是整个 Compose 项目的总内存上限。主机或 Podman Machine 必须同时容纳 Elasticsearch、Kibana、容器运行时和操作系统的内存开销，实际所需内存会高于 1 GiB。

## 9. 三类凭据以及后台请求与用户请求的身份

| 凭据 | 身份和用途 | 生命周期 | 能否登录 Kibana |
| --- | --- | --- | --- |
| Kibana 注册令牌 | 手动注册方案中的一次性配对凭据；本节自动化流程不使用 | 短期有效，过期后重新生成 | 不能 |
| Kibana 服务账户令牌 | 机器身份 `elastic/kibana`，用于 Kibana 后台访问 Elasticsearch | 不会自动过期，需要主动撤销 | 不能 |
| `elastic` 用户密码 | 人类用户 `elastic`，用于登录 Kibana 或直接调用 Elasticsearch | 重置前持续有效 | 能 |

Kibana 即使没有用户登录，也要迁移 `.kibana*` 系统索引并运行后台任务，所以后台通信使用专用机器身份。用户在 Dev Tools、Discover 或 Dashboard 发起的操作则必须按照该登录用户的角色授权。两条请求通道身份不同，Kibana 不会把自己的服务账户权限借给浏览器用户。

## 10. Basic 登录后的请求路径与授权

请求路径可以表示为：

```text
浏览器
  └─ Basic 登录凭据 ─→ Kibana
                        └─ 向 Elasticsearch 验证用户身份

浏览器
  └─ Kibana 会话 ─→ Kibana
                     └─ 携带用户认证上下文 ─→ Elasticsearch HTTP API
                                                └─ 按用户角色授权
```

浏览器只访问 Kibana 的 `5601` 端口，不直接访问 Elasticsearch 的 `9200` 端口。登录成功后，浏览器保存 Kibana 会话；Kibana 代理后续请求，Elasticsearch 最终根据登录用户的身份和角色决定是否允许操作。使用 `elastic` 登录时拥有超级用户权限，换成低权限用户后，即使界面相同，也只能执行该用户获准的操作。

## 11. Compose 自动初始化的设计

本节没有把静态注册令牌写入 `.env`，而是由 Elasticsearch 启动脚本自动生成稳定证书和长期 Kibana 机器凭据：

```text
start-elasticsearch.sh 生成或复用证书和服务令牌，并复制 CA
  └─ es01 使用证书启动并通过 HTTPS 健康检查
       └─ kib01 将令牌写入 keystore 并以 full 模式连接 es01
```

验收时应确认：

- Compose 只包含 `es01` 和 `kib01` 两个长期服务。
- `ELASTICSEARCH_HOSTS` 使用稳定服务名 `https://es01:9200`。
- HTTP 证书包含 `es01` SAN，Kibana 通过只读共享卷取得 CA 并执行完整 TLS 校验。
- Kibana keystore 中存在 `elasticsearch.serviceAccountToken` 键名，但检查时不输出值。
- 不带服务名执行 `compose stop` 和 `compose start` 后，Elasticsearch 与 Kibana 都能恢复，Kibana 状态返回 `200`。

`kibanabootstrap` 是本地课程中的受限共享卷，仍保存令牌原文；生产环境应使用 Compose Secret 或外部 Secret 管理系统，并建立轮换和撤销机制。
