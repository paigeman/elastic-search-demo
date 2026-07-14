# 附录｜常用 API 速查

> 先确认环境和目标。`DELETE`、配置变更、重新索引、恢复、重新路由等操作不可只凭速查表直接在生产环境执行。

## 集群与节点

```http
GET /
GET /_cluster/health
GET /_cluster/state/metadata?filter_path=metadata.cluster_uuid
GET /_cluster/settings?include_defaults=true&flat_settings=true
GET /_cat/nodes?v
GET /_nodes/stats
GET /_nodes/hot_threads
GET /_cluster/pending_tasks
GET /_tasks?detailed=true&actions=*
```

## 索引与分片

```http
GET /_cat/indices?v
GET /_cat/shards?v
GET /products/_mapping
GET /products/_settings?flat_settings=true
GET /_alias/products-read
POST /_cluster/allocation/explain
{}
```

## 文档与搜索

```http
PUT /products/_doc/p1001
{"product_id":"p1001","name":"Keyboard"}

GET /products/_doc/p1001

POST /products/_search
{"query":{"match_all":{}},"size":10}

POST /_bulk
{"index":{"_index":"products","_id":"p1002"}}
{"product_id":"p1002","name":"Mouse"}

POST /products/_count
{"query":{"term":{"available":true}}}
```

## 映射、模板和分析

```http
POST /_analyze
{"analyzer":"standard","text":"Quick Start"}

GET /_component_template
GET /_index_template
POST /_index_template/_simulate_index/products-v99
```

## 摄取管道、任务与重新索引

```http
GET /_ingest/pipeline
POST /_ingest/pipeline/pipeline-name/_simulate
{"docs":[{"_source":{"message":"test"}}]}

POST /_reindex?wait_for_completion=false
{"source":{"index":"old-index"},"dest":{"index":"new-index"}}

GET /_tasks/<task_id>
POST /_tasks/<task_id>/_cancel
```

取消是否立即生效取决于任务是否支持取消和当前执行点。

## 安全

```http
GET /_security/_authenticate
GET /_security/role
GET /_security/user
GET /_security/api_key?owner=true

POST /_security/user/_has_privileges
{"cluster":["monitor"],"index":[{"names":["products-read"],"privileges":["read"]}]}
```

## 快照

```http
GET /_snapshot
POST /_snapshot/repository-name/_verify
GET /_snapshot/repository-name/_all
GET /_slm/status
GET /_slm/policy
```

## 故障排查

```http
GET /_cat/thread_pool?v
GET /_cat/recovery?v&active_only=true
GET /_recovery?active_only=true&detailed=true
GET /_nodes/stats/jvm,fs,indices,thread_pool
GET /_cluster/allocation/explain?include_yes_decisions=false
{}
```

## curl 请求模板

```bash
curl --silent --show-error \
  --connect-timeout 2 \
  --max-time 10 \
  --cacert "$ES_CA" \
  -H "Authorization: ApiKey $ES_API_KEY" \
  -H 'Content-Type: application/json' \
  -X POST "$ES_URL/products-read/_search" \
  -d '{"query":{"match_all":{}},"size":10}'
```

## 状态码速查

| 状态码 | 第一判断 | 首要检查 |
| --- | --- | --- |
| 400 | 请求不合法 | `error.root_cause`、映射、查询 DSL、参数 |
| 401 | 认证失败 | 凭据、过期、认证请求头、代理 |
| 403 | 授权不足 | 身份、角色、索引或别名、所需权限 |
| 404 | 资源不存在 | 环境、索引/文档/模板名称 |
| 409 | 冲突 | 序列号、主分片任期、重复创建、资源状态 |
| 429 | 过载或拒绝 | 线程池、堆内存、磁盘、并发、批次、慢查询 |
| 502/503/504 | 上游或服务不可用 | 负载均衡、节点状态、超时、重试安全性 |

返回：[课程首页](./README.md)
