# 10｜相关性、排序、分页与高亮：练习与验收答案

建议先独立完成练习，再使用本页核对查询结构、分页游标和响应字段。以下标记为 `http` 的请求都在 Kibana 的开发工具（Dev Tools）中的控制台（Console）执行，并假定已经按照第 09 章的初始化脚本创建 `query-dsl-products` 索引和 5 条实验数据。

开始前先确认数据数量：

```http
GET /query-dsl-products/_count
```

预期返回 `"count": 5`。如果索引不存在或数量不是 5，应先重新执行第 09 章“操作环境与实验数据”中的初始化脚本。

## 1. 实现按相关性、价格、唯一标识的稳定排序

下面的查询先按 `_score` 从高到低排列；当相关性分数相同时，再按价格从低到高排列；如果分数和价格都相同，最后按唯一的 `product_id` 从小到大排列：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits.sort,hits.hits._source
{
  "_source": ["product_id","name","price"],
  "query": {
    "match": {
      "description": {
        "query": "无线键盘",
        "operator": "and"
      }
    }
  },
  "sort": [
    {"_score": "desc"},
    {"price": "asc"},
    {"product_id": "asc"}
  ]
}
```

排序规则按数组顺序逐级生效，不是三个字段各自独立排序：

| 优先级 | 排序项           | 作用                                     |
| -----: | ---------------- | ---------------------------------------- |
|      1 | `_score desc`    | 相关性更高的文档优先                     |
|      2 | `price asc`      | 只在 `_score` 相同时让低价文档优先       |
|      3 | `product_id asc` | 只在 `_score` 和价格都相同时确定唯一顺序 |

按照初始化数据，查询应命中 `p1001`、`p1002`、`p1003` 和 `p1005`。确切的 `_score` 及最终先后顺序取决于 BM25 计算相关性时使用的统计信息，不应写死；验收时应检查每条命中的 `sort` 数组是否依次包含分数、价格和商品编号。

要理解这些统计信息，先要知道 Elasticsearch 并不是直接拿整段原文计算匹配程度。写入和查询 `text` 字段时，分析器会先把文本拆成一个个可参与匹配的单位。分析过程中产生的单位称为“词元”（token）；词元写入倒排索引后，作为检索单位时通常称为“词项”（term）。例如，本章的 `standard` 分析器会把查询文本“无线键盘”处理成“无”“线”“键”“盘”等词元，这些值随后作为词项到倒排索引中查找文档。

BM25 会利用这些检索单位及字段的统计信息计算 `_score`，主要包括：

- 词频：某个查询词项在当前文档的 `description` 中出现多少次；出现次数越多，通常贡献越大，但 BM25 会让增加的贡献逐渐趋于饱和。
- 文档频率：索引或当前参与评分的分片中有多少篇文档包含该词项；包含它的文档越少，该词项通常越能区分结果，权重也越高。
- 字段长度：当前文档的 `description` 有多长，以及它与平均字段长度的关系；在其他条件相近时，查询词出现在较短字段中通常更突出。

因此，即使查询语句不变，增加或删除文档也可能改变“某个词项出现在多少篇文档中”等统计信息，从而改变 `_score`。不同命中文档的描述长度和词项出现次数也可能不同，所以答案只固定排序规则，不固定具体分数。

`product_id` 在第 09 章映射中是启用 doc values 的 `keyword`，并且每条实验数据的值唯一，因此适合作为平局裁决字段。仅使用 `_score` 和 `price` 时，如果两条文档的两个值都相同，它们的相对顺序可能不稳定。

## 2. 使用 PIT 和 `search_after` 连续获取两页且不重复

### 2.1 创建 PIT

```http
POST /query-dsl-products/_pit?keep_alive=1m
```

保存响应中的 `id`。该 PIT 固定的是创建时 `query-dsl-products` 的数据视图，不包含查询条件。

### 2.2 获取第 1 页

```http
POST /_search?filter_path=pit_id,hits.hits._id,hits.hits.sort
{
  "_source": false,
  "size": 2,
  "pit": {
    "id": "替换为创建PIT时返回的id",
    "keep_alive": "1m"
  },
  "query": {"match_all": {}},
  "sort": [
    {
      "created_at": {
        "order": "desc",
        "format": "strict_date_optional_time"
      }
    },
    {"product_id": "asc"}
  ]
}
```

这里的 `"_source": false` 不是“不要查询文档”，也不会让命中数量变成 0。`_source` 保存的是写入文档时的原始 JSON 业务内容；设为 `false` 只表示每条命中的响应里不返回这部分内容。查询仍会正常匹配和排序文档，并返回本题需要的 `_id` 与 `sort` 数组。

本题只需要用 `_id` 检查两页是否重复，并用 `sort` 生成下一页游标，不需要商品名称、价格等完整业务数据，所以关闭 `_source` 可以减少不必要的取回和响应内容。请求地址中的 `filter_path` 只决定最终 JSON 保留哪些路径；`_source: false` 则明确告诉搜索 API 不需要返回源文档，两者不能互相替代。

如果实际页面还要展示商品信息，可以删除 `"_source": false`，或者改为只返回所需字段：

```json
"_source": ["product_id", "name", "price"]
```

预期第 1 页依次返回 `p1005`、`p1004`。每条命中的 `sort` 数组包含三个值：

1. `created_at` 的排序值；
2. `product_id` 的排序值；
3. PIT 自动加入的 `_shard_doc` 平局裁决值。

响应结构类似：

```json
{
  "pit_id": "第1页响应返回的最新PIT_ID",
  "hits": {
    "hits": [
      {
        "_id": "p1005",
        "sort": ["2026-07-15T12:00:00.000Z", "p1005", 4]
      },
      {
        "_id": "p1004",
        "sort": ["2026-07-12T11:00:00.000Z", "p1004", 3]
      }
    ]
  }
}
```

上面的 `_shard_doc` 数字只是结构示例，实际值可能不同。后续请求不得照抄示例数字，必须复制自己第 1 页响应中最后一条命中的完整 `sort` 数组。

### 2.3 获取第 2 页

假设实际响应中 `p1004` 的完整排序数组确实是：

```json
["2026-07-12T11:00:00.000Z", "p1004", 3]
```

则第 2 页请求为：

```http
POST /_search?filter_path=pit_id,hits.hits._id,hits.hits.sort
{
  "_source": false,
  "size": 2,
  "pit": {
    "id": "替换为第1页响应中的最新pit_id",
    "keep_alive": "1m"
  },
  "query": {"match_all": {}},
  "sort": [
    {
      "created_at": {
        "order": "desc",
        "format": "strict_date_optional_time"
      }
    },
    {"product_id": "asc"}
  ],
  "search_after": ["2026-07-12T11:00:00.000Z", "p1004", 3]
}
```

如果实际 `sort` 数组中的日期格式、商品编号或最后一个数字不同，应使用实际数组替换整个 `search_after`。`query` 和 `sort` 必须与第 1 页完全相同。

预期第 2 页依次返回 `p1003`、`p1002`：

```text
第 1 页 ID 集合：p1005、p1004
第 2 页 ID 集合：p1003、p1002
两页交集：空集
```

这证明前两页没有重复。若继续以第 2 页最后一条的 `sort` 请求第 3 页，应只返回 `p1001`。

### 2.4 关闭 PIT

分页结束后，使用最近一次搜索响应中的 `pit_id` 主动关闭 PIT：

```http
DELETE /_pit
{
  "id": "替换为最近一次响应中的pit_id"
}
```

若不显式关闭，PIT 也会在最后一次续期的 `keep_alive` 到期后自动关闭；生产代码主动关闭可以更早释放相关资源。

## 3. 只返回 `product_id`、`name`、`price`、`stock`，并为 `description` 增加高亮

下面的请求使用 `_source` 过滤，让每条命中只返回 `product_id`、`name`、`price` 和 `stock`；`description` 不出现在 `_source` 中，但仍用于查询并通过独立的 `highlight.description` 返回高亮片段：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._source,hits.hits.highlight
{
  "_source": ["product_id","name","price","stock"],
  "size": 10,
  "timeout": "2s",
  "query": {
    "match": {
      "description": {
        "query": "无线机械键盘",
        "operator": "and"
      }
    }
  },
  "highlight": {
    "fields": {
      "description": {
        "fragment_size": 80,
        "number_of_fragments": 2
      }
    }
  }
}
```

按照初始化数据，查询应命中 `p1001` 和 `p1003`。验收每条命中时检查：

1. `_source` 只包含 `product_id`、`name`、`price`、`stock` 四个字段；
2. `_source` 中没有完整的 `description`；
3. `highlight.description` 是数组，最多包含两个片段；
4. 每个片段的目标长度为 80 个字符，实际长度可能因词语或句子边界而略有不同；
5. 实际命中的词元默认由 `<em>` 和 `</em>` 包裹，具体标签位置取决于分析器产生的词元和匹配偏移量，不应写死。

这里同时使用 `_source` 和 `filter_path`，但它们职责不同：`_source` 选择每条命中的业务字段；`filter_path` 只保留整个响应中的 `_id`、`_source` 和 `highlight` 路径。删除 `filter_path` 不会改变命中文档或 `_source` 的四字段过滤，只会让 `took`、`_shards`、`hits.total` 等其他响应结构重新显示。
