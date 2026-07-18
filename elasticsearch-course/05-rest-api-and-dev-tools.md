# 05｜REST API、curl 与开发工具

## 本节目标

- 掌握 Elasticsearch HTTP API 的请求结构。
- 能在 curl 与开发工具之间转换请求。
- 学会按通用方法阅读成功响应、局部失败和错误根因。

## 1. 请求结构

典型 API 由请求方法、路径、查询参数和 JSON 请求体组成：

```http
POST /products/_search?track_total_hits=true
Content-Type: application/json

{
  "query": { "match_all": {} },
  "size": 10
}
```

下面的命令假定已经设置 `ES_URL`、`ES_CA` 和 `ELASTIC_PASSWORD`。如果使用第 04 课的独立 Compose 集群，应先按[第 04 课的证书复制步骤](./04-compose-and-kibana.md#32-复制-ca-并验证-elasticsearch-api)取得该集群自己的 `http_ca.crt`；不同集群的 CA 不能混用。

使用 curl 发出同一请求：

```bash
curl --cacert "$ES_CA" -u "elastic:$ELASTIC_PASSWORD" \
  -H 'Content-Type: application/json' \
  -X POST "$ES_URL/products/_search?track_total_hits=true" \
  -d '{"query":{"match_all":{}},"size":10}'
```

Elasticsearch 虽然支持 GET 请求携带请求体，但部分代理或客户端的处理方式不一致；搜索接口使用 `POST /_search` 更稳妥。

## 2. 常用方法

| 方法 | 常见用途 | 是否幂等 |
| --- | --- | --- |
| GET | 获取文档、查询状态 | 是 |
| PUT | 创建指定资源或按指定标识写文档 | 通常是 |
| POST | 搜索、自动生成标识并写入、执行动作 | 视 API 而定 |
| DELETE | 删除文档、索引或资源 | 目标消失后重复请求结果会不同，但期望状态一致 |

## 3. 响应的通用读法

Elasticsearch 的成功响应没有一套所有 API 都具备的字段。阅读响应时，不要套用固定的 JSON 结构，而应按以下顺序判断：

1. 看 HTTP 状态码，判断请求整体是否成功。
2. 根据所调用 API 的文档阅读响应主体；不同类型的 API 返回不同字段。
3. 即使 HTTP 状态码表示成功，也要检查是否存在分片、批量条目等局部失败。
4. 请求失败时，从结构化错误信息中定位错误类型和根因。

下面这些字段经常出现，但都不是所有响应共有的字段：

| API 类型 | 常见字段 | 主要含义 |
| --- | --- | --- |
| 搜索 | `took`、`timed_out`、`_shards`、`hits` | 执行耗时、是否超时、分片执行情况和搜索结果 |
| 文档写入 | `_index`、`_id`、`result`、`_version`、`_seq_no` | 文档位置、写入结果及并发控制信息 |
| 索引与集群管理 | `acknowledged`、`status`、`number_of_nodes` | 操作确认或集群状态；具体字段取决于所调用的 API |
| 批量操作 | `took`、`errors`、`items` | 整体耗时、是否存在失败条目及每条操作的结果 |

特别注意，HTTP 200 不一定表示每个子操作都成功：分片类响应要检查 `_shards.failed` 和 `_shards.failures`，批量响应要检查 `errors` 以及 `items` 中每条操作的状态。`took` 如果存在，只表示 Elasticsearch 服务端处理耗时，不包含完整的网络和客户端耗时。

例如，在 Dev Tools 中故意搜索一个不存在的索引：

```http
POST /course_missing_index/_search

{
  "query": { "match_all": {} }
}
```

该请求会返回 HTTP 404，响应主体采用结构化 JSON：

```json
{
  "error": {
    "root_cause": [
      {
        "type": "index_not_found_exception",
        "reason": "no such index [course_missing_index]"
      }
    ],
    "type": "index_not_found_exception",
    "reason": "no such index [course_missing_index]"
  },
  "status": 404
}
```

排查时先结合 HTTP 状态码和 `error.type` 判断错误类别，再查看 `error.root_cause` 与 `error.reason` 获取具体原因。错误响应的细节也会随 API 和错误类型而变化。

## 4. 常见状态码

- `200/201`：成功。
- `400`：JSON、映射、查询或参数错误；查看 `error.root_cause`。
- `401`：未认证或凭据错误。
- `403`：已认证但角色无权限。
- `404`：文档、索引或资源不存在。
- `409`：版本冲突或资源状态冲突。
- `429`：线程池/队列饱和、熔断或服务过载；应退避并找根因。

只提取根因：

```bash
curl ... 2>/dev/null | jq '.error.root_cause // .error'
```

## 5. API 调试习惯

```http
GET /_cluster/health
GET /_cat/indices?v&h=health,status,index,pri,rep,docs.count,store.size
GET /products/_mapping
GET /products/_settings?flat_settings=true
```

CAT API 是 Elasticsearch 提供的一组固定端点，`_cat` 是这组端点的命名空间，不是可以添加在任意 API 路径前面的通用前缀。例如，`GET /_cat/health` 和 `GET /_cluster/health` 是两个独立端点；不能把后者改写成 `GET /_cat/_cluster/health`。并非每个普通 API 都有对应的 CAT 版本，可以通过 `GET /_cat` 查看当前版本提供的 CAT 端点。

CAT API 默认返回适合终端阅读的对齐文本。常用查询参数如下：

| 参数 | 作用 | 示例 |
| --- | --- | --- |
| `v` | 显示列名 | `GET /_cat/indices?v` |
| `h` | 只显示指定列，多个列用逗号分隔 | `GET /_cat/nodes?h=name,roles,cpu` |
| `s` | 按指定列排序，可使用 `:asc` 或 `:desc` | `GET /_cat/indices?s=store.size:desc` |
| `format` | 指定响应格式，例如 `json` | `GET /_cat/shards?format=json` |

`format=json` 只是将 CAT API 原本的表格结果改为 JSON 格式，并不会改变它面向人工查看的设计定位。CAT API 适合在命令行中检查状态和临时排查问题；应用程序、监控系统和长期运行的自动化任务应优先使用对应的结构化 API，以免依赖面向展示的列名和输出格式。

`filter_path` 用于只保留响应中需要的字段，多个字段之间用逗号分隔。例如，只查看集群状态、节点数和未分配分片数：

```http
GET /_cluster/health?filter_path=status,number_of_nodes,unassigned_shards
```

过滤后的响应类似：

```json
{
  "status": "yellow",
  "number_of_nodes": 1,
  "unassigned_shards": 1
}
```

`filter_path` 只精简返回给客户端的内容，不会改变 API 本身执行的操作。

生产脚本使用 `filter_path` 减少响应内容，设置连接和请求超时，记录请求标识，对 429/502/503 响应执行带随机抖动的指数退避，但不要无限重试非幂等写入。

## 练习与验收

- 在开发工具与 curl 中各执行一次集群健康状态请求。
- 执行前文针对 `course_missing_index` 的请求，确认 HTTP 状态码并找出 `error.root_cause`。
- 使用 `filter_path` 只返回集群状态和节点数。

上一节：[04｜Compose 与 Kibana](./04-compose-and-kibana.md)｜下一节：[06｜增删改查与批量操作](./06-index-document-crud.md)
