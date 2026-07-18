# 06｜索引、文档增删改查与批量操作

## 本节目标

- 创建、读取、更新和删除文档。
- 理解 `_id`、`_source`、刷新机制和并发控制。
- 正确使用批量操作接口（Bulk API）并检查每一条结果。

## 操作环境

本节所有标记为 `http` 的请求示例，除非另有说明，都在 Kibana 的开发工具（Dev Tools）中的控制台（Console）执行，而不是直接粘贴到宿主机的 Shell。先打开 `http://localhost:5601` 并登录 Kibana，再进入“开发工具”页面运行请求。如果希望改用 curl，应按照第 05 课的方法转换请求，并提供当前 Elasticsearch 集群的地址、CA 证书和用户凭据。

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

使用业务系统中的稳定商品编号 `p1001` 作为 Elasticsearch 文档的 `_id`：

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

请求路径 `/products/_doc/p1001` 末尾的 `p1001` 是 Elasticsearch 文档的 `_id`；请求体中的 `product_id` 则是保存在 `_source` 中的业务字段。对同一个 `_id` 重复执行 PUT 会重新索引该文档，并用本次请求体替换原有的完整 `_source`，因此它不是局部更新；局部修改字段应使用后文的 `_update` API。使用稳定的业务主键作为 `_id`，便于幂等重放并避免重复文档。

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

`_create` 和 `_doc` 只有在指定 `_id` 尚不存在时效果相同，都会创建文档；当 `_id` 已存在时，两者行为不同：

| 请求                          | `_id` 不存在 | `_id` 已存在                             |
| ----------------------------- | ------------ | ---------------------------------------- |
| `PUT /products/_doc/p1002`    | 创建文档     | 用本次请求体重新索引并覆盖完整 `_source` |
| `PUT /products/_create/p1002` | 创建文档     | 拒绝覆盖并返回 HTTP 409                  |

`PUT /products/_create/p1002` 等价于 `PUT /products/_doc/p1002?op_type=create`，适合将重复 `_id` 视为错误并防止意外覆盖。这里检查的只是 Elasticsearch 文档 `_id` 是否已经存在，不会检查 `product_id`、商品名称等其他业务字段是否重复。

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
```

写入、更新或删除请求成功，只表示 Elasticsearch 已经接受并处理了这次变更，不一定表示变更已经能被搜索请求看见。按 `_id` 执行 GET 是实时读取，可以立即看到最新结果；`_search` 只能搜索最近一次刷新后已经打开的 Lucene 段，因此具有近实时特性。本节创建索引时把 `refresh_interval` 设置为 `1s`，Elasticsearch 会按该间隔自动刷新。

“写完立即搜”是指写入请求返回后，下一条请求马上使用 `_search` 查找刚写入的文档。例如：

```http
PUT /products/_doc/p1002?refresh=wait_for
{"product_id":"p1002","name":"人体工学鼠标","price":199.0}

POST /products/_search
{
  "query": {
    "ids": {"values": ["p1002"]}
  }
}
```

这里的 `refresh=wait_for` 不会强制立即刷新，而是让写入请求等待下一次刷新完成后再返回。因此，紧接着执行的搜索能够找到 `p1002`。

常见刷新方式如下：

| 方式                                  | 行为                                             | 适用场景                         |
| ------------------------------------- | ------------------------------------------------ | -------------------------------- |
| 省略 `refresh` 或使用 `refresh=false` | 写入完成后立即返回，不等待搜索可见               | 默认选择，适合大多数生产写入     |
| `refresh=wait_for`                    | 等待下一次刷新使本次变更可被搜索后再返回         | 测试或确实需要写后立刻搜索的流程 |
| `refresh=true`                        | 写入后立即强制刷新相关分片                       | 会增加开销，应谨慎使用           |
| `POST /products/_refresh`             | 立即刷新整个 `products` 索引，并在刷新完成后返回 | 临时调试或测试多个写入结果       |

例如，手动让此前的写入、更新和删除反映到搜索结果中：

```http
POST /products/_refresh
```

每个 Elasticsearch 分片底层都是一个 Lucene 索引，由多个不可修改的段（segment）组成。刷新会把当前积累的写入生成新段并开放给搜索，但不会重写已有段。如果写入很少的数据就执行一次 `refresh=true`，每次刷新都可能产生只包含少量文档的小段；段越多，搜索需要查询并汇总的段越多，文件、元数据和缓存开销也越大，后台还需要消耗 CPU、磁盘 I/O 和临时空间进行段合并。

新段通常只保存最近的变更，并不是旧段的完整副本，因此刷新后不能直接删除旧段。例如，旧段 `S1` 包含商品 A、B、C，更新商品 B 时会把 B 的新版本写入新段 `S2`，同时把 `S1` 中的旧版本标记为已删除：

```text
刷新后：S1 = A、B（旧版本，已标记删除）、C
        S2 = B（新版本）

