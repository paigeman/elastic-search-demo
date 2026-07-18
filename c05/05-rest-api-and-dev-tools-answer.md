# 05｜REST API、curl 与开发工具：练习与验收答案

建议先独立完成练习，再使用本页核对请求、响应和判断过程。以下命令假定 Elasticsearch 已经启动，并且 `ES_URL`、`ES_CA` 和 `ELASTIC_PASSWORD` 指向当前集群；不同集群的 CA 不能混用，也不要使用 `curl -k` 关闭证书校验。

## 1. 分别使用 Dev Tools 和 curl 查看集群健康状态

登录 Kibana 后，在 Dev Tools 中执行：

```http
GET /_cluster/health
```

响应应包含 `cluster_name`、`status`、`number_of_nodes` 和分片统计等字段，例如：

```json
{
  "cluster_name": "docker-cluster",
  "status": "yellow",
  "number_of_nodes": 1,
  "active_primary_shards": 1,
  "active_shards": 1,
  "unassigned_shards": 1
}
```

实际数值取决于当前集群。单节点课程环境可能显示 `yellow`，通常是因为副本分片无法与主分片分配到同一个节点；这不等于 Elasticsearch 已经无法读写。

在宿主机中使用 curl 调用同一个 API：

```bash
curl --silent --show-error \
  --cacert "$ES_CA" \
  -u "elastic:$ELASTIC_PASSWORD" \
  --write-out '\nHTTP %{http_code}\n' \
  "$ES_URL/_cluster/health?pretty"
```

响应主体应与 Dev Tools 中看到的是同一类结构，末尾应显示：

```text
HTTP 200
```

两种方式最终都调用 Elasticsearch 的 `9200` HTTP API，但连接路径不同：curl 从宿主机直接访问 Elasticsearch，需要显式提供 CA 和用户凭据；Dev Tools 由 Kibana 代发请求，并使用当前登录用户的认证上下文。

## 2. 请求不存在的索引并定位错误根因

在 Dev Tools 中执行课程正文里的请求：

```http
POST /course_missing_index/_search

{
  "query": { "match_all": {} }
}
```

如果该索引确实不存在，请求会返回 HTTP 404，错误主体类似：

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

应得出以下判断：

- HTTP 状态码是 `404`，表示请求的资源不存在。
- `error.type` 是 `index_not_found_exception`，表明错误类别是索引不存在。
- `error.root_cause[0].reason` 指出缺少的具体索引。

也可以用 curl 复现并通过 `jq` 只保留错误状态和根因：

```bash
curl --silent --show-error \
  --cacert "$ES_CA" \
  -u "elastic:$ELASTIC_PASSWORD" \
  -H 'Content-Type: application/json' \
  -X POST \
  "$ES_URL/course_missing_index/_search" \
  -d '{"query":{"match_all":{}}}' \
  | jq '{status, root_cause: .error.root_cause}'
```

预期输出类似：

```json
{
  "status": 404,
  "root_cause": [
    {
      "type": "index_not_found_exception",
      "reason": "no such index [course_missing_index]"
    }
  ]
}
```

这里的 404 是 Elasticsearch 正常返回的业务错误响应，不是网络连接失败或 TLS 校验失败。如果本机已经存在同名索引，应改用另一个确认不存在的测试名称。

## 3. 使用 `filter_path` 精简集群健康响应

在 Dev Tools 中执行：

```http
GET /_cluster/health?filter_path=status,number_of_nodes
```

响应只保留指定的两个字段，例如：

```json
{
  "status": "yellow",
  "number_of_nodes": 1
}
```

对应的 curl 请求为：

```bash
curl --silent --show-error \
  --cacert "$ES_CA" \
  -u "elastic:$ELASTIC_PASSWORD" \
  "$ES_URL/_cluster/health?filter_path=status,number_of_nodes"
```

验收时应确认响应中只有 `status` 和 `number_of_nodes`，并能说明 `filter_path` 只是精简返回给客户端的响应内容，不会改变集群健康检查本身执行的操作。
