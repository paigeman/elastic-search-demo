# 17｜快照、恢复与滚动升级

## 本节目标

- 配置快照仓库并完成恢复演练。
- 理解快照不是复制数据目录。
- 能制定兼容、可回滚的升级计划。

## 1. 快照原则

唯一受支持的集群备份方式是快照与恢复（snapshot/restore）。不要复制运行中节点的数据目录作为备份，也不要依赖独立磁盘冗余阵列（RAID）、云盘快照或数据卷本身替代集群快照。

快照仓库可以使用共享文件系统（`fs` 类型）或对象存储插件。集群节点必须以一致方式访问仓库，凭据应放在密钥库或云身份中，不得以明文写入 `elasticsearch.yml`。

## 2. 文件系统快照仓库实验

文件系统快照仓库是快照仓库的一种实现，其类型为 `fs`。这种仓库的配置原则不与某一份 Compose 文件的写法绑定。无论使用原生安装、Docker/Podman、Compose 还是容器编排平台，都必须满足以下条件：

1. 先选定独立于 Elasticsearch 数据目录的仓库介质。
2. 让所有主节点和数据节点以相同路径访问同一份仓库。
3. 让 Elasticsearch 运行用户能够在仓库中创建、打开、重命名和列出文件与目录。
4. 在每个相关节点的静态配置 `path.repo` 中加入该路径。
5. 重启节点使配置生效，然后再通过 API 注册和验证仓库。

同一原则在不同部署方式下的落点如下：

| 部署方式           | 如何让节点看到仓库                        | 如何配置 `path.repo`                         |
| ------------------ | ----------------------------------------- | -------------------------------------------- |
| 压缩包、DEB 或 RPM | 在操作系统上挂载本地磁盘或 NFS 等共享存储 | 修改每个节点的 `elasticsearch.yml`           |
| Docker 或 Podman   | 通过 `-v` 把卷或主机目录挂载到容器        | 使用镜像支持的环境变量或挂载配置文件         |
| Compose            | 在服务的 `volumes` 中挂载仓库             | 在 `environment` 或挂载的配置文件中设置      |
| Kubernetes 或 ECK  | 为相关 Pod 挂载同一个共享持久卷           | 通过 Pod 或 Elasticsearch 资源的节点配置设置 |

托管云环境不一定允许使用本地 `fs` 仓库，应使用平台提供的快照仓库和管理流程。

### 2.1 通用节点配置

假设每个节点内部都能通过 `/mnt/es-backups` 访问同一份仓库，在节点配置中加入：

```yaml
path.repo: ["/mnt/es-backups"]
```

这是静态节点配置，运行中的集群需要在配置后重启相关节点。多节点集群应滚动重启，每次等待节点重新加入和集群恢复稳定；课程的单节点环境则直接重启或重新创建该容器。

### 2.2 第 04 课 Compose 环境的参考实现

为了保持第 04 课的基础部署不变，本实验不直接修改 `c04/compose.yml`，而是通过 `c17/compose.snapshot.yml` 叠加快照实验所需配置：

```yaml
services:
  snapshot-repo-init:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    user: "0"
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        chown 1000:0 /mnt/es-backups
        chmod 0770 /mnt/es-backups
    volumes:
      - esbackups:/mnt/es-backups
    restart: "no"

  es01:
    environment:
      ES_SETTING_PATH_REPO: /mnt/es-backups
    volumes:
      - esbackups:/mnt/es-backups
    depends_on:
      snapshot-repo-init:
        condition: service_completed_successfully

volumes:
  esbackups:
```

`esbackups` 是与 `esdata01` 分离的仓库卷。`snapshot-repo-init` 是一次性初始化服务，它将卷的所有者设置为 Elasticsearch 镜像中的 `1000:0`，并在完成后退出；长期运行的服务仍然只有 `es01` 和 `kib01`。

