# 06｜索引、文档增删改查与批量操作

## 本节目标

- 创建、读取、更新和删除文档。
- 理解 `_id`、`_source`、刷新机制和并发控制。
- 正确使用批量操作接口（Bulk API）并检查每一条结果。

## 1. 创建索引

```http
PUT /products
{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0,
    "refresh_interval": "1s"
  }
}
```

这里的单分片零副本仅适合单节点课程环境。生产分片数要结合数据量、节点数和查询模型决定。

## 2. 写入与读取

指定业务标识，重复执行会覆盖同一标识的文档：

```http
PUT /products/_doc/p1001
{
  "product_id": "p1001",
  "name": "机械键盘 K8",
  "description": "87 键无线机械键盘",
  "category": "keyboard",
  "brand": "KeyWorks",
  "price": 399.0,
  "stock": 25,
  "tags": ["wireless", "hot-swap"],
  "available": true,
  "created_at": "2026-07-01T08:00:00Z"
}

GET /products/_doc/p1001
GET /products/_source/p1001
```

`_source` 保存索引文档时提交的原始 JSON 内容，本身不会被索引，因此不能直接负责字段检索；Elasticsearch 使用倒排索引等数据结构找到文档，再从 `_source` 取回业务数据。两种读取方式的返回内容不同：

- `GET /products/_doc/p1001` 返回 `_index`、`_id`、版本信息以及 `_source`。
- `GET /products/_source/p1001` 只返回文档的 `_source` 内容。

按标识执行 GET 默认是实时读取，不需要等待刷新；搜索则是近实时的，文档刷新后才能被搜索到。只需要部分字段时，可以过滤 `_source`，减少网络传输和客户端反序列化开销：

```http
GET /products/_doc/p1001?_source=product_id,name,price
```

更新、重建索引和部分调试能力依赖 `_source`，不要仅为了节省磁盘空间就随意禁用它。

让 Elasticsearch 自动生成文档标识：

```http
POST /products/_doc
{"name":"匿名配件","price":19.9}
```

业务数据同步通常使用稳定业务主键，便于幂等重放并避免重复。

## 3. 创建、索引和更新操作

只允许首次创建：

```http
PUT /products/_create/p1002
{"product_id":"p1002","name":"人体工学鼠标","price":199.0}
```

部分更新实际是“读取旧文档、合并、重新索引”：

```http
POST /products/_update/p1001
{
  "doc": {"stock": 24},
  "doc_as_upsert": false
}
```

脚本更新：

```http
POST /products/_update/p1001
{
  "script": {
    "source": "ctx._source.stock += params.delta",
    "params": {"delta": -1}
  }
}
```

这里的 `ctx._source` 是更新脚本中可修改的文档内容；脚本完成后，Elasticsearch 会重新索引修改后的文档。脚本应短小且参数化，避免把用户输入拼接到脚本源码中。

## 4. 删除与刷新

```http
DELETE /products/_doc/p1002
POST /products/_refresh
```

仅在测试中需要“写完立刻搜”时使用 `refresh=wait_for`：

```http
PUT /products/_doc/p1002?refresh=wait_for
{"product_id":"p1002","name":"人体工学鼠标","price":199.0}
```

不要让每次生产写入都设置 `refresh=true`，这会产生大量小段。

## 5. 乐观并发控制

GET 响应包含 `_seq_no` 和 `_primary_term`。仅当读取到的版本未发生变化时才更新：

```http
PUT /products/_doc/p1001?if_seq_no=0&if_primary_term=1
{
  "product_id":"p1001",
  "name":"机械键盘 K8",
  "price":389.0,
  "stock":24
}
```

版本过期会返回 409。应用应重新读取并按业务规则合并，而不是无脑覆盖。

## 6. 批量操作接口

```http
POST /_bulk?refresh=wait_for
{"index":{"_index":"products","_id":"p1003"}}
{"product_id":"p1003","name":"显示器支架","category":"office","brand":"Ergo","price":259.0,"stock":12,"available":true,"created_at":"2026-07-02T09:00:00Z"}
{"index":{"_index":"products","_id":"p1004"}}
{"product_id":"p1004","name":"USB-C 扩展坞","category":"accessory","brand":"DockPro","price":499.0,"stock":8,"available":true,"created_at":"2026-07-03T10:00:00Z"}
{"update":{"_index":"products","_id":"p1001"}}
{"doc":{"price":379.0}}
```

批量操作使用以换行分隔的 JSON（NDJSON），每个动作和数据各占一行，最后必须有换行。整体返回 HTTP 200 不代表全部成功，必须检查顶层 `errors` 和每个 `items.*.status/error`。批次应按字节数和处理耗时调优，不能只按文档条数；出现 429 时采用指数退避，并仅重试可以安全重放的失败项。

## 练习与验收

- 创建 5 个商品，完成读取、更新和删除。
- 制造一次 `_create` 冲突并解释 409。
- 用批量操作写入至少 3 条数据，并能指出逐项错误的检查位置。

上一节：[05｜REST API](./05-rest-api-and-dev-tools.md)｜下一节：[07｜映射](./07-mapping-and-field-types.md)
