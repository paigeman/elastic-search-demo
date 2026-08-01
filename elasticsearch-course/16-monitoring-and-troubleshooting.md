# 16｜监控与故障排查

## 本节目标

- 建立从现象到根因的排障路径。
- 使用集群健康、分配解释、节点统计、任务和日志等接口。
- 处理黄色或红色状态、磁盘水位、慢查询、429 响应与 Java 虚拟机压力。

## 1. 先收集证据

下面这些接口不是功能重复的“监控接口”，而是从不同层次回答问题：

| 接口                      | 回答的问题                                                   | 数据性质                               | 后续检查对象                                     |
| ------------------------- | ------------------------------------------------------------ | -------------------------------------- | ------------------------------------------------ |
| `/_cluster/health`        | 集群和索引的分片是否正常分配                                 | 调用时的状态快照                       | `/_cat/shards`、`/_cluster/allocation/explain`   |
| `/_cat/nodes`             | 哪个节点的处理器、堆内存或磁盘明显异常                       | 调用时的状态快照                       | 异常节点的 `/_nodes/stats` 结果和节点日志        |
| `/_cat/indices`           | 问题集中在哪个索引                                           | 调用时的索引概览                       | `/_cat/shards`、索引设置和映射                   |
| `/_cat/shards`            | 具体是哪一个主分片或副本处于异常状态                         | 调用时的分片明细                       | `/_cluster/allocation/explain`                   |
| `/_nodes/stats`           | 各节点在搜索、写入、垃圾回收、文件系统和线程池方面发生了什么 | 既有当前值，也有节点启动以来的累计计数 | 两个采样时刻的统计差值、慢日志和业务流量趋势     |
| `/_cluster/pending_tasks` | 主节点的集群状态更新任务是否积压                             | 调用时仍在排队的任务                   | 索引创建与映射变更频率、分片分配活动和主节点压力 |
| `/_tasks`                 | 当前有哪些搜索、写入、重索引等任务正在执行                   | 调用时仍在运行的任务                   | 任务的 `action`、运行时长、可取消性和业务影响    |

这些接口不是必须依次全部调用。推荐的排查关系是：

1. 在调用接口前先记录故障时间窗口、时区、受影响请求和追踪标识。
2. 使用 `/_cluster/health` 建立分片分配概览。
3. 根据现象选择分支：
   - 集群为黄色或红色：依次查看 `/_cat/indices`、`/_cat/shards` 和 `/_cluster/allocation/explain`。
   - 出现 429、高延迟或资源告警：先用 `/_cat/nodes` 定位异常节点，再用 `/_nodes/stats` 深入检查。
   - 集群变更长时间不生效：查看 `/_cluster/pending_tasks`；请求或后台操作长时间不结束：查看 `/_tasks`。
4. 将接口结果与同一时间窗口内的应用日志、节点日志、业务流量以及部署和配置变更关联起来。

因此，下面的编号用于组织讲解，不代表固定的执行顺序。

### 1.1 集群健康：建立分片分配概览

```http
GET /_cluster/health?level=indices
```

重点看：

- `status`：`green` 表示主分片和副本都已分配；`yellow` 表示主分片可用但至少一个副本未分配；`red` 表示至少一个主分片未分配，部分数据可能不可用。
- `unassigned_shards`、`initializing_shards`、`relocating_shards`：分别表示未分配、正在初始化和正在迁移的分片数。
- `number_of_pending_tasks` 和 `task_max_waiting_in_queue_millis`：帮助判断主节点的集群状态更新队列是否积压。
- `indices`：因为设置了 `level=indices`，响应会继续列出每个索引的健康状态，可以先确定是全局问题还是单个索引的问题。

这个接口只反映**分片分配健康度**。即使结果是 `green`，查询仍可能很慢、线程池仍可能拒绝请求，应用也仍可能报错。

### 1.2 节点概览：定位资源异常节点

```http
GET /_cat/nodes?v&h=name,node.role,heap.percent,ram.percent,cpu,load_1m,disk.used_percent
```

`v` 用于显示表头，`h` 用于指定列。各列含义如下：

