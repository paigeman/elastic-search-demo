# 11｜聚合分析

## 本节目标

- 掌握桶聚合、指标聚合和管道聚合。
- 构建类目、价格和时间分析。
- 识别高基数、精度和内存风险。

## 1. 类目与指标聚合

```http
POST /products/_search
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
            "_source": ["product_id","name","price"],
            "sort": [{"stock":"desc"}]
          }
        }
      }
    }
  }
}
```

`size: 0` 表示只需要聚合结果，不返回普通命中文档。`terms` 只返回排名靠前的桶，不是分页取得所有唯一值的可靠方式。

## 2. 范围与日期直方图

```http
POST /products/_search
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

业务按自然日统计要显式设置 `time_zone`。固定 24 小时用 `fixed_interval`，日/月这类日历边界用 `calendar_interval`。

## 3. 基数和百分位是近似值

```http
POST /products/_search
{
  "size": 0,
  "aggs": {
    "unique_brands": {"cardinality": {"field": "brand", "precision_threshold": 1000}},
    "price_percentiles": {"percentiles": {"field": "price", "percents": [50, 95, 99]}}
  }
}
```

基数聚合（cardinality）与百分位聚合（percentiles）为节省内存而使用近似算法。报表需要绝对精确时，应明确误差是否可接受，或改用离线计算。

## 4. 管道聚合

```http
POST /products/_search
{
  "size": 0,
  "aggs": {
    "daily": {
      "date_histogram": {"field":"created_at","calendar_interval":"day"},
      "aggs": {
        "stock_sum": {"sum":{"field":"stock"}},
        "stock_change": {"derivative":{"buckets_path":"stock_sum"}}
      }
    }
  }
}
```

管道聚合基于其他桶的输出继续计算，不会重新读取原始文档。

## 5. 大聚合风险

- 高基数字段的大 `terms.size` 会占用协调节点和数据节点内存。
- 需要遍历全部桶时，使用复合聚合（composite aggregation）分页。
- 限制用户可选字段、桶数量、时间范围和请求超时。
- 监控熔断器、被拒绝的搜索请求和垃圾回收，不要只看 HTTP 请求是否成功。
- Kibana 仪表盘的多个面板可能同时发出多条昂贵查询。

## 练习与验收

- 统计每个品牌的商品数、均价和总库存。
- 按上海时区统计每天新增商品。
- 说明为什么需要关注 `terms` 的 `doc_count_error_upper_bound` 以及基数聚合的近似性。

上一节：[10｜相关性与分页](./10-relevance-sort-pagination.md)｜下一节：[12｜数据接入](./12-data-ingestion.md)
