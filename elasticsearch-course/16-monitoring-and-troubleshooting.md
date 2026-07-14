# 16｜监控与故障排查

## 本节目标

- 建立从现象到根因的排障路径。
- 使用集群健康、分配解释、节点统计、任务和日志等接口。
- 处理黄色或红色状态、磁盘水位、慢查询、429 响应与 Java 虚拟机压力。

## 1. 先收集证据

```http
GET /_cluster/health?level=indices
GET /_cat/nodes?v&h=name,roles,heap.percent,ram.percent,cpu,load_1m,disk.used_percent
GET /_cat/indices?v&s=health,index
GET /_cat/shards?v&s=state,index
GET /_nodes/stats/jvm,fs,os,process,indices,thread_pool
GET /_cluster/pending_tasks
GET /_tasks?detailed=true&actions=*
```

记录时间窗口、受影响请求、部署/配置变更、节点日志和趋势。单个瞬时数值没有基线时容易误判。

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

常见原因包括：单节点无处放置副本、节点离线、磁盘达到水位、分配过滤条件与数据层不匹配、达到分片上限或正在恢复。不要看到红色状态就立刻强制分配陈旧主分片；该操作可能导致数据丢失，应先确认快照、节点数据和恢复路径。

## 3. 磁盘水位

磁盘达到水位会限制分片分配，严重时索引可能进入只读保护。处理顺序：

1. 确认增长最快的索引和节点。
2. 临时止血：扩盘/增节点、按已批准的保留策略清理有快照的数据。
3. 等分片重新平衡并确认磁盘回落。
4. 如果写保护未自动解除，再按当前版本文档检查并解除写入阻止状态。
5. 修正 ILM/保留期、分片和容量告警。

不要直接删除未知索引，也不要仅提高水位百分比掩盖容量不足。

## 4. 429 与线程池拒绝

```http
GET /_cat/thread_pool/search,write?v&h=node_name,name,active,queue,rejected,completed
GET /_nodes/hot_threads?threads=3&ignore_idle_threads=true
```

检查流量突增、批量写入批次、慢查询、聚合桶、分片数、垃圾回收和磁盘延迟。客户端退避是保护措施，不是根因修复。不要盲目增大队列，队列只会把失败变成更高延迟和更多内存占用。

## 5. Java 虚拟机与熔断

关注堆内存使用趋势、垃圾回收暂停、老年代和熔断器。堆内存使用率过高通常由高基数聚合、过多分片或字段、巨大请求或响应、字段数据以及索引缓冲区压力引起。堆内存长期处于高位且垃圾回收后不回落时，需要调查对象来源，不能只是增加 Java 虚拟机内存。

## 6. 慢查询

- 从应用端确认端到端第 95 和第 99 百分位延迟及超时情况，不能只看 `took`。
- 使用慢日志进行受控采样，避免阈值过低而产生日志风暴。
- 使用分析接口（Profile API）在非高峰或测试环境分析有代表性的单条查询；该接口本身有明显开销。
- 检查查询是否跨越过多分片，或包含深分页、脚本、前导通配符、嵌套查询或大型聚合。
- 对照映射、分析器和真实查询的命中分布。

## 7. 标准事件记录

每次事故至少记录：开始/恢复时间、用户影响、检测方式、时间线、直接原因、促成因素、止血动作、永久修复、责任人与期限。不要把“重启后好了”当根因。

## 练习与验收

- 在单节点设置一个副本制造黄色状态，用分配解释接口说明原因。
- 能区分搜索请求被拒绝、Java 虚拟机内存使用率过高和磁盘水位告警。
- 写一份 429 排障检查单，不把“调大队列”列为第一步。

上一节：[15｜安全](./15-security.md)｜下一节：[17｜备份与升级](./17-backup-restore-upgrade.md)