- `name`、`node.role`：节点名称和角色，用来判断异常是否只发生在数据节点、主节点或摄取节点。
- `heap.percent`：Elasticsearch JVM 当前使用的堆内存百分比；持续高位且垃圾回收后不下降才值得重点调查。
- `ram.percent`：操作系统已使用的内存百分比，不等于 JVM 堆内存。Linux 使用空闲内存作为文件缓存很正常，不能仅凭这个值判断内存泄漏。
- `cpu`：当前处理器使用率快照；一次尖峰不能代表长期过载。
- `load_1m`：最近 1 分钟系统平均负载，它不是百分比，需要结合处理器核数解释。
- `disk.used_percent`：节点所在磁盘的已用比例，接近磁盘水位时继续调查分片分配和磁盘增长。

横向比较各节点通常比盯着一个绝对数值更有用。例如只有一个数据节点的 `heap.percent` 和 `cpu` 明显高，可能存在分片或路由热点。

### 1.3 索引与分片：定位分配异常对象

```http
GET /_cat/indices?v&s=health,index
GET /_cat/shards?v&s=state,index
```

- `/_cat/indices` 每行表示一个索引。先看 `health`，再看主分片数 `pri`、副本数 `rep`、文档量和存储量，识别异常或增长过快的索引。`s=health,index` 只负责排序。
- `/_cat/shards` 每行表示一个分片副本。重点看 `prirep`（`p` 为主分片、`r` 为副本）、`state`、所在 `node` 和 `unassigned.reason`。它能把“某索引是黄色或红色”继续缩小到“哪个分片副本没有分配”。

CAT 接口是面向人的表格，不适合作为程序的稳定数据契约；自动化采集应优先使用相应的 JSON API。

### 1.4 节点统计：深入分析资源和工作量

```http
GET /_nodes/stats/jvm,fs,os,process,indices,thread_pool
```

这个响应很大，第一次排障可以重点检查：

- `jvm.mem.heap_used_percent`：当前堆内存使用率。
- `jvm.gc.collectors.*.collection_count` 和 `collection_time_in_millis`：垃圾回收次数与耗时。
- `fs.total`、`fs.io_stats`：磁盘容量和输入输出累计情况。
- `indices.search.query_total`、`query_time_in_millis`：搜索查询累计次数和累计耗时。
- `indices.indexing.index_total`、`index_time_in_millis`：索引写入累计次数和累计耗时。
- `thread_pool.search`、`thread_pool.write`、`thread_pool.write_coordination`：分别表示搜索线程池、实际写入与摄取处理线程池、Bulk 请求协调线程池。每个线程池都包含 `active`（当前正在执行的任务数）、`queue`（当前排队的任务数）、`completed`（节点启动以来完成的任务数）和 `rejected`（节点启动以来拒绝的任务数）。因此，这里是三个线程池各看四个字段，而不是三个线程池共用四个值。

这里最容易犯的错误，是把累计计数当成“当前一分钟”的数值。许多 `*_total`、`*_time_in_millis`、`completed` 和 `rejected` 字段从节点启动后持续累加，节点重启后会重置；必须对两个采样时刻求差，才能解释某个时间段内的变化。

### 1.5 待处理任务与运行中任务：区分队列和任务

```http
GET /_cluster/pending_tasks
GET /_tasks?detailed=true&actions=*
```

- `/_cluster/pending_tasks` 只显示等待主节点处理的**集群状态更新任务**，例如创建索引、更新映射或分片分配。重点看 `source`、`priority` 和 `time_in_queue_millis`。它不是普通搜索/写入请求的线程池队列。
- `/_tasks` 显示调用当下仍在运行的可见任务。`detailed=true` 增加任务描述，`actions=*` 表示不限制动作类型。重点看 `action`、`running_time_in_nanos`、`cancellable` 和 `description`。任务完成后通常不会继续出现在这个列表中，所以它也不是任务历史记录。

生产集群上可以先按动作过滤，避免返回过多内容。例如只看搜索任务：

```http
GET /_tasks?detailed=true&actions=indices:data/read/search*
```