`ES_SETTING_PATH_REPO` 是 Elasticsearch Docker 镜像对 `path.repo` 的环境变量写法：设置名转为大写、添加 `ES_SETTING_` 前缀，并将点号替换为下划线。因此 Compose 中的：

```yaml
ES_SETTING_PATH_REPO: /mnt/es-backups
```

在本例中等效于在 `elasticsearch.yml` 中配置一个仓库根目录：

```yaml
path.repo:
  - /mnt/es-backups
```

环境变量负责允许 Elasticsearch 使用该路径作为文件系统快照仓库；`esbackups:/mnt/es-backups` 则将 `esbackups` 命名卷挂载到容器内的 `/mnt/es-backups`，为快照仓库提供持久化存储。两项配置缺一不可。

这里的 `/mnt/es-backups` 是 Elasticsearch Linux 容器内的路径，不是 macOS 宿主机路径。在 macOS 上，Docker Desktop 和 Podman 都通过 Linux 虚拟机运行 Linux 容器，命名卷由容器引擎管理并挂载到该容器路径，因此这个配置同样生效，不要求 macOS 本身存在 `/mnt/es-backups`。不过，命名卷主要用于本机实验；如果需要直接在 macOS 上访问快照文件，或在删除容器虚拟机后仍保留快照，应改用宿主机目录绑定挂载或独立的外部存储。

第 04 课结束后，基础容器应已通过不带 `-v` 的 `compose down` 停止并删除。这不会删除该 Compose 项目的命名卷：索引和安全索引仍保存在 `esdata01`，Elasticsearch 证书、keystore 和配置仍保存在 `esconfig`，Kibana 服务令牌和保存对象也仍保存在各自的卷中。本节重建容器后会复用这些数据和认证状态，无需重新初始化集群。

进入第 04 课实验目录，让 Compose 继续读取其中的 `.env`：

```bash
cd c04
```

如果使用 Podman 且 Machine 已经停止，先执行 `podman machine start`。如果第 04 课的基础容器仍在运行，再按使用的容器引擎执行 `docker compose down` 或 `podman compose down`，不要添加 `-v`。

使用 Docker Compose 时执行：

```bash
docker compose \
  -f compose.yml \
  -f ../c17/compose.snapshot.yml \
  config

docker compose \
  -f compose.yml \
  -f ../c17/compose.snapshot.yml \
  up -d
```

使用 Podman Compose 时将上述命令中的 `docker compose` 替换为 `podman compose`。实验期间执行 `up`、`down`、`ps` 或 `logs` 时都应保留这两个 `-f` 参数，以免 Compose 在后续重建 `es01` 时丢失仓库挂载。可通过以下命令检查状态：

```bash
docker compose \
  -f compose.yml \
  -f ../c17/compose.snapshot.yml \
  ps -a
```

`snapshot-repo-init` 显示已成功退出是预期结果，`es01` 应为健康运行状态。不要使用 `down -v`；它会删除 Compose 项目的数据卷、配置卷和本实验的快照卷。

这个命名卷只用于在单节点课程环境中验证快照与恢复机制。它仍由同一台容器主机管理，不能证明主机损坏后仍可恢复。要演练这类故障，应将仓库替换为独立挂载目录、NFS 或对象存储，但通用步骤不变。

### 2.3 准备独立实验数据

本节使用独立的 `snapshot-lab-products-v1` 索引，不依赖前面课程遗留的索引状态。在 Kibana Dev Tools 中执行：

```http
PUT /snapshot-lab-products-v1
{
  "mappings": {
    "properties": {
      "name": {"type":"keyword"},
      "price": {"type":"scaled_float","scaling_factor":100}
    }
  }
}

POST /snapshot-lab-products-v1/_doc/1?refresh=true
{"name":"course-snapshot-sample","price":99.90}
```

## 3. 注册仓库并创建快照

节点重启且实验数据就绪后，先确认 `path.repo` 已经在节点上生效：

```http
GET /_nodes/settings?filter_path=nodes.*.settings.path.repo
```

响应中应包含 `/mnt/es-backups`。然后注册并验证仓库：

