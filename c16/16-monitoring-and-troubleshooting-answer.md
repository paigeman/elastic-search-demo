# 16｜监控与故障排查：练习与验收答案

建议先独立完成练习，再使用本页核对接口用途、时间窗口、故障证据和排查顺序。以下标记为 `http` 的请求都在 Kibana 的开发工具（Dev Tools）中的控制台（Console）执行，并假定当前登录身份具有读取集群和节点监控信息所需的 `monitor` 权限。

第 3 题会创建练习专用索引 `monitoring-c16-yellow`，只应在课程的单数据节点实验集群中执行。不要为了制造故障而修改生产索引的副本数、分片分配规则或磁盘水位。

## 1. 说明 7 个证据收集接口

| 接口                             | 回答的问题                                       | 数据性质             | 关键观察项                                       |
| -------------------------------- | ------------------------------------------------ | -------------------- | ------------------------------------------------ |
| `/_cluster/health?level=indices` | 集群和各索引的分片是否正常分配                   | 当前快照             | `status`、未分配/初始化/迁移分片数、待处理任务数 |
| `/_cat/nodes`                    | 哪个节点的处理器、堆内存或磁盘明显异常           | 当前快照             | 节点角色、堆内存、处理器、负载和磁盘使用率       |
| `/_cat/indices`                  | 黄色或红色状态集中在哪个索引                     | 当前索引概览         | `health`、主分片数、副本数、文档数和存储量       |
| `/_cat/shards`                   | 具体哪个主分片或副本未分配、初始化或迁移         | 当前分片明细         | `prirep`、`state`、`node`、`unassigned.reason`   |
| `/_nodes/stats`                  | 节点的资源使用量和搜索、写入、线程池等工作量如何 | 当前值与累计计数混合 | JVM、垃圾回收、文件系统、搜索、写入和线程池统计  |
| `/_cluster/pending_tasks`        | 主节点的集群状态更新队列是否积压                 | 当前仍在排队的任务   | `source`、`priority`、`time_in_queue_millis`     |
| `/_tasks`                        | 当前有哪些可见任务仍在运行                       | 当前仍在运行的任务   | `action`、运行时长、`cancellable`、`description` |

分类时应特别注意：

- `/_cluster/health`、CAT 接口、`/_cluster/pending_tasks` 和 `/_tasks` 主要是调用时的快照，不接受“过去 15 分钟”这样的历史查询范围。
- `/_nodes/stats` 中的 `active`、`queue`、堆内存使用量等是当前值；`query_total`、`query_time_in_millis`、`completed`、`rejected` 和垃圾回收累计耗时等通常从节点启动后持续累加。
- 累计值本身不能表示最近一分钟的变化，必须在两个时刻采样后求差。
- `/_cluster/pending_tasks` 查看集群状态更新队列，`/_tasks` 查看运行中任务，两者不是同一种队列，也不能互相替代。

验收时应能根据现象选择分支，而不是机械地依次调用全部接口：黄色或红色状态进入索引和分片分支；429、高延迟或资源告警进入节点统计分支；集群变更迟迟不生效时查看待处理任务。

## 2. 对节点统计采样两次并计算差值

在时间窗口开始时执行一次下面的请求并保存响应，间隔 60 秒后以完全相同的请求再次采样：

```http
GET /_nodes/stats/jvm,indices,thread_pool?filter_path=nodes.*.name,nodes.*.timestamp,nodes.*.jvm.uptime_in_millis,nodes.*.jvm.gc.collectors.*.collection_time_in_millis,nodes.*.indices.search.query_total,nodes.*.indices.search.query_time_in_millis,nodes.*.thread_pool.search.rejected,nodes.*.thread_pool.write.rejected,nodes.*.thread_pool.write_coordination.rejected
```

假设同一节点的两次结果整理如下：

| 指标                                      |      `T0` |      `T1` | 窗口增量 `T1 - T0` |
| ----------------------------------------- | --------: | --------: | -----------------: |
| `jvm.uptime_in_millis`                    | 3,600,000 | 3,660,000 |             60,000 |
| `indices.search.query_total`              |     1,000 |     1,120 |                120 |
| `indices.search.query_time_in_millis`     |     4,000 |     4,720 |             720 ms |
| `thread_pool.search.rejected`             |         2 |         5 |                  3 |
| `thread_pool.write.rejected`              |         0 |         1 |                  1 |
| `thread_pool.write_coordination.rejected` |         0 |         2 |                  2 |
| 垃圾回收累计耗时                          |    600 ms |    780 ms |             180 ms |

这 60 秒内可以得出：

