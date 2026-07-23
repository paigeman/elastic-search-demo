# 12｜数据接入、批量操作与摄取管道

## 本节目标

- 选择适合的接入方式。
- 使用摄取管道（ingest pipeline）清洗、转换和拒绝脏数据。
- 设计可重放、可观测、不会制造重复数据的写入链路。

## 操作环境与实验初始化

本章的 Elasticsearch HTTP 请求都可以在 Kibana 的“开发工具（Dev Tools）→ Console”中执行；第 3 节另外提供了从终端导入文件的 `curl` 写法。为了不依赖前面章节留下的索引状态，本章使用独立的 `ingestion-products` 索引。

下面的初始化请求会删除并重建该实验索引，请勿将索引名替换成需要保留数据的业务索引：

```http
DELETE /ingestion-products?ignore_unavailable=true

PUT /ingestion-products
{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0
  },
  "mappings": {
    "dynamic": "strict",
    "properties": {
      "product_id": {"type": "keyword"},
      "name": {"type": "text"},
      "category": {"type": "keyword"},
      "price": {"type": "scaled_float", "scaling_factor": 100},
      "available": {"type": "boolean"},
      "ingested_at": {"type": "date"},
      "ingest_error": {"type": "keyword"}
    }
  }
}
```

这里显式声明字段类型，是为了验证摄取管道转换后的值能否满足索引映射。例如，原始数据中的 `price` 可以是字符串，但经过管道后必须转换成映射能够接受的数值。

映射中没有声明后面示例使用的 `debug_payload`，这是有意为之：摄取管道会在映射校验和索引写入之前删除该字段，因此最终文档不需要它的映射。如果写入时没有启用管道，`dynamic: "strict"` 会因为遇到未声明的 `debug_payload` 而拒绝文档，这也能帮助发现管道漏用。

## 1. 接入方式选择

这里的“接入”是指把业务系统、数据库、日志或消息队列中的数据，持续、可靠地写入 Elasticsearch，形成可供搜索和分析的文档。接入方式决定了数据由谁采集、在哪里转换，以及失败后如何重试和恢复；它不是简单地调用一次写入接口。

之所以需要专门设计接入链路，是因为真实数据通常存在格式不统一、重复、乱序、脏数据和流量波动等问题。合适的接入方式可以在写入前完成清洗与转换，并提供缓冲、重试、幂等、监控和回放能力，避免数据丢失、重复或拖垮 Elasticsearch。下面这些方式并不互斥，例如可以使用 Elastic Agent 采集日志、Kafka 缓冲流量，再由消费者批量写入并调用摄取管道完成轻量转换。

| 方式 | 适用场景 | 注意事项 |
| --- | --- | --- |
| 官方客户端与批量操作 | 应用或同步服务直接写入 | 自己负责重试、幂等、背压和监控 |
| 摄取管道（Ingest Pipeline） | 节点内轻量字段转换 | 重型解析会占用摄取节点的处理器资源 |
| Elastic Agent / Beats | 日志、指标和集成采集 | 使用数据流和集成模板 |
| Logstash | 多输入、复杂转换、缓冲与路由 | 增加独立组件和运维成本 |
| Kafka 与消费者 | 高吞吐、解耦、可回放 | 管理消费进度（消费位点）、重复写入和积压 |
| 连接器/变更数据捕获（CDC） | 数据库同步 | 验证删除、更新顺序和结构变化语义 |

## 2. 创建摄取管道

摄取管道（Ingest Pipeline）是运行在 Elasticsearch 节点上的一组预处理步骤。客户端把原始文档写入 Elasticsearch 时，通过 `pipeline` 参数指定管道；文档会先按顺序经过管道中的处理器（processor），完成字段补充、格式规范、类型转换或字段删除，然后才进入索引。

它适合处理靠近写入端的轻量、确定性转换，例如统一大小写、转换日期和数值类型、删除无用字段。它不负责从外部系统采集数据，也不适合耗时较长的复杂计算，因此不能完全替代 Elastic Agent、Logstash、Kafka 消费者等接入组件。

下面的管道用于规范商品数据，各处理器会依次执行：

- `set`：记录文档进入管道的时间。
- `trim`：去掉商品名称首尾的空格。
- `lowercase`：把类目统一为小写。
- `convert`：把字符串形式的价格转换为浮点数；转换失败时记录 `ingest_error`。
- `remove`：删除不需要写入索引的调试字段。

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

创建管道后先使用 `_simulate` 验证转换效果。模拟只返回处理结果，不会把文档写入索引：

