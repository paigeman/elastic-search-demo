# 12｜数据接入、批量操作与摄取管道：练习与验收答案

建议先独立完成练习，再使用本页核对管道定义、模拟结果和重放链路。以下标记为 `http` 的请求都在 Kibana 的开发工具（Dev Tools）中的控制台（Console）执行，并假定已经按照第 12 章“操作环境与实验初始化”创建 `ingestion-products` 索引。

## 1. 创建商品数据规范化管道

创建 `products-normalize-v1` 管道：

```http
PUT /_ingest/pipeline/products-normalize-v1
{
  "description": "normalize product events",
  "processors": [
    {
      "set": {
        "field": "ingested_at",
        "value": "{{{_ingest.timestamp}}}"
      }
    },
    {
      "trim": {
        "field": "name"
      }
    },
    {
      "lowercase": {
        "field": "category"
      }
    },
    {
      "convert": {
        "field": "price",
        "type": "double",
        "on_failure": [
          {
            "set": {
              "field": "ingest_error",
              "value": "invalid price: {{{_ingest.on_failure_message}}}"
            }
          }
        ]
      }
    },
    {
      "remove": {
        "field": "debug_payload",
        "ignore_missing": true
      }
    }
  ]
}
```

五个处理器按数组顺序执行：

1. `set` 使用管道执行时间补充 `ingested_at`。
2. `trim` 去除 `name` 首尾空格。
3. `lowercase` 把 `category` 转成小写。
4. `convert` 把 `price` 从字符串转换成数值；失败时写入 `ingest_error`。
5. `remove` 删除不应进入索引的 `debug_payload`。

可以读取管道，确认它已经创建：

```http
GET /_ingest/pipeline/products-normalize-v1
```

验收时应检查处理器名称、字段和顺序，而不只是管道是否存在。

## 2. 使用 `_simulate` 验证正常与异常输入

一次提交正常和异常两篇文档：

```http
POST /_ingest/pipeline/products-normalize-v1/_simulate?filter_path=docs.doc._source
{
  "docs": [
    {
      "_source": {
        "product_id": "p2001",
        "name": "  Mechanical Keyboard  ",
        "category": "KEYBOARD",
        "price": "399.00",
        "debug_payload": {
          "trace_id": "demo-001"
        }
      }
    },
    {
      "_source": {
        "product_id": "p-bad",
        "name": "Bad Item",
        "category": "TEST",
        "price": "unknown"
      }
    }
  ]
}
```

响应中的 `_source` 应与下面的结构相符。`ingested_at` 的具体时间和 `ingest_error` 的完整错误文本以实际响应为准：

```json
{
  "docs": [
    {
      "doc": {
        "_source": {
          "product_id": "p2001",
          "name": "Mechanical Keyboard",
          "category": "keyboard",
          "price": 399,
          "ingested_at": "实际摄取时间"
        }
      }
    },
    {
      "doc": {
        "_source": {
          "product_id": "p-bad",
          "name": "Bad Item",
          "category": "test",
          "price": "unknown",
          "ingested_at": "实际摄取时间",
          "ingest_error": "invalid price: 实际错误信息"
        }
      }
    }
  ]
}
```

正常文档的验收点：

- `name` 不再包含首尾空格。
- `category` 是小写的 `keyboard`。
- `price` 是不带引号的 JSON 数值，而不是字符串。
- 存在 `ingested_at`。
- 不再存在 `debug_payload`。

异常文档的验收点：

- `category` 仍会正常转换为小写的 `test`。
- `price` 转换失败后存在 `ingest_error`。
- `_simulate` 返回处理结果，但不会把 `p2001` 或 `p-bad` 写入 `ingestion-products`。

`on_failure` 已处理 `convert` 处理器的异常，因此管道可以继续执行后面的处理器。但如果把异常文档真正写入本章的 `ingestion-products`，字符串 `"unknown"` 仍不符合 `price` 的数值映射，索引写入可能被拒绝。

## 3. 设计可重放且不产生重复文档的写入链路

一种符合题意的链路如下：

```text
[消息队列] → [消费者：使用 product_id 生成 _id] → [Bulk API] → [Elasticsearch]
                 ↑                              │
                 │                              ├─ 成功 → 确认处理完成
                 │                              ├─ 暂时性失败 → 等待后重发失败条目
                 │                              │                  │
                 │                              │                  └─ 超过重试上限 ─┐
                 │                              │                                      │
                 │                              └─ 数据本身有误 → 不重试 ─────────────┤
                 │                                                                     ↓
                 └────────────── 排除失败原因后重放 ─────────────────────────────── [DLQ]
                                                                                 - 原始事件
                                                                                 - 错误原因
                                                                                 - 管道版本
                                                                                 - 重放状态
```

图中的“等待后重发失败条目”由消费者程序实现，不是 Elasticsearch 自动完成。消费者读取 Bulk 响应中每个条目的 `status` 和 `error`，只重新发送暂时失败的条目：

- `429`、`503` 或网络超时等暂时性问题，可以在逐步延长等待时间后有限重试。
- 映射冲突、字段格式错误等由数据本身造成的问题，重复发送相同内容仍会失败，应直接进入 DLQ。
- 暂时性错误超过最大重试次数后也进入 DLQ，避免消费者一直卡在同一批数据上。

“排除失败原因”不固定指修复消费者，应根据 DLQ 保存的错误信息处理：

- 原始字段值错误或缺失：修正或补全待重放的数据，同时保留原始事件用于审计。
- 摄取管道规则错误：发布修正后的管道版本，再重放受影响事件。
- 目标索引映射不兼容：修正数据，或创建具有正确映射的新索引。
- 消费者程序存在缺陷：修复并重新部署消费者。
- Elasticsearch 暂时不可用：等待服务恢复即可，不一定需要修改数据或代码。

消费者从商品事件中读取 `product_id`，并把它放到 Bulk 操作行的 `_id` 中：

```ndjson
{"index":{"_id":"p2002"}}
{"product_id":"p2002","name":"4K 显示器","category":"MONITOR","price":"2299.00","available":true}
```

如果同一条商品数据被再次投递，消费者仍生成 `_id` 为 `p2002` 的 `index` 操作。Elasticsearch 会替换同一篇文档，而不是再创建一篇具有自动生成 `_id` 的重复文档：

```text
第一次处理 product_id=p2002 → 写入 _id=p2002
重放时处理 product_id=p2002 → 再次写入 _id=p2002
最终文档数量               → 仍然是 1
```

这里的 `product_id` 适合充当商品当前状态的稳定标识。若系统保存的是每一次变化的独立事件，而不是商品当前状态，则通常应使用唯一的 `event_id` 识别重复事件；两种数据模型不能混用。

稳定 `_id` 只能避免重复文档，不能阻止旧事件最后到达并覆盖新状态。完整实现还应携带业务版本号或更新时间，并拒绝比当前文档更旧的事件。持续失败的事件进入 DLQ 后，修复并重放时仍使用相同的 `_id` 和顺序检查规则。
