# 13｜应用接入与客户端实践

## 本节目标

- 正确配置官方客户端的 TLS、认证、超时和重试。
- 封装稳定的搜索接口，避免暴露任意 DSL。
- 建立测试和可观测性习惯。

## 操作环境与实验数据

本章的 Elasticsearch HTTP 请求都在 Kibana 的“开发工具（Dev Tools）→ Console”中执行，客户端程序则从终端运行。为了不依赖前面章节留下的索引状态，本章使用独立的 `application-client-products-v1` 索引，并通过 `application-client-products-read` 别名提供稳定的读取入口。

下面的初始化脚本会删除并重建实验索引，请勿将索引名替换为需要保留数据的业务索引：

```http
DELETE /application-client-products-v1?ignore_unavailable=true

PUT /application-client-products-v1
{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0
  },
  "mappings": {
    "dynamic": "strict",
    "properties": {
      "product_id": {"type": "keyword"},
      "name": {"type": "text"},
      "description": {"type": "text"},
      "category": {"type": "keyword"},
      "price": {"type": "scaled_float", "scaling_factor": 100},
      "stock": {"type": "integer"},
      "available": {"type": "boolean"}
    }
  },
  "aliases": {
    "application-client-products-read": {}
  }
}
```

再使用 Bulk API 写入五件商品。`refresh=wait_for` 会等待数据对搜索可见，因此初始化完成后可以立即运行客户端示例：

```http
POST /application-client-products-v1/_bulk?refresh=wait_for&filter_path=errors,items.*.status
{"index":{"_id":"p1301"}}
{"product_id":"p1301","name":"机械键盘 K8","description":"87 键无线机械键盘","category":"keyboard","price":399.0,"stock":25,"available":true}
{"index":{"_id":"p1302"}}
{"product_id":"p1302","name":"无线办公键盘","description":"轻薄静音无线键盘","category":"keyboard","price":299.0,"stock":18,"available":true}
{"index":{"_id":"p1303"}}
{"product_id":"p1303","name":"无线游戏键盘","description":"无线机械键盘，旧型号暂时缺货","category":"keyboard","price":459.0,"stock":0,"available":false}
{"index":{"_id":"p1304"}}
{"product_id":"p1304","name":"USB-C 扩展坞","description":"支持显示器和有线键盘连接","category":"accessory","price":499.0,"stock":8,"available":true}
{"index":{"_id":"p1305"}}
{"product_id":"p1305","name":"人体工学键盘","description":"分体式无线办公键盘","category":"keyboard","price":699.0,"stock":6,"available":true}
```

Bulk 响应中的 `errors` 应为 `false`，每个 `index.status` 应为 `201`。最后通过读取别名确认五条文档均已写入：

```http
GET /application-client-products-read/_count
```

预期返回的 `count` 是 `5`。`p1303` 被设置为不可用，后面的客户端搜索会通过固定过滤条件将它排除；`p1304` 则用于验证类目过滤。

客户端不应使用 `elastic` 超级用户。继续在 Console 中创建一个有效期为一天、只能读取本章实验索引的 API 密钥：

```http
POST /_security/api_key
{
  "name": "course-13-search-client",
  "expiration": "1d",
  "role_descriptors": {
    "course-13-product-reader": {
      "cluster": [],
      "indices": [
        {
          "names": ["application-client-products-*"],
          "privileges": ["read"]
        }
      ]
    }
  }
}
```

妥善保存响应中的 `encoded` 值，稍后把它设置到本机的 `ES_API_KEY` 环境变量中。API 密钥属于敏感信息，不要写入源码、提交到 Git 或记录到日志。

## 1. 客户端连接原则

- 优先使用对应语言的 Elastic 官方客户端，并核对客户端与服务端兼容矩阵。
- 生产环境使用专用服务账户、API 密钥或最小权限用户，禁止应用使用 `elastic` 超级用户。
- 校验 CA 和主机名，禁止关闭 TLS 验证。
- 设置连接、请求、总体业务超时；对安全的请求做有限重试和指数退避。
- 多节点自管集群应为客户端配置多个可接收业务流量的节点，或在这些节点前配置负载均衡器；不要把专用主节点作为业务流量入口。
- 记录应用请求标识、Elasticsearch 的 `took`、总延迟、命中数和错误分类，不记录密码或 API 密钥。

典型请求路径是“客户端 → 外部负载均衡器（可选）→ Elasticsearch 协调节点 → 持有目标分片的数据节点”。外部负载均衡器负责入口流量分配、健康检查和故障切换；收到请求的 Elasticsearch 节点则成为该请求的协调节点，负责集群内部路由与结果汇总。大型集群可以使用多个专用协调节点承接入口流量，但仍应避免让单个协调节点成为唯一入口。

## 2. Python 客户端示例

先确保当前 Python 环境已经安装与服务端主版本兼容的官方 `elasticsearch` 包。使用哪一种虚拟环境或依赖管理工具由项目自行决定。

下面的示例包括客户端初始化、搜索函数和一次实际调用，可以直接保存为 `search_products.py`：

```python
import json
import os

from elasticsearch import Elasticsearch

INDEX_NAME = "application-client-products-read"

client = Elasticsearch(
    os.environ["ES_URL"],
    ca_certs=os.environ["ES_CA"],
    api_key=os.environ["ES_API_KEY"],
    request_timeout=2,
    max_retries=3,
    retry_on_timeout=True,
)


def search_products(
    keyword: str,
    category: str | None,
    page_size: int = 20,
):
    page_size = min(max(page_size, 1), 100)
    filters = [{"term": {"available": True}}]
    if category:
        filters.append({"term": {"category": category}})

    response = client.search(
        index=INDEX_NAME,
        size=page_size,
        source=["product_id", "name", "price", "stock"],
        query={
            "bool": {
                "must": [
                    {
                        "multi_match": {
                            "query": keyword,
                            "fields": ["name^3", "description"],
                        }
                    }
                ],
                "filter": filters,
            }
        },
    )
    return response.body


if __name__ == "__main__":
    try:
        result = search_products("无线键盘", category="keyboard")
        print(json.dumps(result, ensure_ascii=False, indent=2))
    finally:
        client.close()
```

`page_size` 被限制在 1～100，`available` 是应用强制加入的固定过滤条件，调用者只能选择关键词和类目，不能提交任意 DSL。查询参数始终以结构化的 Python 值构造，不要通过字符串拼接生成 JSON 或脚本源码。

设置连接参数。`ES_CA` 必须替换为当前 Elasticsearch 实例的 CA 证书路径：

```bash
export ES_URL='https://localhost:9200'
export ES_CA='/path/to/http_ca.crt'
export ES_API_KEY='<创建 API 密钥时返回的 encoded 值>'
```

运行商品搜索：

```bash
python search_products.py
```

结果中应包含 `p1301`、`p1302` 和 `p1305`，不应包含不可用的 `p1303` 或属于配件类目的 `p1304`。如果 API 密钥已经超过一天的有效期，请重新创建密钥并更新 `ES_API_KEY`，不要把 `elastic` 密码改写到示例中。

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
  index: 'application-client-products-read',
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
