# 05｜REST API、curl 与开发工具

## 本节目标

- 掌握 Elasticsearch HTTP API 的请求结构。
- 能在 curl 与开发工具之间转换请求。
- 学会读状态码和错误根因。

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

对应 curl：

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

## 3. 读懂响应

```json
{
  "took": 3,
  "timed_out": false,
  "_shards": {"total": 1, "successful": 1, "skipped": 0, "failed": 0},
  "hits": {
    "total": {"value": 42, "relation": "eq"},
    "max_score": 1.0,
    "hits": []
  }
}
```

- `took` 仅表示服务端处理耗时，单位为毫秒，不包含完整的网络和客户端耗时。
- `_shards.failed` 不应被忽略；HTTP 200 仍可能伴随部分分片失败。
- `hits.total.relation` 为 `gte` 时，总数只是下界。

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
GET /_cluster/health?filter_path=status,number_of_nodes,unassigned_shards
GET /_cat/indices?v&h=health,status,index,pri,rep,docs.count,store.size
GET /products/_mapping
GET /products/_settings?flat_settings=true
```

生产脚本使用 `filter_path` 减少响应内容，设置连接和请求超时，记录请求标识，对 429/502/503 响应执行带随机抖动的指数退避，但不要无限重试非幂等写入。

## 练习与验收

- 在开发工具与 curl 中各执行一次集群健康状态请求。
- 人为查询不存在的索引，找出 HTTP 状态码和 `root_cause`。
- 使用 `filter_path` 只返回集群状态和节点数。

上一节：[04｜Compose 与 Kibana](./04-compose-and-kibana.md)｜下一节：[06｜增删改查与批量操作](./06-index-document-crud.md)
