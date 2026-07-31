# 15｜安全：TLS、用户、角色与 API 密钥：练习与验收答案

建议先独立完成练习，再使用本页核对 API Key 的权限范围、拒绝结果和泄露处置步骤。以下标记为 `http` 的管理请求在 Kibana 的开发工具（Dev Tools）中执行，并假定当前登录身份具有创建和吊销自有 API Key 所需的 `manage_own_api_key` 等权限。使用新 API Key 验收时则从终端运行 `curl`，确保检查的是该密钥而不是 Kibana 当前登录用户。

终端命令假定已按课程约定设置 `ES_URL`、`ES_CA` 和 `ES_API_KEY`，其中 `ES_API_KEY` 是创建响应的 `encoded` 值。不要把真实 `encoded` 值写入本文档、Git、工单或截图，也不要使用 `curl -k` 绕过证书校验。

先用管理身份确认第 14 课的读别名已存在：

```http
GET /_alias/products-read
```

如果返回 404，应先按第 14 课创建或修复 `products-read` 别名，而不要为了让本练习通过而改成其他资源名称。

## 1. 创建只能搜索 `products-read` 的 API Key

使用有权创建 API Key 的登录身份执行：

```http
POST /_security/api_key
{
  "name": "products-reader-c15",
  "expiration": "1h",
  "role_descriptors": {
    "products_reader_c15": {
      "cluster": [],
      "indices": [
        {
          "names": ["products-read"],
          "privileges": ["read", "view_index_metadata"],
          "allow_restricted_indices": false
        }
      ]
    }
  },
  "metadata": {
    "owner": "course-student",
    "purpose": "lesson-15-exercise"
  }
}
```

这里的权限边界是：

- `cluster: []` 不授予任何集群级权限。
- `names` 只包含 `products-read`，不使用 `products-*` 或 `*` 扩大资源范围。
- `read` 是 Elasticsearch 的索引只读权限，除 `_search` 外还包含获取文档、计数等读操作。因此题目中的“只能搜索”应理解为“只具有业务只读能力”，而不是只能调用单一 `_search` 端点。
- `view_index_metadata` 允许客户端读取映射、别名和字段能力（字段类型以及是否可搜索、可聚合）等元数据，但不允许修改它们。
- 没有 `index`、`create_doc`、`delete` 或 `delete_index`，因此不能写入文档、删除文档或删除索引。

`products_reader_c15` 是该 API Key 内嵌权限描述的名称，不是对现有 `products_reader` 角色的引用。API Key 的有效权限还会受创建者当时权限快照限制；如果创建者本身不能读取 `products-read`，新密钥也不会凭空获得该权限。

创建成功的响应关键字段类似：

```json
{
  "id": "实际 API Key ID",
  "name": "products-reader-c15",
  "expiration": 1785500000000,
  "api_key": "只显示一次的密钥原文",
  "encoded": "只显示一次的编码值"
}
```

`expiration` 的具体毫秒时间戳以实际响应为准。立即把 `encoded` 存入安全的临时凭据位置，并另外记录非机密的 `id`、`name`、所有者和过期时间。

## 2. 验证可以搜索但不能删除索引

### 2.1 确认终端使用的是新 API Key

使用第 1 题响应的 `encoded` 值设置 `ES_API_KEY` 后，调用认证端点：

```bash
curl --cacert "$ES_CA" -i \
  -H "Authorization: ApiKey $ES_API_KEY" \
  "$ES_URL/_security/_authenticate"
```

应返回 HTTP `200`，且响应中的 `authentication_type` 为 `api_key`。如果返回 401，先检查是否完整使用了 `encoded` 值、密钥是否过期，以及请求是否连接到创建密钥的同一集群。

### 2.2 验证搜索成功

```bash
curl --cacert "$ES_CA" -i \
  -H "Authorization: ApiKey $ES_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST \
  --data-binary '{"query":{"match_all":{}},"size":0}' \
  "$ES_URL/products-read/_search"
```

这与前面课程在 Kibana Dev Tools 中使用的 `POST /_search` 加 JSON 请求体是同一种写法，只是在终端中需要用 `-H` 声明 JSON 内容类型，并用 `--data-binary` 传入请求体。`match_all` 匹配所有文档，`size: 0` 表示不返回具体文档，但仍会执行搜索并返回总命中数。

请求应返回 HTTP `200`，响应中存在 `hits.total`。文档数可以为 0；验收重点是搜索请求已被授权，而不是必须命中某篇文档。

### 2.3 非破坏性地验证不能删除索引

继续使用同一 API Key 检查权限：

```bash
curl --cacert "$ES_CA" -i \
  -H "Authorization: ApiKey $ES_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST \
  --data-binary '{
    "cluster": ["monitor"],
    "index": [
      {
        "names": ["products-read"],
        "privileges": [
          "read",
          "view_index_metadata",
          "index",
          "delete_index"
        ]
      }
    ]
  }' \
  "$ES_URL/_security/user/_has_privileges"
```