```http
PUT /_snapshot/course-repo
{
  "type": "fs",
  "settings": {"location":"/mnt/es-backups/course","compress":true}
}

POST /_snapshot/course-repo/_verify
```

创建快照：

```http
PUT /_snapshot/course-repo/snapshot-lab-001?wait_for_completion=true
{
  "indices": "snapshot-lab-products-*",
  "include_global_state": false,
  "metadata": {"reason":"course restore drill","owner":"search-team"}
}
```

查看：

```http
GET /_snapshot/course-repo/snapshot-lab-001
GET /_snapshot/course-repo/_status
```

如果重复实验，应为新快照使用新的唯一名称，例如 `snapshot-lab-002`，不要用文件系统命令修改仓库内容。

## 4. 恢复演练

不要直接覆盖线上同名索引。恢复为新名称：

```http
POST /_snapshot/course-repo/snapshot-lab-001/_restore
{
  "indices": "snapshot-lab-products-v1",
  "include_global_state": false,
  "rename_pattern": "snapshot-lab-products-(.+)",
  "rename_replacement": "restored-snapshot-lab-products-$1"
}
```

验证恢复后的文档数、映射和抽样数据：

```http
GET /_cat/indices/snapshot-lab-products-v1,restored-snapshot-lab-products-v1?v
GET /restored-snapshot-lab-products-v1/_mapping
GET /restored-snapshot-lab-products-v1/_search
```

预期原索引和恢复索引的文档数相同，并能在恢复索引中查到 `course-snapshot-sample`。备份成功不等于能够恢复；应定期在隔离环境演练，并记录恢复点目标（RPO）和恢复时间目标（RTO）。

重复恢复时，目标索引名不能已经存在。可以修改 `rename_replacement` 生成新的实验索引名，或者在确认不再需要后删除上一次生成的 `restored-snapshot-lab-products-v1`；不要为了解决同名冲突而覆盖真实业务索引。

完成验证后，应停止并删除实验容器以释放资源，同时保留数据、认证信息和快照：

```bash
# Docker Compose
docker compose \
  -f compose.yml \
  -f ../c17/compose.snapshot.yml \
  down

# Podman Compose
podman compose \
  -f compose.yml \
  -f ../c17/compose.snapshot.yml \
  down
podman machine stop
```

两种方式都不得在 `down` 后添加 `-v`。`podman machine stop` 只停止虚拟机，不删除其中的命名卷；不要执行 `podman machine rm`。

## 5. 快照生命周期管理

使用快照生命周期管理（SLM）定时创建、保留和删除快照。策略应覆盖业务索引、必要的功能状态与合规保留要求，并监控失败情况。不同环境或集群使用同一仓库时，只能有一个写入者，其他集群应将仓库注册为只读，以避免仓库损坏。

## 6. 升级计划

1. 阅读目标版本的发布说明、不兼容变更、插件和客户端兼容矩阵。
2. 运行升级助手和弃用接口，修复弃用项。
3. 确认最近快照成功且完成恢复演练。
4. 在预生产用真实数据量、查询和客户端验证。
5. 按官方版本路径升级，不能任意跨版本；保持 Elastic Stack 各组件版本兼容。
6. 滚动升级按官方节点顺序执行，每次等待节点加入和集群稳定。
7. 验证集群健康、分片、写入、查询、Kibana、采集链路和业务指标。

升级节点会修改磁盘数据格式，通常不能通过简单降级二进制回滚。真正回退往往需要旧版本集群 + 升级前快照/数据重放，因此升级前必须明确回滚架构。

## 练习与验收

- 创建一个快照并恢复成不同索引名。
- 抽样验证恢复索引的文档与查询。
- 写出升级前检查表，包含快照、插件、客户端、弃用项和回滚方式。

上一节：[16｜监控与排障](./16-monitoring-and-troubleshooting.md)｜下一节：[18｜性能与容量](./18-performance-and-capacity.md)
