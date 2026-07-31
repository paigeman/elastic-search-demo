# 15｜安全：TLS、用户、角色与 API 密钥

## 本节目标

- 理解认证、授权、TLS 与审计的边界。
- 按最小权限原则创建角色和 API 密钥。
- 处理凭据轮换与常见 401/403。

## 1. 安全基线

现代 Elasticsearch 首次启动会自动配置 HTTP 层与传输层的 TLS、`elastic` 密码等安全能力。生产要求如下：

- 9200、9300 只开放给需要的网络范围；Kibana 不应匿名暴露到公网，应限制在内网、VPN 或受控网关之后，并保留 Kibana 登录或企业 SSO 认证以及基于角色的授权。
- 客户端应验证 CA 与主机名；测试用 `curl -k` 不得进入生产脚本。
- `elastic` 仅用于初始化/救援，日常管理和应用分别使用最小权限身份。
- 密钥应放在企业密钥系统、Kubernetes Secret、密钥库等受控位置，不得提交到 Git。
- 建立过期、轮换、吊销和应急泄露处置流程。

这里的“验证主机名”由 HTTPS 客户端自动完成：请求 `https://es01:9200` 时，客户端既要确认服务端证书由可信 CA 签发，也要确认该证书的 SAN 包含 DNS 名称 `es01`；如果使用 IP 地址访问，证书的 SAN 则必须包含对应 IP。以 `curl` 为例，`--cacert "$ES_CA"` 会在信任指定 CA 的同时保留主机名校验，不需要再添加单独的主机名验证参数。

