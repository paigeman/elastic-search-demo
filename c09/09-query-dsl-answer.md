# 09｜查询语言与全文检索：练习与验收答案

建议先独立完成练习，再使用本页核对查询结构、结果集合和评分行为。以下标记为 `http` 的请求都在 Kibana 的开发工具（Dev Tools）中的控制台（Console）执行，并假定已经按照正文开头的初始化脚本创建 `query-dsl-products` 索引和 5 条实验数据。

## 1. 查询有货、100～500 元且商品描述匹配“无线键盘”的商品

商品描述需要全文分析并计算相关性，因此使用查询上下文；有货状态和价格范围是不能违反的业务条件，因此放在过滤上下文：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "query": {
    "bool": {
      "must": [
        {
          "match": {
            "description": {
              "query": "无线键盘",
              "operator": "and"
            }
          }
        }
      ],
      "filter": [
        {"term": {"available": true}},
        {"range": {"price": {"gte": 100, "lte": 500}}}
      ]
    }
  }
}
```

查询文本“无线键盘”会被当前 `standard` 分析器处理为“无”“线”“键”“盘”。`operator: "and"` 要求文档描述包含全部四个词元。

按照初始化数据逐步判断：

| 条件                    | 满足条件的文档                     |
| ----------------------- | ---------------------------------- |
| 描述包含全部查询词元    | `p1001`、`p1002`、`p1003`、`p1005` |
| `available` 等于 `true` | `p1001`～`p1005`                   |
| 价格位于 100～500 元    | `p1001`、`p1002`、`p1003`、`p1004` |
| 三个条件的交集          | `p1001`、`p1002`、`p1003`          |

因此最终返回 `p1001`、`p1002` 和 `p1003`。三条文档的 `_score` 都只来自 `must.match`；两个过滤条件不会增加分数。

`p1003` 带有 `discontinued` 标签，但题目没有要求排除停用商品，所以它仍会返回。如果业务同时要求排除停用商品，应在 `bool` 中增加：

```json
"must_not": [
  {"term": {"tags": "discontinued"}}
]
```

## 2. 为 `KeyWorks` 品牌加权，但不能排除其他品牌

品牌是偏好条件而不是硬性条件，应放在 `should` 中参与评分，并显式设置 `minimum_should_match: 0`：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name,hits.hits._source.brand
{
  "query": {
    "bool": {
      "must": [
        {
          "match": {
            "description": {
              "query": "无线键盘",
              "operator": "and"
            }
          }
        }
      ],
      "filter": [
        {"term": {"available": true}},
        {"range": {"price": {"gte": 100, "lte": 500}}}
      ],
      "should": [
        {"term": {"brand": {"value": "KeyWorks", "boost": 2}}}
      ],
      "minimum_should_match": 0
    }
  }
}
```

预期行为如下：

- `p1001` 和 `p1002` 的品牌都是 `KeyWorks`，会同时获得全文匹配分数和品牌加分。
- `p1003` 的品牌是 `GameType`，不会获得品牌加分，但仍满足 `must` 和 `filter`，所以不会被排除。
- `minimum_should_match: 0` 明确表示品牌条件可以一项都不满足。

不能把品牌条件放在 `filter` 中，因为那会直接排除其他品牌；也不能设置 `minimum_should_match: 1`，因为当前只有一个品牌 `should`，这样会使它从偏好条件变成必须条件。

确切 `_score` 取决于索引中的词项统计，不应在答案中写死。验收重点是 `p1001`、`p1002` 和 `p1003` 都保留，同时 `KeyWorks` 商品因品牌子句获得额外分数。

## 3. 说明过滤条件为什么通常不应放入 `must` 参与评分

查询“商品是否有货”和“价格是否位于指定范围”时，业务含义只有满足或不满足，不存在“更有货”或“更符合价格范围”的相关性程度。因此它们通常应该放在 `filter`：

```json
{
  "bool": {
    "must": [{ "match": { "description": "无线键盘" } }],
    "filter": [
      { "term": { "available": true } },
      { "range": { "price": { "gte": 100, "lte": 500 } } }
    ]
  }
}
```

如果把所有条件都放入 `must`：

```json
{
  "bool": {
    "must": [
      { "match": { "description": "无线键盘" } },
      { "term": { "available": true } },
      { "range": { "price": { "gte": 100, "lte": 500 } } }
    ]
  }
}
```

虽然两种写法可能返回相同的文档集合，但第二种写法会让结构化条件进入查询上下文。具体评分贡献取决于查询类型及其底层改写方式，这些贡献通常没有业务意义，还会干扰原本想表达的文本相关性。

使用 `filter` 的主要理由是：

1. `_score` 只反映真正需要排序的相关性条件，含义更清楚。
2. 过滤条件不执行相关性评分，可以减少不必要的评分工作。
3. 经常重复使用的过滤结果更有机会被 Elasticsearch 缓存。
4. 查询结构能明确区分“用于召回和排序的条件”与“绝对不能违反的业务约束”。

这不是说 `term`、`range` 永远不能放入 `must`。如果一个精确词项确实需要影响排序，例如品牌命中要提高分数，就可以放在 `must` 或 `should`；是否评分由业务语义决定，而不是由查询类型名称决定。

## 4. 对比 `minimum_should_match` 为 `0` 和 `1`

### 4.1 `minimum_should_match: 0`

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "query": {
    "bool": {
      "must": {
        "match": {"description": "无线 键盘"}
      },
      "should": [
        {"match_phrase": {"description": {"query": "无线 机械键盘", "slop": 1}}},
        {"term": {"brand": {"value": "KeyWorks", "boost": 2}}}
      ],
      "minimum_should_match": 0
    }
  }
}
```

`must.match` 使用默认 OR，初始化的五条文档都至少包含“线”“键”“盘”等部分查询词元，因此五条都会进入候选结果。两个 `should` 都是可选的，只负责加分：

| 文档    | 命中短语 `should` | 命中品牌 `should` | 是否返回 |
| ------- | ----------------- | ----------------- | -------- |
| `p1001` | 是                | 是                | 是       |
| `p1002` | 否                | 是                | 是       |
| `p1003` | 是                | 否                | 是       |
| `p1004` | 否                | 否                | 是       |
| `p1005` | 否                | 否                | 是       |

`p1001` 从两个 `should` 获得加分，`p1002` 和 `p1003` 各从一个 `should` 获得加分，`p1004` 和 `p1005` 只有 `must.match` 的基础分数。

### 4.2 `minimum_should_match: 1`

将同一个查询的最后一个参数改为：

```json
"minimum_should_match": 1
```

完整查询中的其他子句保持不变。此时文档除了满足 `must`，还必须至少命中一个 `should`：

| 文档    | 命中的 `should` 数量 | 是否返回 |
| ------- | -------------------: | -------- |
| `p1001` |                    2 | 是       |
| `p1002` |                    1 | 是       |
| `p1003` |                    1 | 是       |
| `p1004` |                    0 | 否       |
| `p1005` |                    0 | 否       |

结果集从五条缩小为 `p1001`、`p1002` 和 `p1003`。对于仍然返回的三条文档，评分子句没有变化，因此在索引状态不变时，它们的 `_score` 应与 `minimum_should_match: 0` 时相同；变化的是文档是否有资格进入结果集。

验收时应能说明：`minimum_should_match` 控制至少要满足多少个 `should`，而不是给 `should` 统一增加多少分。每个 `should` 的实际评分仍由其自身查询类型、字段统计和 boost 决定。