该检查请求本身应返回 HTTP `200`，但因为所查权限中有不满足项，`has_all_requested` 应为 `false`。关键结果应与下面一致：

```json
{
  "has_all_requested": false,
  "cluster": {
    "monitor": false
  },
  "index": {
    "products-read": {
      "read": true,
      "view_index_metadata": true,
      "index": false,
      "delete_index": false
    }
  }
}
```

这同时证明了：

- `read: true`：具有预期的只读业务权限。
- `index: false`：不能创建或覆盖文档。
- `delete_index: false`：不能删除索引。
- `monitor: false`：没有额外的集群监控权限。

不应使用真实业务索引执行 `DELETE /<具体索引>` 来验证：如果 API Key 被意外过度授权，这条“测试”会真正删除数据。也不要通过 `DELETE /products-read` 的失败来下结论，因为 `products-read` 是别名，删除索引 API 不接受别名；这种失败不能证明权限配置正确。

## 3. API Key 泄露后的吊销、替换和审计步骤

泄露处置与日常轮换的顺序不同。日常轮换可以“创建新密钥 → 切换应用 → 吊销旧密钥”以避免中断；已确认泄露时应优先阻断旧密钥，不应为了保留重叠期而让攻击者继续使用它。

### 3.1 识别密钥并立即止损

1. 记录发现时间、泄露位置、API Key `id`、`name`、所有者和预期用途，但不在事故记录中复制 `api_key` 或 `encoded` 机密值。
2. 如果只知道名称，使用有管理权限的身份查询候选密钥，再根据所有者和创建时间确认目标：

```http
GET /_security/api_key?name=products-reader-c15
```

不要在同名密钥存在多条时猜测 `id`。确认后立即吊销泄露的密钥：

```http
DELETE /_security/api_key
{
  "ids": ["<泄露密钥的 id>"]
}
```

响应的 `invalidated_api_keys` 应包含目标 `id`。如果出现 `error_count`，应先处理错误，不能因为请求返回了 HTTP 200 就认为所有密钥都已吊销。

### 3.2 验证旧密钥已失效

使用旧 `encoded` 值调用：

```bash
curl --cacert "$ES_CA" -i \
  -H "Authorization: ApiKey $ES_API_KEY" \
  "$ES_URL/_security/_authenticate"
```

此时应返回 HTTP `401`。如果仍返回 200，检查吊销的 `id` 是否属于正在测试的 `encoded` 值，以及管理请求与验证请求是否连接到同一集群。

### 3.3 创建替换密钥并切换应用

使用与第 1 题相同的最小权限描述创建新密钥，但使用新名称：

```http
POST /_security/api_key
{
  "name": "products-reader-c15-replacement",
  "expiration": "1h",
  "role_descriptors": {
    "products_reader_c15": {
      "cluster": [],
      "indices": [
        {
          "names": ["products-read"],
          "privileges": ["read", "view_index_metadata"],
          "allow_restricted_indices": false
        }
      ]
    }
  },
  "metadata": {
    "owner": "course-student",
    "purpose": "lesson-15-incident-replacement"
  }
}
```

1. 将新 `encoded` 值写入企业密钥系统或其他受控位置，不写入应用配置文件或 Git。
2. 让应用重新加载密钥，然后用新密钥调用 `_authenticate` 和 `products-read/_search`，两者都应返 200。
3. 再次验证旧密钥仍返回 401，避免部署过程意外恢复了旧凭据。

### 3.4 调查影响并完成审计

从密钥可能首次暴露的时间开始，一直检查到吊销完成：

- 在 Elasticsearch 审计日志、反向代理/负载均衡器日志、应用日志和密钥系统访问日志中，按 API Key `id`、`name`、所有者、时间范围和来源地址查找相关请求。Elasticsearch 审计功能需要事先启用；未保留的历史日志无法在事后完整补回。
- 核对请求的操作、目标索引/别名、来源地址、时间和结果，判断是否存在非预期读取、写入、删除或管理操作。本练习的密钥是只读密钥，但仍需评估是否发生了未授权数据读取。
- 如果日志显示数据或配置已被改动，根据快照、变更记录和业务数据源确认影响，在保留证据后执行恢复。同时检查与该密钥一同暴露的其他凭据，不要只替换一个 API Key 就结束调查。
- 完成事故记录：包含时间线、根因、影响范围、吊销和恢复证据、负责人及后续改进项。改进可包括缩短过期时间、完善轮换自动化、限制密钥系统访问和为异常调用建立告警。

## 验收清单

- API Key 的 `role_descriptors` 只授予 `products-read` 上的 `read` 和 `view_index_metadata`，`cluster` 为空。
- 使用 API Key 调用 `_authenticate` 和 `products-read/_search` 都返回 200。
- `_has_privileges` 显示 `read: true`、`index: false`、`delete_index: false` 和 `monitor: false`。
- 能说明为什么不应使用真实 `DELETE` 请求验证最小权限。
- 能区分日常轮换与密钥泄露时的处置顺序，并写出“识别 → 吊销 → 验证失效 → 替换 → 应用验证 → 审计与复盘”的完整链路。
