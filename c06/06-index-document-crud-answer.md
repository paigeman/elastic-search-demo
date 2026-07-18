# 06｜索引、文档增删改查与批量操作：练习与验收答案

建议先独立完成练习，再使用本页核对请求、响应和判断过程。以下标记为 `http` 的请求都在 Kibana 的开发工具（Dev Tools）中的控制台（Console）执行，并假定课程正文已经创建 `products` 索引。

## 1. 创建 5 个商品并完成读取、更新和删除

使用稳定的商品编号作为 Elasticsearch 文档 `_id`，分别创建 5 个商品：

```http
PUT /products/_doc/p2001
{"product_id":"p2001","name":"无线鼠标 M1","category":"mouse","brand":"KeyWorks","price":129.0,"stock":10,"available":true}

PUT /products/_doc/p2002
{"product_id":"p2002","name":"机械键盘 K2","category":"keyboard","brand":"KeyWorks","price":299.0,"stock":8,"available":true}

PUT /products/_doc/p2003
{"product_id":"p2003","name":"27 英寸显示器","category":"monitor","brand":"ViewPro","price":1499.0,"stock":5,"available":true}

PUT /products/_doc/p2004
{"product_id":"p2004","name":"USB-C 扩展坞","category":"accessory","brand":"DockPro","price":399.0,"stock":12,"available":true}

PUT /products/_doc/p2005
{"product_id":"p2005","name":"人体工学椅","category":"office","brand":"Ergo","price":1899.0,"stock":3,"available":true}
```

首次写入新 `_id` 时，响应中的 `result` 应为 `created`。如果重复执行相同的 PUT，请求会重新索引同一文档，`result` 会变为 `updated`，而不会创建重复 `_id`。

读取 `p2001` 的文档元数据和完整 `_source`：

```http
GET /products/_doc/p2001
```

只读取业务数据：

```http
GET /products/_source/p2001
```

部分更新 `p2001` 的库存，不覆盖其他 `_source` 字段：

```http
POST /products/_update/p2001
{
  "doc": {"stock": 9}
}
```

再次读取并确认 `stock` 已变为 `9`：

```http
GET /products/_doc/p2001?_source=product_id,name,stock
```

删除 `p2005`：

```http
DELETE /products/_doc/p2005
```

删除成功时，响应中的 `result` 应为 `deleted`。再次按 `_id` 读取：

```http
GET /products/_doc/p2005
```

应返回 HTTP 404，并包含：

```json
{
  "_index": "products",
  "_id": "p2005",
  "found": false
}
```

按 `_id` 执行 GET 是实时读取，因此不需要手动刷新就能看到上述写入、更新和删除的最新结果。如果改用 `_search` 验证，则需要等待自动刷新，或在确有写后立即搜索的需求时使用 `refresh=wait_for`。

## 2. 制造 `_create` 冲突并解释 HTTP 409

第一次使用 `_create` 写入一个新 `_id`：

```http
PUT /products/_create/p2099
{"product_id":"p2099","name":"冲突测试商品","price":9.9,"stock":1,"available":true}
```

首次执行应成功，响应中的 `result` 为 `created`。不删除该文档，直接再次执行同一个请求：

```http
PUT /products/_create/p2099
{"product_id":"p2099","name":"冲突测试商品","price":9.9,"stock":1,"available":true}
```

第二次执行会返回 HTTP 409，错误类型类似：

```json
{
  "error": {
    "type": "version_conflict_engine_exception",
    "reason": "version conflict, document already exists"
  },
  "status": 409
}
```

`_create` 表示仅当指定 `_id` 不存在时才创建文档。第二次请求中的 `p2099` 已经存在，因此 Elasticsearch 拒绝覆盖并返回冲突。它只检查文档 `_id`，不会检查商品名称、`product_id` 等其他业务字段是否重复。

如果业务希望相同 `_id` 的后一次数据覆盖前一次数据，应使用：

```http
PUT /products/_doc/p2099
{"product_id":"p2099","name":"允许覆盖的测试商品","price":19.9,"stock":2,"available":true}
```

如果业务希望重复 `_id` 被视为错误，则继续使用 `_create` 或等价的 `op_type=create`。

## 3. 使用 Bulk API 写入 3 条数据并检查逐项结果

一次批量写入 3 个商品：

```http
POST /_bulk?refresh=wait_for
{"index":{"_index":"products","_id":"p3001"}}
{"product_id":"p3001","name":"笔记本支架","category":"office","brand":"Ergo","price":159.0,"stock":20,"available":true}
{"index":{"_index":"products","_id":"p3002"}}
{"product_id":"p3002","name":"桌面麦克风","category":"audio","brand":"SoundPro","price":329.0,"stock":7,"available":true}
{"index":{"_index":"products","_id":"p3003"}}
{"product_id":"p3003","name":"1080P 摄像头","category":"camera","brand":"ViewPro","price":269.0,"stock":11,"available":true}
```

首次执行时，响应顶层的 `errors` 应为 `false`，每个结果位于 `items` 数组中。为突出检查位置，下面省略了版本号和分片等字段：

```json
{
  "errors": false,
  "items": [
    {
      "index": {
        "_index": "products",
        "_id": "p3001",
        "status": 201,
        "result": "created"
      }
    },
    {
      "index": {
        "_index": "products",
        "_id": "p3002",
        "status": 201,
        "result": "created"
      }
    },
    {
      "index": {
        "_index": "products",
        "_id": "p3003",
        "status": 201,
        "result": "created"
      }
    }
  ]
}
```

如果重复执行这组 `index` 动作，已有文档会被完整覆盖，对应条目的状态通常变为 `200`，`result` 变为 `updated`。

为了观察逐项失败，先保留已经存在的 `p3001`，再执行以下批量请求：

```http
POST /_bulk?filter_path=errors,items.*._id,items.*.status,items.*.error
{"create":{"_index":"products","_id":"p3001"}}
{"product_id":"p3001","name":"重复创建测试"}
{"update":{"_index":"products","_id":"course_missing_product"}}
{"doc":{"stock":1}}
```

预期响应类似：

```json
{
  "errors": true,
  "items": [
    {
      "create": {
        "_id": "p3001",
        "status": 409,
        "error": {
          "type": "version_conflict_engine_exception",
          "reason": "version conflict, document already exists"
        }
      }
    },
    {
      "update": {
        "_id": "course_missing_product",
        "status": 404,
        "error": {
          "type": "document_missing_exception",
          "reason": "document missing"
        }
      }
    }
  ]
}
```

验收时不能只看 Bulk 请求整体是否返回 HTTP 200，而应依次检查：

1. 顶层 `errors` 是否为 `true`。
2. `items` 数组中每个动作的 `status`。
3. 状态不是 2xx 的条目中是否存在 `error.type` 和 `error.reason`。
4. 重试时只选择可以安全重放的失败项，不能无条件重发整个批次。
