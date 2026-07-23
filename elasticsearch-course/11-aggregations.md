# 11｜聚合分析

## 本节目标

- 掌握桶聚合、指标聚合和管道聚合。
- 构建类目、价格和时间分析。
- 识别高基数、精度和内存风险。

## 操作环境与实验数据

本章所有请求都在 Kibana 的“开发工具（Dev Tools）→ Console”中执行。为了不依赖前面章节执行后的索引状态，本章使用独立的 `aggregation-products` 索引。

下面的初始化脚本会删除并重建 `aggregation-products`。它只用于课程实验，不要把索引名替换成需要保留数据的业务索引。

### 1. 创建索引并声明字段类型

下面是两个完整请求，可以按顺序在 Console 中执行：

```http
DELETE /aggregation-products?ignore_unavailable=true

PUT /aggregation-products
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
      "category": {"type": "keyword"},
      "brand": {"type": "keyword"},
      "price": {"type": "scaled_float", "scaling_factor": 100},
      "stock": {"type": "integer"},
      "available": {"type": "boolean"},
      "created_at": {"type": "date"}
    }
  }
}
```

各字段的用途和类型如下：

| 字段 | 类型 | 本章用途 | 为什么使用该类型 |
| --- | --- | --- | --- |
| `product_id` | `keyword` | 商品业务编号 | 完整值标识，不需要分词 |
| `name` | `text` | 在 `top_hits` 中展示商品名称 | 商品名称可以用于全文检索，本章不使用它进行聚合 |
| `category` | `keyword` | 按类目执行 `terms` 聚合 | 聚合需要使用未分词的完整类目值 |
| `brand` | `keyword` | 按品牌统计和计算品牌基数 | 聚合需要使用未分词的完整品牌值 |
| `price` | `scaled_float` | 平均值、范围和百分位统计 | 按分保存两位小数，同时可以执行数值聚合 |
| `stock` | `integer` | 总库存、库存排序和库存变化 | 库存是整数，可以执行数值聚合和排序 |
| `available` | `boolean` | 过滤有货商品 | 值只有 `true` 和 `false` |
| `created_at` | `date` | 按天分桶 | 日期字段支持日期范围和日期直方图聚合 |

这里使用 `dynamic: "strict"`，如果样例文档中出现映射没有声明的字段，写入会直接失败。这样可以尽早发现字段名拼错或初始化脚本与映射不一致的问题。

### 2. 写入八条实验数据

下面是一个完整的 Bulk 请求，可以直接在 Console 中执行：

```http
POST /aggregation-products/_bulk?refresh=wait_for&filter_path=errors,items.*.status
{"index":{"_id":"p2001"}}
{"product_id":"p2001","name":"机械键盘 K8","category":"keyboard","brand":"KeyWorks","price":399.0,"stock":25,"available":true,"created_at":"2026-07-01T08:00:00Z"}
{"index":{"_id":"p2002"}}
{"product_id":"p2002","name":"无线办公键盘","category":"keyboard","brand":"KeyWorks","price":299.0,"stock":18,"available":true,"created_at":"2026-07-01T14:00:00Z"}
{"index":{"_id":"p2003"}}
{"product_id":"p2003","name":"无线游戏键盘","category":"keyboard","brand":"GameType","price":459.0,"stock":2,"available":false,"created_at":"2026-07-02T02:00:00Z"}
{"index":{"_id":"p2004"}}
{"product_id":"p2004","name":"USB-C 扩展坞","category":"accessory","brand":"DockPro","price":499.0,"stock":8,"available":true,"created_at":"2026-07-02T10:00:00Z"}
{"index":{"_id":"p2005"}}
{"product_id":"p2005","name":"人体工学键盘","category":"keyboard","brand":"ErgoType","price":699.0,"stock":6,"available":true,"created_at":"2026-07-03T02:00:00Z"}
{"index":{"_id":"p2006"}}
{"product_id":"p2006","name":"USB-C 数据线","category":"accessory","brand":"CablePro","price":79.9,"stock":50,"available":true,"created_at":"2026-07-03T10:00:00Z"}
{"index":{"_id":"p2007"}}
{"product_id":"p2007","name":"人体工学鼠标","category":"mouse","brand":"KeyWorks","price":129.0,"stock":30,"available":true,"created_at":"2026-07-05T03:00:00Z"}
{"index":{"_id":"p2008"}}
{"product_id":"p2008","name":"无线游戏鼠标","category":"mouse","brand":"GameType","price":599.0,"stock":4,"available":false,"created_at":"2026-07-05T08:00:00Z"}
```

