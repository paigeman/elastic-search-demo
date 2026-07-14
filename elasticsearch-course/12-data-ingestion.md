# 12｜数据接入、批量操作与摄取管道

## 本节目标

- 选择适合的接入方式。
- 使用摄取管道（ingest pipeline）清洗、转换和拒绝脏数据。
- 设计可重放、可观测、不会制造重复数据的写入链路。

## 1. 接入方式选择

| 方式 | 适用场景 | 注意事项 |
| --- | --- | --- |
| 官方客户端与批量操作 | 应用或同步服务直接写入 | 自己负责重试、幂等、背压和监控 |
| 摄取管道（Ingest Pipeline） | 节点内轻量字段转换 | 重型解析会占用摄取节点的处理器资源 |
| Elastic Agent / Beats | 日志、指标和集成采集 | 使用数据流和集成模板 |
| Logstash | 多输入、复杂转换、缓冲与路由 | 增加独立组件和运维成本 |
| Kafka 与消费者 | 高吞吐、解耦、可回放 | 管理消费位点、重复写入和积压 |
| 连接器/变更数据捕获（CDC） | 数据库同步 | 验证删除、更新顺序和结构变化语义 |

## 2. 创建摄取管道

```http
PUT /_ingest/pipeline/products-normalize-v1
{
  "description": "normalize product events",
  "processors": [
    {"set": {"field": "ingested_at", "value": "{{{_ingest.timestamp}}}"}},
    {"trim": {"field": "name"}},
    {"lowercase": {"field": "category"}},
    {
      "convert": {
        "field": "price",
        "type": "double",
        "on_failure": [
          {"set": {"field": "ingest_error", "value": "invalid price: {{{_ingest.on_failure_message}}}"}}
        ]
      }
    },
    {"remove": {"field": "debug_payload", "ignore_missing": true}}
  ]
}
```

先模拟，不写数据：

```http
POST /_ingest/pipeline/products-normalize-v1/_simulate
{
  "docs": [
    {"_source": {"name":"  Mechanical Keyboard  ","category":"KEYBOARD","price":"399.00"}},
    {"_source": {"name":"Bad Item","category":"TEST","price":"unknown"}}
  ]
}
```

确认结果后写入：

```http
PUT /products/_doc/p2001?pipeline=products-normalize-v1
{"product_id":"p2001","name":"  Mechanical Keyboard  ","category":"KEYBOARD","price":"399.00"}
```

## 3. 使用批量文件导入

`products.ndjson` 内容示意：

```ndjson
{"index":{"_index":"products","_id":"p2002"}}
{"product_id":"p2002","name":"4K 显示器","category":"MONITOR","price":"2299.00","available":true}
{"index":{"_index":"products","_id":"p2003"}}
{"product_id":"p2003","name":"升降桌","category":"OFFICE","price":"1899.00","available":true}
```

```bash
curl --cacert "$ES_CA" -u "elastic:$ELASTIC_PASSWORD" \
  -H 'Content-Type: application/x-ndjson' \
  -X POST "$ES_URL/_bulk?pipeline=products-normalize-v1" \
  --data-binary @products.ndjson
```

必须使用 `--data-binary` 保留换行。生产消费者只重试失败且具备幂等性的条目；为每一批记录耗时、成功和失败数量、状态码、积压情况以及最大重试次数。

## 4. 幂等与顺序

- `_id` 使用稳定业务主键，重复投递变成覆盖而非新增重复文档。
- 同一实体的事件应尽量进入同一消息分区，保证顺序。
- 用外部版本或业务更新时间防止旧事件覆盖新状态；先定义冲突处理语义。
- 删除事件也必须可回放，不能只同步新增和修改。
- 将无法处理的数据写入死信队列（DLQ），保留原始事件、错误原因、管道版本和重放状态。

## 5. 重新索引与迁移

```http
POST /_reindex?wait_for_completion=false
{
  "source": {"index": "products-v1", "query": {"match_all": {}}},
  "dest": {"index": "products-v2", "pipeline": "products-normalize-v1"}
}
```

异步响应会返回任务标识：

```http
GET /_tasks/<task_id>
```

重新索引不会自动复制设置、映射或模板，因此要先创建目标索引。线上迁移还要处理迁移期间的增量写入。

## 练习与验收

- 编写一条摄取管道：补充摄取时间、规范类目、转换价格。
- 使用模拟接口覆盖正常与异常输入。
- 画出“消息队列 → 消费者 → 批量写入 → 死信队列 → 重放”的链路，并注明幂等键。

上一节：[11｜聚合](./11-aggregations.md)｜下一节：[13｜应用客户端](./13-application-clients.md)