```http
POST /_ingest/pipeline/products-normalize-v1/_simulate
{
  "docs": [
    {"_source": {"name":"  Mechanical Keyboard  ","category":"KEYBOARD","price":"399.00","debug_payload":{"trace_id":"demo-001"}}},
    {"_source": {"name":"Bad Item","category":"TEST","price":"unknown"}}
  ]
}
```

第一条文档处理后，`name` 会变成 `Mechanical Keyboard`，`category` 会变成 `keyboard`，`price` 会从字符串 `"399.00"` 变成数值 `399`，新增 `ingested_at`，并且不再包含 `debug_payload`。这里的重点是 JSON 值不再带引号；数值序列化时不保证保留 `.0` 或末尾的零。第二条文档的价格无法转换，管道会保留错误信息到 `ingest_error`，方便后续识别和处理脏数据。

`on_failure` 只处理管道步骤的失败，不代表文档一定能够成功写入。例如索引映射要求 `price` 为数值时，值为 `unknown` 的文档之后仍可能被索引拒绝；生产环境通常还需要决定是拒绝此类文档，还是将其送入死信队列。

确认模拟结果符合预期后，在写入请求中通过 `pipeline` 参数启用该管道：

```http
PUT /ingestion-products/_doc/p2001?pipeline=products-normalize-v1
{"product_id":"p2001","name":"  Mechanical Keyboard  ","category":"KEYBOARD","price":"399.00","debug_payload":{"trace_id":"demo-001"}}
```

本节处理的是新写入的文档。摄取管道也可以配合 `_reindex` 重处理 Elasticsearch 中已有的历史文档，但这属于索引重建与迁移，不是从外部系统接入数据；相关流程参见[第 07 课](./07-mapping-and-field-types.md)的映射迁移说明和[第 14 课](./14-index-management.md)的别名切换。

## 3. 使用 Bulk API 批量写入

Bulk API 的请求体不是一个 JSON 数组，而是换行分隔的 JSON（Newline Delimited JSON，NDJSON）。以本节的前两行为例：

```ndjson
{"index":{"_id":"p2002"}}
{"product_id":"p2002","name":"4K 显示器","category":"MONITOR","price":"2299.00","available":true}
```

- 第一行是操作行：`index` 是操作名称，`_id` 是操作使用的元数据。目标 `_id` 不存在时创建文档，已经存在时则替换原文档。
- 第二行是文档行：它是实际写入 Elasticsearch 的商品文档，不是 `create` 操作。

`create` 是与 `index` 并列的另一种操作名称。如果希望目标 `_id` 已存在时直接报错，而不是覆盖原文档，可以把操作行改成下面这样；它的下一行仍然是要写入的文档：

```ndjson
{"create":{"_id":"p2002"}}
{"product_id":"p2002","name":"4K 显示器","category":"MONITOR","price":"2299.00","available":true}
```

因此，`index` 和 `create` 都由“操作行 + 文档行”组成。Bulk 还支持 `delete` 和 `update`：`delete` 只需要操作行，`update` 的下一行则是更新参数。按照 Bulk 协议，请求体在最后一个 JSON 对象之后还应有一个换行符。

在 Kibana Console 中，即使没有在最后一行手动按回车，请求也可能正常执行，因为 Console 会在发送时整理请求内容，实际传输的请求体可能已经包含结尾换行。这个细节在界面中通常不可见；自己生成 NDJSON 文件或直接构造 HTTP 请求体时，不要依赖客户端自动补齐。

NDJSON 与 JSON Lines（常简称 JSONL）通常指同一种“一行一个 JSON 值”的文本格式。这里使用 `.ndjson` 扩展名，是因为 Elasticsearch 官方将 Bulk 协议称为 NDJSON，并使用 `application/x-ndjson` 媒体类型；文件改名为 `.jsonl` 并不会改变内容，但 `.ndjson` 能更直接地表明它遵循 Elasticsearch 的 Bulk 请求格式。还要注意，这个文件不是单纯的一行一篇文档，而是交替包含操作行和文档行。

### 1. 在 Kibana Console 中执行

下面的请求可以直接粘贴到 Kibana Console，不需要先创建本地文件：

```http
POST /ingestion-products/_bulk?pipeline=products-normalize-v1&refresh=wait_for&filter_path=errors,items.*.status
{"index":{"_id":"p2002"}}
{"product_id":"p2002","name":"4K 显示器","category":"MONITOR","price":"2299.00","available":true}
{"index":{"_id":"p2003"}}
{"product_id":"p2003","name":"升降桌","category":"OFFICE","price":"1899.00","available":true}
```