Bulk 请求整体成功时，HTTP 状态通常是 `200 OK`；响应中每个 `index.status` 则表示对应那一条文档操作的结果。这里刚刚重建了空索引，八个 `_id` 都不存在，因此每条 `index` 操作都是创建新文档，状态应为 `201 Created`。如果不重建索引而再次执行相同的 Bulk 请求，`index` 操作会覆盖同 `_id` 的已有文档，对应状态通常会变成 `200 OK`。

本次 Bulk 响应中的 `errors` 应为 `false`，每个 `index.status` 应为 `201`。`refresh=wait_for` 会等待本次写入对搜索可见，因此不需要再手动刷新索引。

### 3. 验证初始化结果

下面是两个完整请求，分别用于检查文档数量和字段映射：

```http
GET /aggregation-products/_count

GET /aggregation-products/_mapping?filter_path=*.mappings.properties
```

第一个请求的 `count` 应为 `8`。第二个请求用于核对实际映射；应能看到建索引请求中声明的八个字段及其类型。如果结果不同，先重新执行本节的删除、创建和 Bulk 写入请求，再继续后面的实验。

## 1. 类目与指标聚合

聚合可以理解为对搜索结果进行“分组统计”，类似 SQL 中的 `GROUP BY`，也类似 Excel 的数据透视表。

初始化完成后，`aggregation-products` 索引中已经保存了下面这些字段：

- `available`：商品是否有货。
- `category`：商品类目，本章样例值为 `keyboard`、`accessory` 和 `mouse`。
- `price`：商品价格。
- `stock`：商品库存。

现在要完成一个商品统计报表：

1. 只统计有货的商品。
2. 按商品类目分组。
3. 计算每个类目的商品数量、平均价格和总库存。
4. 找出每个类目中库存最多的 3 件商品。

对应的查询如下：

下面是一个完整请求，可以直接在 Console 中执行：

```http
POST /aggregation-products/_search
{
  "size": 0,
  "query": {"term": {"available": true}},
  "aggs": {
    "by_category": {
      "terms": {"field": "category", "size": 20},
      "aggs": {
        "avg_price": {"avg": {"field": "price"}},
        "total_stock": {"sum": {"field": "stock"}},
        "top_products": {
          "top_hits": {
            "size": 3,
            "_source": ["product_id","name","price","stock"],
            "sort": [{"stock":"desc"}]
          }
        }
      }
    }
  }
}
```

### 1.1 查询的执行顺序

这段查询不是同时做完所有事情，而是按照下面的顺序执行：

下面是流程示意，不是 Elasticsearch 请求：

```text
aggregation-products 中的全部商品
        ↓ query：只保留 available = true 的商品
        ↓ terms：按照 category 分组
        ├─ keyboard 类目
        │    ├─ avg：计算平均价格
        │    ├─ sum：计算总库存
        │    └─ top_hits：取库存最多的 3 件商品
        ├─ accessory 类目
        │    └─ 执行相同的统计
        └─ mouse 类目
             └─ 执行相同的统计
```

其中，`terms` 创建出来的每个分组称为一个**桶（bucket）**。例如，`keyboard` 是一个桶，`accessory` 是另一个桶。桶中的 `doc_count` 就是该类目的商品数量。

### 1.2 逐段理解查询

本小节中的代码块都是从前面完整查询中截取的讲解片段，不能单独复制到 Console 执行。

第一步，只统计有货商品：

```json
"query": {
  "term": {
    "available": true
  }
}
```

`term` 查询进行精确匹配，这里表示只保留 `available` 等于 `true` 的文档。后面的所有聚合都只会处理这些文档。

第二步，按照商品类目分组：

```json
"by_category": {
  "terms": {
    "field": "category",
    "size": 20
  }
}
```

`by_category` 是自定义的聚合名称，可以换成其他易懂的名字。`terms` 表示按照字段值分桶，`size: 20` 表示最多返回商品数量排名靠前的 20 个类目。