合并后：S3 = A、B（新版本）、C
```

此时直接删除 `S1` 会同时丢失仍然有效的 A 和 C。Lucene 会在后台合并段，把有效文档复制到新段并丢弃已删除或过期版本；确认新段可用且没有查询继续引用旧段后，才会安全删除旧段。因此，更新或删除文档后，旧版本占用的磁盘空间通常要等段合并后才会释放。

生产环境通常依赖自动刷新，避免频繁强制刷新产生大量小段。刷新只控制变更何时对搜索可见，不等同于段合并、备份或数据持久化。

## 5. 乐观并发控制

乐观并发控制是“先读取版本，再带着该版本执行条件写入”的两步流程。第一步读取文档：

```http
GET /products/_doc/p1001
```

响应中会包含 `_seq_no` 和 `_primary_term`。为突出并发控制字段，下面的示例省略了 `_source` 中的部分内容：

```json
{
  "_index": "products",
  "_id": "p1001",
  "_seq_no": 2,
  "_primary_term": 1,
  "found": true,
  "_source": {
    "product_id": "p1001",
    "name": "机械键盘 K8",
    "price": 399.0,
    "stock": 23
  }
}
```

这里的 `2` 和 `1` 只是示例，实际值取决于此前执行过多少次写入以及主分片状态。第二步把本次 GET 实际返回的两个值带入更新请求。假设读取到的值确实是 `_seq_no: 2` 和 `_primary_term: 1`：

```http
POST /products/_update/p1001?if_seq_no=2&if_primary_term=1
{
  "doc": {"price": 389.0}
}
```

Elasticsearch 只会在当前文档的 `_seq_no` 和 `_primary_term` 仍与请求参数完全相同时执行更新。假设第一次条件更新成功后，文档的 `_seq_no` 从 `2` 变为 `3`；如果不重新 GET 最新值，下一次更新仍携带 `if_seq_no=2&if_primary_term=1`，这些并发控制参数就已经过期，无论请求体是否改变都会返回 HTTP 409。此时应用应重新读取最新文档，按业务规则合并后再提交，不能无脑覆盖。

`PUT /products/_doc/p1001` 也支持相同的 `if_seq_no` 和 `if_primary_term` 参数，但 PUT 会用请求体替换完整 `_source`；这里使用 `_update` 是为了只修改价格字段。

## 6. 批量操作接口

Bulk API 把多个文档操作放进一次 HTTP 请求。批量请求中的 `index`、`create`、`update` 和 `delete` 是每条子操作的动作名，不是新的索引名称；它们与前文非批量 API 的对应关系如下：

| Bulk 动作 | 对应的非批量请求              | 行为                                         | 是否需要下一行数据     |
| --------- | ----------------------------- | -------------------------------------------- | ---------------------- |
| `index`   | `PUT /products/_doc/{id}`     | `_id` 不存在时创建，存在时覆盖完整 `_source` | 需要，下一行是完整文档 |
| `create`  | `PUT /products/_create/{id}`  | 仅在 `_id` 不存在时创建，否则返回 409        | 需要，下一行是完整文档 |
| `update`  | `POST /products/_update/{id}` | 使用 `doc` 或脚本进行部分更新                | 需要，下一行是更新内容 |
| `delete`  | `DELETE /products/_doc/{id}`  | 删除指定文档                                 | 不需要                 |

例如，下面第一行外层的 `index` 表示执行普通索引操作，内层的 `_index` 和 `_id` 分别指定目标索引 `products` 和文档标识 `p1003`；紧随其后的第二行才是要写入的完整文档。这里的两个“index”含义不同：动作名 `index` 表示创建或覆盖文档，元数据字段 `_index` 表示文档写到哪个索引。

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