`curl -k` 是 `curl --insecure` 的短写，会跳过服务端证书的 CA 与主机名校验。连接仍使用 TLS，Elasticsearch 的密码或 API Key 认证也仍然存在，但客户端不能可靠确认服务端身份，因而可能遭受中间人攻击。它只适合隔离的本机临时实验或诊断；其风险已在[第 03 课的安全提醒](./03-container-installation.md#5-安全提醒)中说明，第 04 课的 [Compose 配置](./04-compose-and-kibana.md#13-compose-文件)则展示了证书 SAN 与完整主机名校验。

## 2. 创建业务角色

### 2.1 只读角色

下面创建名为 `products_reader` 的角色，只允许读取商品查询别名 `products-read`：

```http
PUT /_security/role/products_reader
{
  "cluster": [],
  "indices": [
    {
      "names": ["products-read"],
      "privileges": ["read", "view_index_metadata"],
      "allow_restricted_indices": false
    }
  ]
}
```

`PUT /_security/role/products_reader` 中最后一段是角色名；角色已存在时，该请求会更新它。JSON 字段含义如下：

- `cluster`：集群级权限，例如监控集群、管理模板或管理安全配置。空数组表示不授予任何集群级权限。
- `indices`：索引级权限规则数组。一个角色可以放入多条规则，分别约束不同索引、数据流或别名。
- `names`：当前规则适用的索引、数据流或别名，也可以使用名称模式。这里使用读别名 `products-read`，避免应用依赖具体物理索引名。
- `privileges`：在 `names` 指定目标上授予的操作。`read` 允许搜索、获取和统计文档；`view_index_metadata` 允许读取映射、别名、字段能力等元数据，常用于客户端理解索引结构，但不允许修改这些元数据。
- `allow_restricted_indices`：是否允许通配符或正则名称模式覆盖 Elasticsearch 的受限系统索引，例如安全功能使用的 `.security`。默认值为 `false`；保持 `false` 可以避免将来把 `names` 改成 `*` 等宽泛模式时意外覆盖受限索引。受限索引不等于所有以 `.` 开头的索引，业务角色通常不应访问它们。

“字段能力”（Field Capabilities）是字段结构元数据，用来说明字段在一个或多个索引中的类型，以及是否可搜索、是否可聚合。客户端可以通过下面的端点检查 `name` 和 `price`：

```http
POST /products-read/_field_caps?fields=name,price
```

该端点只返回字段类型、`searchable`、`aggregatable` 等元数据，不返回文档中的实际字段值。`_mapping` 展示每个索引如何定义字段，`_field_caps` 则便于客户端汇总判断这些字段能用于哪些操作，并发现多索引中的同名字段类型冲突。

因此，这个角色不能写入文档、删除文档或管理索引，也没有集群管理权限。

### 2.2 写入角色

下面创建名为 `products_writer` 的仅追加写入角色，写操作通过写别名 `products-write` 进入当前写索引：

```http
PUT /_security/role/products_writer
{
  "cluster": [],
  "indices": [
    {
      "names": ["products-write"],
      "privileges": ["create_doc", "view_index_metadata"],
      "allow_restricted_indices": false
    }
  ]
}
```

这里各层 JSON 字段与只读角色相同，区别在于目标是写别名 `products-write`，并授予写入权限：

- `create_doc`：只能创建新文档，不能更新或覆盖已有文档。请求需要使用 `_create` 端点、`op_type=create`，或者让 Elasticsearch 自动生成文档 `_id`，适合仅追加链路。“仅追加”是指日志、审计记录或业务事件等数据每次都写成一篇新文档，旧文档一经写入便不再修改或删除；例如订单的创建、付款和发货分别保存为三条事件。若应用使用固定 `_id` 反复保存商品的最新价格或库存，则属于当前状态同步，需要覆盖已有文档，不是仅追加。
- `index`：允许创建、更新或覆盖文档。同步程序需要按固定 `_id` 反复写入最新状态时，可以用它替换 `create_doc`。
- `delete`：允许删除文档，但不允许删除整个索引；删除索引需要危险性更高的 `delete_index` 权限。
- `view_index_metadata`：含义与上例相同。如果写入程序完全不需要读取映射、字段能力或别名元数据，可以进一步评估是否移除。

不要同时授予 `create_doc` 和 `index`，因为 `index` 已允许覆盖文档，会使 `create_doc` 的仅追加限制失去意义。是否改用 `index`、是否额外加入 `delete`，应由业务同步语义决定。这个写入角色本身没有 `read` 权限；同一应用如果还要查询，可以同时绑定 `products_reader` 和 `products_writer`，角色权限会合并。

“绑定两个角色”不是在 `names` 中填写两个别名。若身份是 Elasticsearch 原生用户，就在创建或更新用户的 `POST /_security/user/<用户名>` 请求体中，通过 `roles` 数组引用已有角色名。例如，下面创建或更新原生用户 `catalog_service`：

```http
POST /_security/user/catalog_service
{
  "password": "使用企业密码流程生成的强密码",
  "roles": ["products_reader", "products_writer"]
}
```

该用户由 `products_reader` 获得 `products-read` 的读取权限，由 `products_writer` 获得 `products-write` 的写入权限。`names` 只指定一条索引权限规则作用于哪些索引、数据流或别名；如果把两个别名放进同一个 `names`，同一组 `privileges` 会同时应用到二者。API Key 不直接引用已有角色名，而是在 `role_descriptors` 中内嵌权限；需要读写能力时，应分别放置针对 `products-read` 的读取规则和针对 `products-write` 的写入规则。不要为了省事给应用授予 `manage`、`delete_index` 或通配的 `all`。

## 3. 用户与 API 密钥

创建或更新 Elasticsearch 原生用户的端点格式是 `POST /_security/user/<用户名>`。其中 `/_security/user/` 是固定路径，后面的 `<用户名>` 是用户自行定义的实际用户名；下面的 `search_operator` 只是示例名称，不是 Elasticsearch 的固定关键字。该用户名不存在时创建用户，已存在时则更新该用户。

人工用户示例：

```http
POST /_security/user/search_operator
{
  "password": "使用企业密码流程生成的强密码",
  "roles": ["products_reader"],
  "full_name": "Search Operator"
}
```

应用应优先使用生命周期较短的 API 密钥。使用具备 `manage_own_api_key` 等所需权限的身份创建：

```http
POST /_security/api_key
{
  "name": "catalog-service-prod-2026q3",
  "expiration": "30d",
  "role_descriptors": {
    "catalog_reader": {
      "cluster": [],
      "indices": [
        {"names":["products-read"],"privileges":["read","view_index_metadata"]}
      ]
    }
  },
  "metadata": {"owner":"catalog-team","env":"prod"}
}
```

这里的 `role_descriptors` 是 API Key 自己的内嵌权限描述，其结构与创建角色时的请求体相似，但它不会按名称引用已有的 `products_reader` 等角色。`catalog_reader` 只是这段内嵌权限描述的自定义名称。API Key 的有效权限是这些内嵌权限与创建者当时权限快照的交集，因此不能通过 API Key 获得创建者本来没有的权限；省略 `role_descriptors` 或将其留空时，API Key 继承创建者当时的权限快照。

响应中的 `encoded` 值只显示一次。调用方式如下：

```bash
curl --cacert "$ES_CA" \
  -H "Authorization: ApiKey $ES_API_KEY" \
  "$ES_URL/products-read/_search"
```

轮换采用“创建新密钥 → 应用切换并验证 → 使旧密钥失效”的重叠方式。

## 4. 字段/文档级安全

多租户场景可以使用文档级安全约束租户过滤条件，并用字段级安全隐藏敏感字段，但应确认许可证要求和性能影响。权限过滤必须由受信任的配置绑定，不能只依赖应用请求参数。要求更严格隔离时，可能需要独立索引或集群。

## 5. 401 与 403 排查

`401 Unauthorized` 表示请求还没有通过身份认证；`403 Forbidden` 表示身份已经认证成功，但没有执行当前操作的权限。排查时必须使用与报错请求完全相同的用户、密码或 API Key；如果在 Kibana Dev Tools 中改用当前登录用户测试，检查的就不再是原来报错的应用身份。

| 原请求状态 | 首要问题                       | 主要排查端点                           |
| ---------- | ------------------------------ | -------------------------------------- |
| 401        | 这份凭据能否识别出有效身份？   | `GET /_security/_authenticate`         |
| 403        | 当前身份对目标是否有所需权限？ | `POST /_security/user/_has_privileges` |

### 5.1 用 `_authenticate` 排查 401

将原请求使用的 API Key 原样放入认证请求；`curl -i` 会同时显示 HTTP 状态码和响应头：

```bash
curl --cacert "$ES_CA" -i \
  -H "Authorization: ApiKey $ES_API_KEY" \
  "$ES_URL/_security/_authenticate"
```

下面的状态码指这个 `_authenticate` 诊断请求的结果，不是再次描述原业务请求：

- `_authenticate` 返回 `200`：说明凭据在这次诊断请求中有效，响应中的 `username`、`roles` 和 `authentication_type` 显示 Elasticsearch 实际识别到的身份。由于原业务请求曾返回 401，两个请求在传输过程中实际存在差异；重点比较应用真正发出的 `Authorization` 头、代理路由和目标集群。如果两者的凭据、代理路径和目标集群完全相同，通常不应出现这种结果差异。
- `_authenticate` 返回 `401`：说明诊断请求也未能建立身份，问题仍在认证阶段。检查认证头是否为 `Authorization: ApiKey <encoded 值>`、密码是否正确、密钥或令牌是否过期/被吊销，以及反向代理是否移除了认证头。使用 Bearer Token 时还要检查时钟偏差。

CA 或主机名校验失败属于 TLS 连接错误，发生在 HTTP 状态码之前，不是 401。如果使用用户名密码，可以把上述 `Authorization` 头换成 `-u "<用户名>:<密码>"`。

### 5.2 用 `_has_privileges` 排查 403

先确认 `_authenticate` 返回 `200`，再用同一份凭据检查原操作所需的具体权限。例如，排查搜索 `products-read` 时的 403：

```http
POST /_security/user/_has_privileges
{
  "cluster": [],
  "index": [
    {
      "names": ["products-read"],
      "privileges": ["read"]
    }
  ]
}
```

该端点检查的是发出请求的当前身份。缺少查询权限时，它通常仍返回 HTTP `200`，而不是再返回 403；应检查响应中的布尔值：

```json
{
  "username": "search_operator",
  "has_all_requested": false,
  "cluster": {},
  "index": {
    "products-read": {
      "read": false
    }
  },
  "application": {}
}
```

`has_all_requested: false` 表示至少一项被检查权限不满足；继续查看 `cluster` 或 `index` 中哪一项为 `false`。不要在一次请求中混入与失败操作无关的权限，否则会干扰判断。若所需权限为 `false`，原生用户应检查其绑定的角色；API Key 应检查其 `role_descriptors` 以及创建者的权限限制。同时确认请求的索引/别名是否与对应权限描述中的 `names` 匹配，以及是否访问了受限索引。

## 练习与验收

- 创建只能搜索 `products-read` 的 API 密钥。
- 验证该密钥可以搜索但不能删除索引。
- 写出 API 密钥泄露后的吊销、替换和审计步骤。

上一节：[14｜索引管理](./14-index-management.md)｜下一节：[16｜监控与排障](./16-monitoring-and-troubleshooting.md)