用于 `terms` 分组的字段通常应为 `keyword` 类型。如果 `category` 是 `text` 类型，一般应改用它的 `keyword` 子字段，例如 `category.keyword`。

第三步，在每个类目内部继续计算指标：

```json
"avg_price": {
  "avg": {
    "field": "price"
  }
},
"total_stock": {
  "sum": {
    "field": "stock"
  }
}
```

- `avg_price` 使用 `avg` 计算当前类目的平均价格。
- `total_stock` 使用 `sum` 计算当前类目的库存总量。

这两个聚合写在 `by_category.aggs` 内部，因此它们不是计算所有商品的整体平均值和总库存，而是分别对每个类目计算。

第四步，取出每个类目中库存最多的 3 件商品：

```json
"top_products": {
  "top_hits": {
    "size": 3,
    "_source": ["product_id", "name", "price", "stock"],
    "sort": [
      {"stock": "desc"}
    ]
  }
}
```

`top_hits` 用来从当前桶中取出具体文档。这里先按 `stock` 从大到小排序，再返回前 3 件商品。`_source` 限制了返回字段，避免把完整商品文档全部传回来。

### 1.3 三个 `size` 不要混淆

查询中出现了三个 `size`，它们控制的对象不同：

| 位置 | 含义 |
| --- | --- |
| 搜索请求最外层的 `"size": 0` | 不返回普通搜索命中文档，只返回聚合统计结果 |
| `terms` 中的 `"size": 20` | 最多返回 20 个类目桶 |
| `top_hits` 中的 `"size": 3` | 每个类目最多返回 3 件具体商品 |

### 1.4 如何阅读返回结果

执行完整查询后，`keyboard` 桶的结果可以简化为如下结构。下面是简化响应，不是可执行请求：

```json
{
  "aggregations": {
    "by_category": {
      "buckets": [
        {
          "key": "keyboard",
          "doc_count": 3,
          "avg_price": {
            "value": 465.6666666666667
          },
          "total_stock": {
            "value": 49.0
          },
          "top_products": {
            "hits": {
              "hits": [
                {
                  "_source": {
                    "product_id": "p2001",
                    "name": "机械键盘 K8",
                    "price": 399.0,
                    "stock": 25
                  }
                }
              ]
            }
          }
        }
      ]
    }
  }
}
```

为了突出返回结构，上面的简化响应只展示了 `top_products.hits.hits` 中的第一件商品；实际执行完整查询会返回该桶中按库存排序后的最多三件商品。

这段结果可以读成：

- `key: "keyboard"`：当前统计的是键盘类目。
- `doc_count: 3`：有 3 件 `available` 为 `true` 的键盘商品；`p2003` 无货，因此没有参与本次聚合。
- `avg_price.value`：三件有货键盘的平均价格，即 `(399 + 299 + 699) / 3`。
- `total_stock.value: 49.0`：三件有货键盘的库存总量，即 `25 + 18 + 6`。
- `top_products.hits.hits`：按库存从大到小排列的三件键盘，依次为 `p2001`、`p2002` 和 `p2005`。

这一节先记住两个核心概念即可：

- **桶聚合**负责分组，例如 `terms` 按类目分组。
- **指标聚合**负责计算，例如 `avg` 计算平均值、`sum` 计算总和。

`terms` 聚合中的 term 指用于分桶的字段值，例如 `brand` 字段中的 `KeyWorks`，不一定是自然语言中的词。在多分片索引中，为了避免传输和保存所有桶，每个分片只向协调节点返回排名靠前的一部分候选桶，再由协调节点合并结果。某个字段值可能在所有分片上的文档总数很多，却在部分分片内没有进入候选列表；协调节点看不到这些被省略的局部统计，只能用收到的数据计算，因此该桶的 `doc_count` 可能偏小，而不是绝对精确值。响应中的 `doc_count_error_upper_bound` 表示返回桶的文档数最多可能漏算多少；值为 `0` 表示没有这类潜在漏算。增大 `shard_size` 可以让每个分片返回更多候选桶，通常能提高准确性，但也会增加节点间传输量和内存开销。本章实验索引只有一个分片，结果通常不会出现由跨分片候选桶合并造成的误差。