不要仅因一个任务运行时间长就直接取消；先确认它对应的业务、是否可取消以及取消后的影响。

### 1.6 贯穿全程的“时间窗口”在哪里体现

上面 7 个取证请求都**不支持通过参数查询某个历史时间窗口**。集群健康接口、CAT 接口、`/_cluster/pending_tasks` 和 `/_tasks` 主要提供调用当下的快照；节点统计接口包含大量累计计数，但也不会替你计算“最近 15 分钟”。

有些接口支持 `timeout`、`master_timeout` 或 `wait_for_status`，但它们表示“这次请求最多等待多久”或“等待某个状态出现”，也不是查询过去一段时间的数据。

时间窗口需要在排障开始时建立，并贯穿后续取证和关联分析。假设故障发生在北京时间 `2026-08-01 14:00:00` 至 `14:15:00`，应当：

1. 把起止时间、时区、受影响请求或追踪标识记入事件记录，并选择一个正常时段作为基线。
2. 在窗口开始和结束时分别采样同一个统计接口；用 `T1 - T0` 计算窗口内的查询数、拒绝数和垃圾回收耗时。对只有当前值的指标，应持续采样或使用监控系统保存时间序列。
3. 在应用日志、Elasticsearch 节点日志和部署记录中使用同一时间范围做关联分析。

下面的请求可以在两个时刻各执行一次。`filter_path` 只是缩小响应字段，**不是**设置时间窗口：

```http
GET /_nodes/stats/jvm,indices,thread_pool?filter_path=nodes.*.name,nodes.*.timestamp,nodes.*.jvm.uptime_in_millis,nodes.*.jvm.gc.collectors.*.collection_time_in_millis,nodes.*.indices.search.query_total,nodes.*.indices.search.query_time_in_millis,nodes.*.indices.indexing.index_total,nodes.*.thread_pool.search.rejected,nodes.*.thread_pool.write.rejected,nodes.*.thread_pool.write_coordination.rejected
```

例如，两个时刻的 `search.rejected` 分别为 120 和 145，那么窗口内新增了 25 次搜索拒绝；若 `jvm.uptime_in_millis` 变小，则节点在两次采样之间重启过，累计值不能直接相减。

如果日志已经写入 Elasticsearch，时间范围才会明确出现在搜索请求的 `range` 条件中：

```http
GET logs-*/_search
{
  "size": 100,
  "query": {
    "range": {
      "@timestamp": {
        "gte": "2026-08-01T14:00:00+08:00",
        "lt": "2026-08-01T14:15:00+08:00"
      }
    }
  },
  "sort": [
    { "@timestamp": "asc" }
  ]
}
```

这里的 `logs-*` 和 `@timestamp` 需要替换为实际的日志数据流/索引模式和时间字段。若日志只在节点本地，则应使用日志工具按相同的起止时间过滤。无论采用哪种方式，都要同时记录部署与配置变更；单个瞬时数值没有趋势和基线时很容易误判。

## 2. 集群处于黄色或红色状态

列出未分配分片：

```http
GET /_cat/shards?v&h=index,shard,prirep,state,unassigned.reason,node&s=state
```

解释一个分片为何不能分配：

```http
POST /_cluster/allocation/explain
{
  "index": "目标索引",
  "shard": 0,
  "primary": false
}
```

常见原因包括：单节点无处放置副本、节点离线、磁盘达到水位、分配过滤条件与数据层不匹配、节点达到分片上限或分片正在恢复。不要看到红色状态就立刻强制分配陈旧主分片；该操作可能导致数据丢失，应先确认快照、节点数据和恢复路径。

## 3. 磁盘水位

“磁盘水位”是 Elasticsearch 为防止节点磁盘写满而设置的磁盘使用阈值。它不是普通告警线；达到不同水位后，Elasticsearch 会主动采取保护措施。默认值和行为如下：