`pipeline` 参数会让本批次中的两篇文档都经过 `products-normalize-v1`。首次写入时，响应中的 `errors` 应为 `false`，两条 `index.status` 应为 `201`；再次执行会覆盖相同 `_id` 的文档，状态通常为 `200`。

### 2. 在终端中导入文件

需要从程序生成的文件或大量数据导入时，可以把同样的请求体保存为 `ingestion-products.ndjson`：

```ndjson
{"index":{"_id":"p2002"}}
{"product_id":"p2002","name":"4K 显示器","category":"MONITOR","price":"2299.00","available":true}
{"index":{"_id":"p2003"}}
{"product_id":"p2003","name":"升降桌","category":"OFFICE","price":"1899.00","available":true}
```

```bash
curl --cacert "$ES_CA" -u "elastic:$ELASTIC_PASSWORD" \
  -H 'Content-Type: application/x-ndjson' \
  -X POST "$ES_URL/ingestion-products/_bulk?pipeline=products-normalize-v1" \
  --data-binary @ingestion-products.ndjson
```

`ingestion-products` 已写在请求路径中，所以操作行不必再重复 `_index`。文件导入时必须使用 `--data-binary` 保留换行，并应确认文件末尾也有换行符。生产消费者只重试失败且具备幂等性的条目；为每一批记录耗时、成功和失败数量、状态码、积压情况以及最大重试次数。

## 4. 幂等与顺序

幂等是指同一条数据被重复处理多次，最终结果仍与处理一次相同；重放则是把历史数据或失败消息重新发送和处理。因此，幂等不等于重放，而是安全重放的重要前提。例如使用稳定的业务主键作为 `_id` 时，重复写入会覆盖同一文档，而不会产生重复文档；但“库存数量加一”这类累加操作不是幂等的，每次重放都会再次修改结果。

实际链路中很容易出现重复投递：消费者已经成功写入 Elasticsearch，但还没来得及向消息队列确认“这条消息已处理完成”就发生重启，消息队列随后可能再次发送同一条消息。此时应从业务主键得到稳定的 `_id`，并使用 `index` 这类覆盖写入，让重复投递落到同一篇文档。对于库存累加等非幂等操作，则需要事件去重或改为写入计算后的库存绝对值。

解决重复之后，还要处理重放造成的乱序。假设商品先后产生“价格更新为 399”和“价格更新为 359”两个事件，如果较旧的事件最后才被重放，单靠稳定 `_id` 仍会让旧价格覆盖新价格。通常需要同时采用以下措施：

- 让同一业务实体的事件进入同一消息分区，尽量维持消费顺序。
- 在事件中携带递增版本号或业务更新时间，写入时拒绝比当前文档更旧的事件。
- 事先定义版本冲突的处理方式，例如忽略旧事件、记录告警，或转入待核查队列。

最后，重放链路还必须保证数据完整并能处理失败：

- 删除也要表示成可保存、可重放的事件。否则重建索引时只能恢复新增和修改，已经删除的数据会重新出现。
- 暂时性错误可以重试；格式错误、字段缺失等持续失败的数据应写入死信队列（DLQ），避免阻塞整个批次。
- DLQ 至少保留原始事件、错误原因、管道版本和重放状态。修复数据或管道后，重新投递时仍要遵守相同的幂等和顺序规则。

因此，一条可安全重放的写入链路需要同时解决四件事：用稳定 `_id` 避免重复文档，用版本信息阻止旧状态覆盖新状态，把删除纳入事件流，并把无法立即处理的数据留在 DLQ 中等待修复。

## 练习与验收

- 编写一条摄取管道：补充 `ingested_at`，去除 `name` 首尾空格，把 `category` 从 `KEYBOARD` 转成小写 `keyboard`，并把字符串价格 `"399.00"` 转成数值。
- 调用 `POST /_ingest/pipeline/products-normalize-v1/_simulate` 测试两篇文档：正常文档使用价格 `"399.00"`，确认名称、类目和价格均完成转换且 `debug_payload` 被删除；异常文档使用价格 `"unknown"`，确认结果中出现 `ingest_error`。
- 画出“消息队列 → 消费者 → 批量写入 → 死信队列 → 重放”的链路，并在消费者到 Elasticsearch 的写入步骤标明：使用商品的 `product_id` 作为文档 `_id`，让同一商品被重复投递时覆盖同一篇文档，而不是产生重复文档。

上一节：[11｜聚合](./11-aggregations.md)｜下一节：[13｜应用客户端](./13-application-clients.md)
