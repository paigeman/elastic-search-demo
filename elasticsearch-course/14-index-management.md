# 14｜分片、副本、模板、别名与生命周期

## 本节目标

- 为时间序列和业务索引建立可管理结构。
- 使用组件模板、索引模板、别名和数据流。
- 理解滚动更新、索引生命周期管理（ILM）、数据流生命周期与分片规划。

## 1. 分片规划

主分片数在索引创建后不能直接修改，只能拆分、收缩或重新索引。规划时应考虑：

- 单索引预计数据量、保留周期和增长速度。
- 节点数量、故障域、并行查询与恢复时间。
- 单个分片的文档量、磁盘大小、段合并与查询延迟。

不存在适用于所有场景的“每分片固定大小”。日志场景常从数十 GB/分片开始压测，商品小索引可能一个主分片就足够。先用真实数据和查询基准验证。

副本可动态调整：

```http
PUT /products-v1/_settings
{"index.number_of_replicas": 1}
```

## 2. 组件模板与索引模板

```http
PUT /_component_template/products-mappings-v1
{
  "template": {
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "product_id": {"type":"keyword"},
        "name": {"type":"text","fields":{"keyword":{"type":"keyword"}}},
        "price": {"type":"scaled_float","scaling_factor":100},
        "created_at": {"type":"date"}
      }
    }
  },
  "_meta": {"owner":"search-team","version":1}
}

PUT /_component_template/products-settings-v1
{
  "template": {
    "settings": {"number_of_shards":1,"number_of_replicas":1}
  }
}

PUT /_index_template/products-template-v1
{
  "index_patterns": ["products-v*"],
  "priority": 200,
  "composed_of": ["products-settings-v1","products-mappings-v1"],
  "_meta": {"description":"managed product indices"}
}
```

模板只影响新创建的索引，不会自动修改已有索引。上线前使用索引模拟接口检查模板合并结果与优先级冲突。

## 3. 别名与零停机切换

```http
POST /_aliases
{
  "actions": [
    {"remove": {"index":"products-v1","alias":"products-read"}},
    {"add": {"index":"products-v2","alias":"products-read"}}
  ]
}
```

同一个 `_aliases` 请求会以原子方式执行。应用只访问 `products-read`，迁移时无需修改应用配置。写入别名必须保证只有一个写入索引：

```http
POST /_aliases
{
  "actions": [
    {"add":{"index":"products-v2","alias":"products-write","is_write_index":true}}
  ]
}
```

## 4. 数据流与生命周期

日志、指标、事件等只追加的时间序列数据应优先考虑数据流。数据流由多个隐藏的后备索引组成，拥有稳定名称并支持滚动更新。文档必须包含 `@timestamp` 字段。

业务主数据频繁按标识更新时，普通索引与别名的组合通常更直观。

生命周期常见阶段：

- 热阶段（hot）：活跃写入与查询，使用高性能节点。
- 温阶段（warm）：只读或很少写入，降低副本数量或迁移到较低成本层。
- 冷冻阶段（cold/frozen）：低频查询，依赖快照能力降低本地存储需求。
- 删除阶段（delete）：达到保留期后自动删除。

索引生命周期管理策略示意：

```http
PUT /_ilm/policy/app-logs-30d
{
  "policy": {
    "phases": {
      "hot": {"actions":{"rollover":{"max_primary_shard_size":"30gb","max_age":"1d"}}},
      "warm": {"min_age":"2d","actions":{"forcemerge":{"max_num_segments":1}}},
      "delete": {"min_age":"30d","actions":{"delete":{}}}
    }
  }
}
```

策略需要与数据层、模板、滚动更新别名或数据流正确关联。不要在繁忙时段对仍在写入的索引执行强制合并。

## 5. 防止失控

- 为租户创建独立索引前，计算索引与分片总数；小租户通常共享索引并按租户字段过滤。
- 管理索引模板的版本与负责人。
- 定期检查空索引、小分片、未分配分片和长期不删除的数据。
- 删除前确认快照、保留策略与合规要求。

## 练习与验收

- 创建组件模板和索引模板，并用它们创建 `products-v3`。
- 通过别名在两个索引间原子切换并验证回滚。
- 判断商品主数据与应用日志分别应使用普通索引还是数据流。

上一节：[13｜应用客户端](./13-application-clients.md)｜下一节：[15｜安全](./15-security.md)
