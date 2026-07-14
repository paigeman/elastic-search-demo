# 15｜安全：TLS、用户、角色与 API 密钥

## 本节目标

- 理解认证、授权、TLS 与审计的边界。
- 按最小权限原则创建角色和 API 密钥。
- 处理凭据轮换与常见 401/403。

## 1. 安全基线

现代 Elasticsearch 首次启动会自动配置 HTTP 层与传输层的 TLS、`elastic` 密码等安全能力。生产要求如下：

- 9200、9300 只开放给需要的网络范围，Kibana 也应置于认证与访问控制之后。
- 客户端验证 CA 与主机名；测试用 `-k` 不得进入生产脚本。
- `elastic` 仅用于初始化/救援，日常管理和应用分别使用最小权限身份。
- 密钥应放在企业密钥系统、Kubernetes Secret、密钥库等受控位置，不得提交到 Git。
- 建立过期、轮换、吊销和应急泄露处置流程。

## 2. 创建业务角色

只允许读商品别名：

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

写入角色：

```http
PUT /_security/role/products_writer
{
  "cluster": [],
  "indices": [
    {
      "names": ["products-write"],
      "privileges": ["create_doc", "index", "delete", "view_index_metadata"]
    }
  ]
}
```

是否授予 `delete`、`index` 取决于同步语义；仅追加链路优先 `create_doc`。不要给应用 `manage` 或通配 `all`。

## 3. 用户与 API 密钥

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

```http
GET /_security/_authenticate
POST /_security/user/_has_privileges
{
  "cluster": ["monitor"],
  "index": [{"names":["products-read"],"privileges":["read"]}]
}
```

- 401：检查认证头格式、密码或密钥是否过期或被吊销、时间偏差，以及代理是否移除了请求头。
- 403：身份有效；检查角色、索引或别名名称、受限索引，以及具体操作所需的权限。

## 练习与验收

- 创建只能搜索 `products-read` 的 API 密钥。
- 验证该密钥可以搜索但不能删除索引。
- 写出 API 密钥泄露后的吊销、替换和审计步骤。

上一节：[14｜索引管理](./14-index-management.md)｜下一节：[16｜监控与排障](./16-monitoring-and-troubleshooting.md)
