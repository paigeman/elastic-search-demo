# 11｜聚合分析：练习与验收答案

建议先独立完成练习，再使用本页核对聚合请求、预期结果和误差含义。以下标记为 `http` 的请求都在 Kibana 的开发工具（Dev Tools）中的控制台（Console）执行，并假定已经按照正文开头的初始化脚本创建 `aggregation-products` 索引和 8 条实验数据。

开始前先确认数据数量：

```http
GET /aggregation-products/_count
```

预期返回 `"count": 8`。如果索引不存在或数量不是 8，应先重新执行第 11 章“操作环境与实验数据”中的初始化脚本。

## 1. 统计每个品牌的商品记录数、均价和总库存

使用 `terms` 按 `brand` 分桶，再在每个品牌桶中分别执行 `avg` 和 `sum`：

```http
POST /aggregation-products/_search?filter_path=aggregations.by_brand
{
  "size": 0,
  "aggs": {
    "by_brand": {
      "terms": {
        "field": "brand",
        "size": 20
      },
      "aggs": {
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
      }
    }
  }
}
```

题目没有要求只统计有货商品，因此上面的请求会处理全部 8 条文档，包括 `available` 为 `false` 的 `p2003` 和 `p2008`。预期结果如下：

| 品牌 | `doc_count` | `avg_price.value` | `total_stock.value` |
| --- | ---: | ---: | ---: |
| `KeyWorks` | 3 | 275.6666666666667 | 73 |
| `GameType` | 2 | 529 | 6 |
| `CablePro` | 1 | 79.9 | 50 |
| `DockPro` | 1 | 499 | 8 |
| `ErgoType` | 1 | 699 | 6 |

例如，`KeyWorks` 桶包含 `p2001`、`p2002` 和 `p2007`：

```text
商品记录数 = 3
平均价格 = (399 + 299 + 129) / 3 = 275.6666666666667
总库存 = 25 + 18 + 30 = 73
```

默认情况下，`terms` 先按 `doc_count` 从大到小排列；文档数相同的桶再按字段值确定顺序。因此验收重点是各桶的品牌、商品记录数和两个指标值，不要只检查桶在响应中的位置。

## 2. 按上海时区的自然日统计每天新建的商品记录数

基于本章 8 条实验数据，使用 `created_at` 建立日期直方图，并显式指定上海时区。这里统计的是每天新建的商品文档条数，不是把 `stock` 相加。统计范围为 2026 年 7 月 1 日至 5 日，其中没有新建商品记录的 7 月 4 日也需要作为空桶返回：

```http
POST /aggregation-products/_search?filter_path=aggregations.created_daily.buckets.key_as_string,aggregations.created_daily.buckets.doc_count
{
  "size": 0,
  "aggs": {
    "created_daily": {
      "date_histogram": {
        "field": "created_at",
        "calendar_interval": "day",
        "time_zone": "+08:00",
        "format": "yyyy-MM-dd",
        "min_doc_count": 0
      }
    }
  }
}
```

预期返回 5 个日期桶：

| 上海日期 | `doc_count` |
| --- | ---: |
| `2026-07-01` | 2 |
| `2026-07-02` | 2 |
| `2026-07-03` | 2 |
| `2026-07-04` | 0 |
| `2026-07-05` | 2 |

`calendar_interval: "day"` 表示按自然日分桶，`time_zone: "+08:00"` 表示使用上海时间的零点划分日期。`min_doc_count: 0` 会保留数据时间范围内的空桶，因此 7 月 4 日虽然没有新建商品记录，仍会出现在响应中。

验收时应检查日期边界和每天的文档数，而不只是桶的总数。如果省略 `time_zone`，Elasticsearch 默认使用 UTC 日期边界；靠近 UTC 零点的数据可能因此被分到与上海自然日不同的桶中。

## 3. 解释 `doc_count_error_upper_bound` 和基数聚合的近似性

### 3.1 `terms` 的 `doc_count_error_upper_bound`

在多分片索引中，`terms` 聚合不会让每个分片把所有字段值及其文档数都发送给协调节点。每个分片只返回由 `shard_size` 控制的一部分候选桶，协调节点再合并各分片的候选结果。

某个字段值可能在整个索引中出现很多次，却在某个分片内没有排进候选列表。该分片不会上报这个桶的局部文档数，协调节点也就无法把这部分计入最终结果，所以返回桶的 `doc_count` 可能偏小。`doc_count_error_upper_bound` 在可以计算误差上限时，表示返回桶的文档数最多可能漏算多少：

- 值为 `0`：没有这类潜在漏算。
- 值大于 `0`：返回的 `doc_count` 可能少算，但漏算数量不超过该上限。

增大 `shard_size` 会让每个分片上报更多候选桶，通常可以降低误差，而且一般比直接大幅增大 `size` 更合适；代价是增加分片到协调节点的传输量和协调节点的内存开销。第 11 章实验索引只有一个分片，因此通常不会出现由跨分片候选桶合并造成的误差。

`doc_count_error_upper_bound` 也不表示有多少文档属于未返回的其他桶。后者由响应中的 `sum_other_doc_count` 表示，两者不能混为一谈。

### 3.2 `cardinality` 为什么是近似值

如果要绝对精确地统计唯一值，节点需要保存已经见过的全部不同值，并在分片之间传输、合并这些集合。字段基数很高或数据量很大时，这种做法会消耗大量内存和网络资源。

`cardinality` 聚合使用 HyperLogLog++ 算法，根据字段值的哈希摘要估算不同值数量，而不是保存完整的唯一值集合。因此它的内存开销主要由精度配置决定，不会随着唯一值数量等比例增长，但结果可能存在小幅误差。

`precision_threshold` 用于在准确性和内存之间取舍：

- 提高该值通常可以提高阈值附近统计的准确性，但会使用更多内存。
- 它不是“误差率”，也不保证结果绝对精确。
- 本章只有 5 个不同品牌，因此通常会得到 `5`，但不能据此认为大规模数据中的结果也一定精确。

验收时应能说明两种近似性的来源不同：`terms` 的计数误差来自多分片候选桶的裁剪和合并；`cardinality` 的误差来自为控制内存而使用的概率估算算法。需要绝对精确的业务报表，应先明确可接受误差，必要时改用离线精确计算。
