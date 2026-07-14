# 13｜应用接入与客户端实践

## 本节目标

- 正确配置官方客户端的 TLS、认证、超时和重试。
- 封装稳定的搜索接口，避免暴露任意 DSL。
- 建立测试和可观测性习惯。

## 1. 连接原则

- 优先使用对应语言的 Elastic 官方客户端，并核对客户端与服务端兼容矩阵。
- 生产环境使用专用服务账户、API 密钥或最小权限用户，禁止应用使用 `elastic` 超级用户。
- 校验 CA 和主机名，禁止关闭 TLS 验证。
- 设置连接、请求、总体业务超时；对安全的请求做有限重试和指数退避。
- 多节点自管集群应配置多个入口或负载均衡；不要把专用主节点作为业务流量入口。
- 记录应用请求标识、Elasticsearch 的 `took`、总延迟、命中数和错误分类，不记录密码或 API 密钥。

## 2. Python 客户端示例

安装与你的服务端兼容的官方包：

```bash
python -m pip install elasticsearch
```

```python
import os
from elasticsearch import Elasticsearch

client = Elasticsearch(
    os.environ["ES_URL"],
    ca_certs=os.environ["ES_CA"],
    api_key=os.environ["ES_API_KEY"],
    request_timeout=2,
    max_retries=3,
    retry_on_timeout=True,
)

def search_products(keyword: str, category: str | None, page_size: int = 20):
    page_size = min(max(page_size, 1), 100)
    filters = [{"term": {"available": True}}]
    if category:
        filters.append({"term": {"category": category}})

    return client.search(
        index="products-read",
        size=page_size,
        source=["product_id", "name", "price", "stock"],
        query={
            "bool": {
                "must": [{"multi_match": {"query": keyword, "fields": ["name^3", "description"]}}],
                "filter": filters,
            }
        },
    )
```

参数是结构化的 JSON 值，不要通过字符串拼接来生成 JSON 或脚本源码。

## 3. JavaScript 客户端示例

```bash
npm install @elastic/elasticsearch
```

```javascript
import fs from 'node:fs'
import { Client } from '@elastic/elasticsearch'

const client = new Client({
  node: process.env.ES_URL,
  auth: { apiKey: process.env.ES_API_KEY },
  tls: { ca: fs.readFileSync(process.env.ES_CA) },
  requestTimeout: 2000,
  maxRetries: 3
})

const result = await client.search({
  index: 'products-read',
  size: 20,
  _source: ['product_id', 'name', 'price'],
  query: {
    bool: {
      must: [{ match: { name: '无线键盘' } }],
      filter: [{ term: { available: true } }]
    }
  }
})

console.log(result.hits.hits)
```

## 4. 接口边界设计

对外服务接受业务参数，例如 `keyword/category/min_price/cursor`，由后端构造固定的查询 DSL。限制如下：

- 可搜索、排序、聚合的字段白名单。
- 限制 `size` 上限、最大时间范围和最大聚合桶数量。
- 不允许直接提交脚本、正则表达式、前导通配符或任意索引名称。
- 为租户或数据权限强制注入过滤条件，不能信任客户端传来的租户标识。
- 错误响应应隐藏节点地址、堆栈和原始查询 DSL 中的敏感信息。

## 5. 测试分层

- 单元测试：验证业务参数到查询 DSL 的转换，以及页大小和字段白名单。
- 集成测试：使用与生产环境相同主版本的真实 Elasticsearch 容器验证映射和查询。
- 相关性回归：使用固定数据集和标注查询，比较前 K 条结果指标。
- 容错测试：模拟 429、超时、单节点不可用和部分批量操作失败。

## 练习与验收

- 使用一种官方客户端，以 API 密钥和证书颁发机构证书连接。
- 实现带字段白名单和结果数量上限的商品搜索函数。
- 测试 429 重试上限，确认不会无限重试。

上一节：[12｜数据接入](./12-data-ingestion.md)｜下一节：[14｜索引管理](./14-index-management.md)
