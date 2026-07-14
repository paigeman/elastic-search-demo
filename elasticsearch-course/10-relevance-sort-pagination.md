# 10｜相关性、排序、分页与高亮

## 本节目标

- 理解 `_score` 的基本来源和相关性调优流程。
- 正确处理排序、浅分页和深分页。
- 使用高亮、字段裁剪和搜索超时。

## 1. 相关性基础

默认的 BM25 算法主要考虑词频、逆文档频率和字段长度。分数只在同一次查询及相同索引条件下有意义，不应把 `_score` 当作稳定的业务分值持久化。

调优顺序：

1. 先解决映射、分析器和数据质量问题。
2. 准备“查询 → 期望结果”的标注集。
3. 再调整字段权重、短语匹配和业务信号。
4. 对比离线指标和线上点击/转化，控制实验变量。

使用函数评分查询（`function_score`）加入库存与新鲜度因素：

```http
POST /products/_search
{
  "query": {
    "function_score": {
      "query": {"match": {"name": "键盘"}},
      "functions": [
        {"filter": {"range": {"stock": {"gt": 0}}}, "weight": 1.2},
        {"gauss": {"created_at": {"origin": "now", "scale": "30d", "decay": 0.5}}}
      ],
      "score_mode": "multiply",
      "boost_mode": "multiply"
    }
  }
}
```

## 2. 排序

```http
POST /products/_search
{
  "query": {"match": {"name": "键盘"}},
  "sort": [
    {"_score": "desc"},
    {"price": "asc"},
    {"product_id": "asc"}
  ]
}
```

最后放置唯一且稳定的字段作为平局裁决字段。排序字段必须具备合适的列式文档值（doc values）；不要为 `text` 字段开启字段数据（fielddata）来临时救急，应改用 `keyword` 子字段。

## 3. 分页

浅分页：

```http
POST /products/_search
{
  "from": 0,
  "size": 20,
  "query": {"match_all": {}},
  "sort": [{"created_at":"desc"},{"product_id":"asc"}]
}
```

`from + size` 越大，每个分片需要保留的候选结果就越多。交互式深分页应使用时间点视图（Point in Time，PIT）配合 `search_after`：

```http
POST /products/_pit?keep_alive=1m
```

得到 PIT 标识后：

```http
POST /_search
{
  "size": 100,
  "pit": {"id": "替换为PIT_ID", "keep_alive": "1m"},
  "sort": [{"created_at":"desc"},{"product_id":"asc"}]
}
```

下一页加入上一页最后一条的 `sort` 数组：

```json
"search_after": ["2026-07-01T08:00:00.000Z", "p1001"]
```

用完关闭：

```http
DELETE /_pit
{"id":"替换为PIT_ID"}
```

批量导出优先使用 PIT 与 `search_after`；滚动搜索（scroll）主要用于需要固定快照的既有批处理场景，不用于用户翻页。

## 4. 高亮与响应裁剪

```http
POST /products/_search
{
  "_source": ["product_id","name","price","stock"],
  "size": 10,
  "timeout": "2s",
  "query": {"match": {"description": "无线机械键盘"}},
  "highlight": {
    "fields": {"description": {"fragment_size": 80, "number_of_fragments": 2}}
  }
}
```

高亮片段用于展示前必须做 HTML 转义；不要信任源文档或高亮标签。

## 练习与验收

- 实现按相关性、价格、唯一标识的稳定排序。
- 用 PIT 和 `search_after` 连续获取两页且不重复。
- 只返回页面需要的 4 个字段，并为描述增加高亮。

上一节：[09｜查询语言](./09-query-dsl.md)｜下一节：[11｜聚合](./11-aggregations.md)
