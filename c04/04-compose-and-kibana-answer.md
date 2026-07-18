# 04｜使用 Compose 部署 Elasticsearch 与 Kibana：练习与验收答案

建议先独立完成部署和注册，再使用本页逐项核对。密码、注册令牌和服务账户令牌均不得写入本文件或提交到 Git。

## 1. 验证 `.env` 已被忽略且 Compose 文件不含凭据

在仓库根目录执行：

```bash
git check-ignore -v c04/.env
git status --short --ignored c04
```

第一条命令应显示命中仓库根目录 `.gitignore` 中的 `.env` 规则。第二条命令中，`c04/.env` 应带有 `!!` 标记，表示它已被忽略；`c04/compose.yml` 则可以作为普通文件提交。

当前 `compose.yml` 只引用版本号、端口和内存限制等变量，没有保存 `elastic` 密码、注册令牌、服务账户令牌或 API Key。变量引用本身不等于凭据泄露，但向 `.env` 添加密码或令牌仍不安全：它们应该通过 Compose Secret、Kibana keystore 或外部 Secret 管理系统提供。

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

`c04_` 是 Compose 默认项目名 `c04` 产生的资源前缀。默认项目名来自 `compose.yml` 所在目录，也可以用 `-p`、`COMPOSE_PROJECT_NAME` 或 Compose 顶层 `name` 改写。普通命名卷和网络会带项目名前缀，例如 `c04_esdata01` 和 `c04_default`。

## 4. 三种“复用”的区别

| 场景 | 做法 | 资源由谁管理 |
| --- | --- | --- |
| 复用同一 Compose 项目的容器 | 使用 `compose stop`、`compose start` 或再次执行 `compose up` | 仍由原 Compose 项目管理 |
| 访问已有容器 | 把 Compose 服务与已有容器接入同一个外部网络 | Compose 只管理自己创建的服务，不能接管已有容器 |
| 复用已有数据卷 | 将卷声明为 `external: true` 并指定实际卷名 | Compose 创建新容器，但不创建或删除该外部卷 |

同名不代表接管。把 `container_name` 写成已经存在的容器名只会产生名称冲突。

外部网络复用的是连接能力，已有容器仍按原来的方式启停。外部卷复用的是数据，不是容器；挂载 Elasticsearch 旧数据卷前必须停止旧节点、确认版本兼容并迁移完整安全配置。数据目录不能被两个节点同时写入，复制数据目录也不能替代受支持的快照备份。

## 5. Compose 服务运行状态

检查命令为：

```bash
podman compose ps
podman compose ps --format json
```

Docker 环境可将 `podman` 替换为 `docker`。验收时应看到 `es01` 的状态为 `running`、健康状态为 `healthy`，`kib01` 的状态为 `running`，并且端口只绑定到本机回环地址。

本机验收结果为：

```text
c04-es01-1   es01    running   healthy   127.0.0.1:9200->9200/tcp
c04-kib01-1  kib01   running             127.0.0.1:5601->5601/tcp
```

Kibana 没有在当前 Compose 文件中配置容器健康检查，所以其 `Health` 字段为空；`running` 加上 `/api/status` 返回 `200` 可以证明它已经就绪。

## 6. 完成 Kibana 注册、登录并查看集群健康状态

先生成第 04 课集群自己的登录密码和短期注册令牌：

```bash
podman compose exec es01 \
  /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic

podman compose exec es01 \
  /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana
```

打开 `http://localhost:5601`，粘贴注册令牌。如果页面要求验证码，执行：

```bash
podman compose exec kib01 bin/kibana-verification-code
```

注册完成并等待 Kibana 就绪后，用用户名 `elastic` 和刚重置得到的密码登录。在 Dev Tools 中执行：

```http
GET /_cluster/health
```

成功响应应包含 `cluster_name`、`status`、`number_of_nodes` 等字段。课程中的单节点集群可能因为副本无法分配而显示 `yellow`；这表示所有主分片都已分配，但至少一个副本未分配，不等于 Elasticsearch 无法读写。

这里的注册令牌只用于首次安全配对，不能用于登录。不得把命令输出中的密码、令牌或验证码保存到答案文件、终端日志截图或 Git 中。

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

提交注册令牌后短暂出现的许可证 `503` 通常表示 Kibana 尚未从 Elasticsearch 取得许可证信息。应先等待日志出现 `License fetched`，或等待 `/api/status` 返回 `200`。如果 `503` 持续存在，再检查 Elasticsearch 健康状态以及 Kibana 日志中的 TLS、连接和认证错误。

`FleetEncryptedSavedObjectEncryptionKeyRequired` 则表示没有为加密 Saved Objects 配置稳定密钥，主要影响 Fleet、告警等功能。它与注册后许可证尚未加载造成的瞬时 `503` 是两个独立问题；不能通过反复重置用户密码或重新生成注册令牌来解决 Fleet 密钥错误。

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
| Kibana 注册令牌 | 一次初始化操作，用于让 Kibana 找到并信任 Elasticsearch | 短期有效，过期后重新生成 | 不能 |
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

## 11. Compose 自动注册需要哪些设计

自动化初始化不能只在 `.env` 中写入一枚静态注册令牌，因为新集群必须启动后才能生成令牌，而且令牌短期有效并属于敏感信息。可增加一个只运行一次的 `setup` 服务，顺序为：

```text
es01 启动并健康
  └─→ setup 准备 CA 与 Kibana 服务凭据
        └─→ setup 成功退出
              └─→ kib01 启动并连接 es01
```

完整方案至少应做到：

- 通过共享卷或受限文件向 Kibana 提供 Elasticsearch CA，不关闭 TLS 校验。
- 为 Kibana 配置 `ELASTICSEARCH_HOSTS` 和服务账户令牌，或配置 `kibana_system` 的专用密码，不使用 `elastic` 超级用户作为后台身份。
- 使用 Compose Secret、Kibana keystore 或外部 Secret 管理系统保存长期凭据，避免写入 Git、普通环境变量和进程参数。
- 让 `setup` 可重复执行且结果一致，例如先检查已有配置再创建凭据，避免每次启动都生成新令牌。
- 让 `kib01` 依赖 `setup` 的 `service_completed_successfully`，确保初始化成功后才启动。

因此，手动注册适合本课程理解安全配对和凭据边界；自动化版本需要额外解决依赖编排、CA 分发、Secret 管理和幂等性，而不是简单地把浏览器操作搬进 Compose。