| 水位                   | 默认磁盘使用率 | 保护行为                                   |
| ---------------------- | -------------: | ------------------------------------------ |
| 低水位 `low`           |            85% | 通常不再向该节点分配更多分片               |
| 高水位 `high`          |            90% | 尝试把已有分片迁移到其他节点               |
| 洪水水位 `flood_stage` |            95% | 阻止受影响索引的普通写入，防止磁盘彻底写满 |

“低水位”表示最先触发的一级保护，不是磁盘使用率很低。水位可以被修改，排障时应同时查看集群的实际配置和各节点的磁盘使用情况：

```http
GET /_cluster/settings?include_defaults=true&filter_path=*.cluster.routing.allocation.disk.watermark*
GET /_cat/allocation?v&h=node,disk.percent,disk.avail,disk.total,disk.used,shards
```

百分比水位表示已用空间比例；如果水位配置为字节值，则表示剩余可用空间。磁盘达到水位会限制分片分配，严重时索引可能进入只读保护。处理顺序：

1. 确认增长最快的索引和节点。
2. 临时止血：扩充磁盘或增加节点，并按已批准的保留策略清理已有快照的数据。
3. 等分片重新平衡并确认磁盘回落。
4. 如果写保护未自动解除，再按当前版本文档检查并解除写入阻止状态。
5. 修正 ILM 或保留期配置、分片规划和容量告警规则。

不要直接删除未知索引，也不要仅提高水位百分比掩盖容量不足。

## 4. 429 与线程池拒绝

```http
GET /_cat/thread_pool/search,write,write_coordination?v&h=node_name,name,active,queue,rejected,completed
GET /_nodes/hot_threads?threads=3&ignore_idle_threads=true
```

`search` 处理分片级搜索，`write` 处理实际写入与摄取处理，`write_coordination` 处理 Bulk 请求协调。应根据错误正文指出的线程池确定拒绝发生在哪一层。

检查流量变化、批量写入的批次大小与并发度、慢查询、大型聚合、分片数量、垃圾回收停顿和磁盘延迟。客户端退避是保护措施，不是根因修复。不要盲目增大队列，队列只会把失败变成更高延迟和更多内存占用。

## 5. Java 虚拟机与熔断

关注堆内存使用趋势、垃圾回收停顿、老年代占用和熔断触发记录。堆内存使用率过高通常由高基数聚合、过多的分片或字段、过大的请求或响应、`fielddata` 占用以及索引缓冲区压力引起。堆内存长期处于高位且垃圾回收后不回落时，需要调查占用堆内存的对象来源，不能只是增加堆内存。

## 6. 慢查询

- 从应用端确认端到端第 95 和第 99 百分位延迟及超时情况，不能只看 `took`。
- 使用慢日志进行受控采样，避免阈值过低而产生日志风暴。
- 在测试环境或生产低峰期，对一条具有代表性的搜索请求设置 `"profile": true`，查看查询和聚合等组件的执行耗时。性能剖析会显著增加搜索开销，其耗时不能与未启用剖析的请求直接比较，也不应在生产环境中默认启用。
- 检查查询是否跨越过多分片，或包含深分页、脚本、前导通配符、嵌套查询或大型聚合。
- 对照映射、分析器和真实查询的命中分布。

## 7. 标准事件记录

每次事故至少记录：开始/恢复时间、用户影响、检测方式、时间线、直接原因、促成因素、止血动作、永久修复、责任人与期限。“重启后恢复”只说明采取了重启这一处置动作以及服务随后恢复的结果，不能解释故障为何发生；仍需结合重启前后的日志、指标和状态变化查明根因。

## 练习与验收

- 逐项说明本节 7 个证据收集接口回答的问题，并指出哪些是快照、哪些包含累计计数。
- 对节点统计接口采样两次，计算这段时间内新增的搜索次数和线程池拒绝次数；说明节点重启为何会让差值失真。
- 在单节点设置一个副本制造黄色状态，用分配解释接口说明原因。
- 能区分搜索请求被拒绝、Java 虚拟机内存使用率过高和磁盘水位告警。
- 写一份 429 排障检查单，不把“调大队列”列为第一步。

上一节：[15｜安全](./15-security.md)｜下一节：[17｜备份与升级](./17-backup-restore-upgrade.md)