需要注意：`terms` 默认优先返回文档数量较多的桶。即使调大 `size`，它也不适合可靠地分页取得所有唯一类目；需要遍历全部桶时，应使用第 5 节提到的复合聚合。

## 2. 范围与日期直方图

下面是一个完整请求，可以直接在 Console 中执行：

```http
POST /aggregation-products/_search
{
  "size": 0,
  "aggs": {
    "price_ranges": {
      "range": {
        "field": "price",
        "ranges": [
          {"to": 100},
          {"from": 100, "to": 500},
          {"from": 500}
        ]
      }
    },
    "created_daily": {
      "date_histogram": {
        "field": "created_at",
        "calendar_interval": "day",
        "time_zone": "+08:00",
        "min_doc_count": 0
      }
    }
  }
}
```

这里使用的是 `range` 聚合，`ranges` 数组中的每个对象定义一个价格区间。每个区间的 `from` 包含边界值，`to` 不包含边界值，因此三个价格桶分别表示 `price < 100`、`100 <= price < 500` 和 `price >= 500`。按初始化数据，它们的 `doc_count` 应分别为 `1`、`5` 和 `2`。

业务按自然日统计时，需要同时看 `calendar_interval` 和 `time_zone`。这里的 `calendar_interval: "day"` 表示按自然日建立桶，`time_zone: "+08:00"` 表示以东八区的本地零点作为每天的分界线；如果不设置 `time_zone`，默认会按 UTC 的日期边界分桶。两项配置共同作用后，应返回上海时间 7 月 1 日到 7 月 5 日的五个桶，对应的 `doc_count` 依次为 `2`、`2`、`2`、`0`、`2`。7 月 4 日没有商品，但因为 `min_doc_count: 0`，仍会返回一个空桶。固定 24 小时用 `fixed_interval`，日/月这类日历边界用 `calendar_interval`。

## 3. 基数和百分位是近似值

下面是一个完整请求，可以直接在 Console 中执行：

```http
POST /aggregation-products/_search
{
  "size": 0,
  "aggs": {
    "unique_brands": {"cardinality": {"field": "brand", "precision_threshold": 1000}},
    "price_percentiles": {"percentiles": {"field": "price", "percents": [50, 95, 99]}}
  }
}
```

这两个聚合回答的问题不同：

- `unique_brands` 使用基数聚合（`cardinality`）估算 `brand` 字段有多少个不同值，作用类似 SQL 的 `COUNT(DISTINCT brand)`。样例数据中共有 `KeyWorks`、`GameType`、`DockPro`、`ErgoType` 和 `CablePro` 五个不同品牌，因此结果中的 `unique_brands.value` 通常为 `5`。`precision_threshold` 用于在统计精度与内存开销之间取舍，不表示结果一定绝对精确。
- `price_percentiles` 使用百分位聚合（`percentiles`）观察价格分布。`P50` 表示大约 50% 的商品价格不高于该值，通常也称为中位数；`P95` 表示大约 95% 的商品价格不高于该值；`P99` 常用于观察接近价格高端的位置。百分位不是平均价格，例如少量高价商品可能明显提高平均值，但不一定同样明显地改变 `P50`。

基数聚合与百分位聚合为节省内存而使用近似算法。数据量很小时结果通常符合直观计算，但不能据此认为它们对任意规模的数据都绝对精确。报表需要绝对精确时，应明确误差是否可接受，或改用离线计算。

## 4. 管道聚合

下面是一个完整请求，可以直接在 Console 中执行：

```http
POST /aggregation-products/_search
{
  "size": 0,
  "aggs": {
    "daily": {
      "date_histogram": {
        "field": "created_at",
        "calendar_interval": "day",
        "time_zone": "+08:00",
        "min_doc_count": 0
      },
      "aggs": {
        "stock_sum": {"sum": {"field": "stock"}},
        "stock_change": {"derivative": {"buckets_path": "stock_sum"}}
      }
    }
  }
}
```

管道聚合基于其他聚合的输出继续计算，不会重新读取原始文档。这里的计算分为两步：