```text
搜索查询数             = 1120 - 1000 = 120
搜索阶段累计耗时增量   = 4720 - 4000 = 720 ms
每次搜索阶段平均耗时   = 720 / 120 = 6 ms
新增搜索拒绝数         = 5 - 2 = 3
新增写入拒绝数         = 1 - 0 = 1
新增 Bulk 协调拒绝数   = 2 - 0 = 2
垃圾回收耗时增量       = 780 - 600 = 180 ms
```

这里的 6 ms 是该节点在采样窗口内搜索查询阶段的平均耗时，不是端到端延迟，也不是第 95 或第 99 百分位延迟。它不包含客户端网络、线程池排队和协调节点合并响应等全部开销。

本例中 `jvm.uptime_in_millis` 增加了 60,000，且假定节点日志和监控中没有重启记录，因此累计值可以直接求差。如果第二次采样的运行时间变小，则节点已经重启，许多累计计数也随之重置。此时直接执行 `T1 - T0` 可能得到负数；即使重启后的流量很大而碰巧得到正数，该差值仍然不能代表整个窗口。正确做法是把重启作为时间线事件，将窗口拆成重启前后两段，或使用已经连续保存指标的监控系统。

多节点集群应按节点分别计算，不能先把不同节点的两次结果随意配对。验收记录至少应包含节点名称或 ID、两个采样时间、时区、采样间隔、原始值、差值以及窗口内是否发生重启。

## 3. 在单数据节点集群制造并解释黄色状态

先确认实验集群只有一个承担数据角色的节点：

```http
GET /_cat/nodes?v&h=name,node.role
```

创建一个主分片和一个副本的练习索引：

如果该索引名已被其他实验使用，应换用新的练习索引名，并在后续请求中保持一致；不要直接删除用途不明的同名索引。

```http
PUT /monitoring-c16-yellow
{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 1
  }
}
```

查看索引健康状态和分片明细：

```http
GET /_cluster/health/monitoring-c16-yellow
GET /_cat/shards/monitoring-c16-yellow?v&h=index,shard,prirep,state,unassigned.reason,node
```

预期结果是：

- 主分片 `p` 为 `STARTED`，索引仍可读写。
- 副本 `r` 为 `UNASSIGNED`。
- 索引 `status` 为 `yellow`，不是 `red`。

指定未分配的副本，请求分配解释：

```http
POST /_cluster/allocation/explain?filter_path=index,shard,primary,current_state,unassigned_info.reason,allocate_explanation,node_allocation_decisions.node_name,node_allocation_decisions.node_decision,node_allocation_decisions.deciders
{
  "index": "monitoring-c16-yellow",
  "shard": 0,
  "primary": false
}
```

解释结果应表明副本当前未分配。关键原因是主分片已经位于唯一的数据节点上，而 Elasticsearch 不允许同一分片的主副本位于同一节点；相关分配决策通常可在 `same_shard` 决策器中看到。

因此，本题的结论不是“黄色等于数据已经丢失”，而是“当前主分片可用，但没有副本冗余；如果唯一节点故障，数据将不可用”。生产环境应增加位于合适故障域的数据节点并等待副本分配，而不是仅为消除黄色状态就把副本永久设为 0。

## 4. 区分搜索拒绝、JVM 内存压力和磁盘水位告警

三类问题可能都表现为请求变慢或 HTTP 429，但证据不同：

| 问题           | 主要证据                                                                   | 常用检查                                                                             | 不能仅凭什么下结论                                      |
| -------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------- |
| 搜索线程池拒绝 | `thread_pool.search.rejected` 在故障窗口内增加，错误中出现线程池拒绝信息   | `/_cat/thread_pool/search`、两次 `/_nodes/stats/thread_pool` 采样、`/_tasks`、热线程 | 单个历史累计值大，或只看到 HTTP 429                     |
| JVM 内存压力   | 堆内存长期高位、垃圾回收耗时或停顿增加、熔断触发                           | `/_nodes/stats/jvm,breaker`、节点日志、堆内存时间序列                                | 一次 `heap.percent` 尖峰，或操作系统 `ram.percent` 很高 |
| 磁盘水位       | 节点磁盘超过实际水位、分片因 `disk_threshold` 无法分配或索引出现只读写保护 | `/_cat/allocation`、集群水位设置、分配解释、节点日志                                 | 索引黄色，或一次磁盘使用率读数                          |

可以使用下面的请求收集关键证据：

```http
GET /_cat/thread_pool/search?v&h=node_name,name,active,queue,rejected,completed
GET /_nodes/stats/jvm,breaker,thread_pool
GET /_cat/allocation?v&h=node,disk.percent,disk.avail,disk.total,disk.used,shards
GET /_cluster/settings?include_defaults=true&filter_path=*.cluster.routing.allocation.disk.watermark*
```

判断规则如下：

