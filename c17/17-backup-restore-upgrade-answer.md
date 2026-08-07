# 17｜快照、恢复与滚动升级：练习与验收答案

建议先独立完成练习，再使用本页核对仓库注册、改名恢复和升级检查表。以下标记为 `http` 的请求在 Kibana 的开发工具（Dev Tools）中执行，并假定当前登录身份具有管理快照仓库和恢复所需的权限；标记为 `bash` 的命令在仓库根目录执行。

本实验只使用练习专用索引 `snapshot-lab-products-*` 和仓库 `course-repo`。不要在真实业务索引上执行恢复，也不要用文件系统命令直接修改仓库内容；真实仓库应只通过快照 API 写入。

## 0. 启动实验环境并确认配置生效

先按第 2.2 节通过包装脚本启动带快照叠加文件的实验环境。使用 Podman 且 Machine 已停止时，先执行 `podman machine start`；需要用 Docker 时按需执行：

```bash
# 按需执行一次；Podman 用户可以省略
export C17_COMPOSE_ENGINE=docker

./c17/compose.sh up -d
./c17/compose.sh ps -a
```

`snapshot-repo-init` 显示已成功退出是预期结果，`es01` 应为健康运行状态。

确认 `path.repo` 已在节点上生效：

```http
GET /_nodes/settings?filter_path=nodes.*.settings.path.repo
```

响应中应包含 `/mnt/es-backups`。如果为空，说明环境变量或卷挂载未生效，先排查 `c17/compose.snapshot.yml` 的合并结果（`./c17/compose.sh config`），不要跳过这一步直接注册仓库。

若第 2.3 节的实验数据还不存在，先创建：

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

## 1. 创建一个快照并恢复成不同索引名

第一步，注册文件系统仓库并验证所有节点可访问：

```http
PUT /_snapshot/course-repo
{
  "type": "fs",
  "settings": {"location":"/mnt/es-backups/course","compress":true}
}

POST /_snapshot/course-repo/_verify
```

`_verify` 的响应中应返回集群内每个节点的结果，`successful` 数量与数据节点数一致；任意节点返回错误都说明该节点无法一致访问仓库，此时不应继续创建快照。

第二步，创建只包含练习索引的快照：

```http
PUT /_snapshot/course-repo/snapshot-lab-001?wait_for_completion=true
{
  "indices": "snapshot-lab-products-*",
  "include_global_state": false,
  "metadata": {"reason":"course restore drill","owner":"search-team"}
}
```

`include_global_state: false` 表示只备份索引数据、不携带集群配置。响应中 `snapshot.state` 应为 `SUCCESS`。查看快照元数据，并列出仓库中的全部快照：

```http
GET /_snapshot/course-repo/snapshot-lab-001
GET /_snapshot/course-repo/_all
```

`GET /_snapshot/course-repo/_status` 只报告仍在进行中的快照任务；因为创建时使用了 `wait_for_completion=true`，此时返回 `"snapshots": []` 是正常预期，不代表仓库为空。

第三步，把快照恢复为不同索引名，不覆盖原索引：

```http
POST /_snapshot/course-repo/snapshot-lab-001/_restore
{
  "indices": "snapshot-lab-products-v1",
  "include_global_state": false,
  "rename_pattern": "snapshot-lab-products-(.+)",
  "rename_replacement": "restored-snapshot-lab-products-$1"
}
```

`rename_pattern` 匹配本次恢复的索引名并把前缀之后的部分捕获为组，`rename_replacement` 用 `$1` 引用该组，因此 `snapshot-lab-products-v1` 恢复为 `restored-snapshot-lab-products-v1`。响应中 `accepted` 应为 `true`；恢复是异步任务，稍等后确认两个索引并存：

```http
GET /_cat/indices/snapshot-lab-products-v1,restored-snapshot-lab-products-v1?v
```

预期原索引仍存在且文档数不变，同时出现 `restored-snapshot-lab-products-v1`。如果恢复请求被拒绝，检查 `rename_replacement` 生成的目标索引名是否已经存在，而不是删除线上同名索引。

重复实验时，每次为快照使用新的唯一名称（如 `snapshot-lab-002`），并为恢复使用新的目标索引名（如修改 `rename_replacement`），不要在旧快照上反复写入。

## 2. 抽样验证恢复索引的文档与查询

对照原索引与恢复索引的文档数：

```http
GET /_cat/indices/snapshot-lab-products-v1,restored-snapshot-lab-products-v1?v
```

预期两个索引的文档数相同。确认恢复索引的映射与源索引一致：

```http
GET /restored-snapshot-lab-products-v1/_mapping
```

预期 `name` 为 `keyword`、`price` 为 `scaled_float`（`scaling_factor` 为 100），与快照时一致。

抽样查询恢复索引：

```http
GET /restored-snapshot-lab-products-v1/_search
```

不带请求体的 `_search` 等价于 match_all，不设过滤条件；默认只返回前 10 条命中（`size` 默认值为 10），全部命中总数在 `hits.total` 中查看。预期 `hits.total` 为 1，并能查到 `course-snapshot-sample` 这条文档。

再用带条件的查询验证按条件检索也正常：

```http
POST /restored-snapshot-lab-products-v1/_search
{
  "query": {"term": {"name": "course-snapshot-sample"}}
}
```

预期同样命中 1 条。查询验证通过后，恢复演练才算完成——备份成功不等于能够恢复。

## 3. 写出升级前检查表

升级前检查表应至少覆盖快照、插件、客户端、弃用项和回滚方式，示例格式如下：

| 分类       | 检查内容                                               |
| ---------- | ------------------------------------------------------ |
| 快照       | 最近快照成功且完成过恢复演练；仓库可访问，RPO/RTO 明确 |
| 插件       | 目标版本插件兼容矩阵；自定义插件有兼容版本             |
| 客户端     | 各语言客户端兼容矩阵；连接集群的应用与脚本清单         |
| 弃用项     | 升级助手与弃用接口检查通过，无遗留弃用项               |
| 兼容矩阵   | 发布说明、不兼容变更；Elastic Stack 各组件版本兼容     |
| 预生产验证 | 预生产用真实数据量、查询和客户端验证                   |
| 回滚       | 明确回滚架构与触发条件；回退 = 旧版本集群 + 升级前快照 |
| 执行与验证 | 按官方顺序滚动升级，每次等待节点加入与集群稳定         |

检查表中最容易忽略的是回滚：升级节点会修改磁盘数据格式，通常不能通过简单降级二进制回滚。真正回退往往需要旧版本集群加升级前快照或数据重放，因此升级前必须把“快照已完成且演练过”作为回滚方案的前提，而不是留到故障发生时再想。升级执行后，还应验证集群健康、分片、写入、查询、Kibana、采集链路和业务指标。

## 4. 实验收尾

完成验证后，停止并删除实验容器，保留数据、认证信息和快照：

```bash
./c17/compose.sh down

# 仅使用 Podman Machine 时执行
podman machine stop
```

两种方式都不得在 `down` 后添加 `-v`。`podman machine stop` 只停止虚拟机，不删除其中的命名卷；不要执行 `podman machine rm`。