1. `date_histogram` 按 `created_at` 将商品文档分到每天的桶中，`stock_sum` 再计算每个桶内所有商品的 `stock` 之和。
2. `stock_change` 使用 `derivative` 计算相邻日期桶之间的变化量；`buckets_path: "stock_sum"` 表示它读取 `stock_sum` 的结果。计算公式是“当前桶的 `stock_sum` 减去前一个桶的 `stock_sum`”。

第一个日期桶没有前一个桶可比较，因此响应中不会为它生成 `stock_change`。例如，7 月 2 日的 `stock_sum` 是 `10`，前一天是 `43`，所以 `stock_change.value` 为 `10 - 43 = -33`。

按初始化数据，结果应符合下面的计算：

| 上海日期 | `stock_sum.value` | `stock_change.value` |
| --- | ---: | ---: |
| 7 月 1 日 | 43 | 无 |
| 7 月 2 日 | 10 | -33 |
| 7 月 3 日 | 56 | 46 |
| 7 月 4 日 | 0 | -56 |
| 7 月 5 日 | 34 | 34 |

例如，7 月 3 日的 `46` 来自 `56 - 10`。7 月 4 日虽然没有文档，日期直方图仍生成空桶，`sum` 在该桶中的结果为 `0`，所以当天相对前一天的变化是 `0 - 56 = -56`。

### 4.1 不要把示例结果误认为真实库存变化

这个示例主要用于演示 `derivative` 如何读取前一个桶的指标并计算差值。由于日期直方图使用的是商品创建时间 `created_at`，所以它实际计算的是：

```text
按创建日期对商品分组
    ↓
计算每组商品当前 stock 的合计
    ↓
比较相邻创建日期分组的合计差值
```

因此，`stock_change: -33` 的准确含义是“7 月 2 日创建的商品，其当前库存合计比 7 月 1 日创建的商品少 33”，而不是“整个商品库在 7 月 2 日减少了 33 件库存”。

例如，`p2001` 在 7 月 1 日创建，当前 `stock` 是 `25`。如果后来卖出 5 件并把该文档的 `stock` 更新为 `20`，重新执行聚合时，7 月 1 日桶的 `stock_sum` 也会减少 5。Elasticsearch 无法从这份商品文档判断这 5 件库存是哪一天减少的，因为文档中没有保存库存变动时间。

如果业务需要统计真实的每日库存变化，应另外保存带时间的库存数据，例如：

- 库存事件：记录 `changed_at` 和 `stock_delta`，例如某次入库 `+10`、某次销售 `-5`。
- 每日快照：记录 `snapshot_date` 和当天的 `total_stock`。

然后再按照 `changed_at` 或 `snapshot_date` 建立日期桶并进行聚合。商品主数据中的 `created_at` 和当前 `stock` 不能还原历史库存变化。

## 5. 大聚合风险

聚合是否昂贵，不只取决于命中文档数量，还取决于最终需要创建和合并多少个桶。多层桶聚合可能使桶数量成倍增长，例如依次按照“类目、品牌、日期”分桶时，每个上层桶都可能继续产生一批下层桶，进而消耗数据节点和协调节点的内存，并可能触发 `search.max_buckets` 限制或熔断器。

- 高基数字段的大 `terms.size` 会占用协调节点和数据节点内存。
- 需要遍历全部桶时，使用复合聚合（composite aggregation）并通过 `after_key` 分页；复合聚合本身也可能昂贵，上线前仍需压测。
- 限制用户可选字段、桶数量、时间范围和请求超时。
- 监控熔断器、被拒绝的搜索请求和垃圾回收，不要只看 HTTP 请求是否成功。
- Kibana 仪表盘的多个面板可能同时发出多条昂贵查询。

## 练习与验收

- 统计每个品牌的商品记录数、均价和总库存。
- 基于本章 8 条实验数据，使用 `created_at` 按上海时区的自然日统计 2026 年 7 月 1 日至 5 日每天新建的商品记录数，并让没有新建商品记录的 7 月 4 日也返回 `doc_count: 0`；这里统计文档条数，不对 `stock` 求和。
- 说明为什么需要关注 `terms` 的 `doc_count_error_upper_bound` 以及基数聚合的近似性。

上一节：[10｜相关性与分页](./10-relevance-sort-pagination.md)｜下一节：[12｜数据接入](./12-data-ingestion.md)