- 搜索拒绝首先看 `rejected` 在故障窗口内是否新增，并结合 `active`、`queue`、慢查询和任务信息解释为什么线程池来不及处理。
- JVM 内存压力关注趋势以及垃圾回收后的回落情况。`ram.percent` 是整个操作系统的内存使用率，不等于 Elasticsearch 堆内存压力。
- 磁盘水位需要把节点实际磁盘使用率与当前集群水位配置对照。达到洪水水位时，错误通常会明确指出 `read_only_allow_delete` 或 `flood-stage watermark`。
- HTTP 429 只是状态码，线程池拒绝、熔断或磁盘写保护可能产生不同的错误正文；必须读取 `error.type` 和 `error.reason`，不能把所有 429 都归为线程池队列已满。

## 5. 429 排障检查单

### 5.1 固定时间窗口和影响范围

1. 记录开始时间、时区、恢复时间、受影响的接口、索引、租户和请求比例。
2. 保存一份已脱敏的完整 429 响应，特别是 `error.type`、`error.reason` 和失败的具体操作。
3. 关联应用请求 ID、`X-Opaque-Id` 或追踪 ID，并检查故障窗口内的部署、配置和流量变化。

### 5.2 先判断是哪一类 429

- 错误指向 `es_rejected_execution_exception` 或线程池拒绝：进入搜索/写入线程池分支。
- 错误指向熔断器：进入 JVM 堆内存和请求规模分支。
- 错误包含 `flood-stage watermark` 或 `read_only_allow_delete`：进入磁盘水位分支。
- 如果错误来自代理、网关或应用自身限流，不能套用 Elasticsearch 线程池结论，应继续检查产生响应的组件。

### 5.3 收集集群与节点证据

```http
GET /_cluster/health?level=indices
GET /_cat/nodes?v&h=name,node.role,heap.percent,cpu,load_1m,disk.used_percent
GET /_cat/thread_pool/search,write,write_coordination?v&h=node_name,name,active,queue,rejected,completed
GET /_nodes/stats/jvm,fs,indices,thread_pool,breaker
GET /_tasks?detailed=true&actions=indices:data/read/search*,indices:data/write/*
GET /_nodes/hot_threads?threads=3&ignore_idle_threads=true
```

对 `rejected`、`completed`、查询次数和垃圾回收耗时等累计计数至少采样两次并求差。横向比较节点，确认问题是全局过载还是单节点热点。

### 5.4 查找负载来源

- 搜索侧：检查慢查询、前导通配符、脚本、深分页、大型聚合、跨越的索引和分片数量，以及突增的查询并发。
- 写入侧：检查 Bulk 批次大小、并发写入数、摄取管道处理器、刷新频率、段合并和磁盘延迟。
- 数据模型：检查分片是否过多、路由是否形成热点、高基数字段是否引发昂贵聚合，以及 `fielddata` 是否占用大量堆内存。
- 变更侧：对照新版本发布、查询模板变更、索引迁移、节点下线和配置调整时间。

### 5.5 止血但不掩盖根因

1. 客户端对可重试请求采用有上限的指数退避和随机抖动，避免所有请求同时重试。
2. 根据证据临时降低并发、缩小 Bulk 批次或限制已确认的高成本查询。
3. 如果容量确实不足，按架构增加节点或资源，并确认分片能够重新平衡。
4. 如果是磁盘水位，扩充空间或按已批准且有恢复保障的保留策略释放空间；不要只提高水位百分比。

不要把“调大线程池队列”列为第一步。更大的队列不会增加处理能力，只会让更多请求占用内存并等待更久，可能把快速失败变成超时和更严重的内存压力。

### 5.6 验证恢复并形成永久修复

- 确认应用端 429 比例回落，端到端第 95 和第 99 百分位延迟恢复到基线。
- 确认采样窗口内 `rejected` 不再增长，而不是只看累计值仍然大于 0。
- 确认堆内存能在垃圾回收后回落、磁盘低于相应水位、分片恢复稳定。
- 记录直接原因、促成因素、止血动作和永久修复，例如查询改写、批次与并发控制、分片调整、容量扩充或告警完善。

## 验收清单

- 能逐项说明 7 个接口回答的问题，并正确区分快照、当前值和累计计数。
- 能使用两个采样时刻计算搜索次数与拒绝数增量，并在节点重启时停止直接求差。
- 能用分配解释证明单节点黄色状态来自副本不能与主分片同节点，而不是数据已丢失。
- 能根据错误正文和趋势证据区分线程池拒绝、JVM 内存压力与磁盘水位。
- 429 检查单遵循“固定窗口 → 分类 → 收集证据 → 定位负载 → 止血 → 验证与永久修复”，且不把调大队列作为第一步。
