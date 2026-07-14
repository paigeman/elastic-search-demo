# 09｜查询语言与全文检索

## 本节目标

- 区分查询上下文（query context）和过滤上下文（filter context）。
- 熟练组合布尔查询、词项级查询和全文查询。
- 写出可解释、可维护的业务查询。

## 1. 查询与过滤

- 查询上下文判断“匹配程度”，计算 `_score`，适合全文相关性搜索。
- 过滤上下文判断“是否满足条件”，不参与评分，适合状态、类目、范围、权限等条件，也更有机会被缓存。

商品搜索示例：

```http
POST /products/_search
{
  "query": {
    "bool": {
      "must": [
        {"match": {"name": {"query": "无线 键盘", "operator": "and"}}}
      ],
      "filter": [
        {"term": {"available": true}},
        {"term": {"category": "keyboard"}},
        {"range": {"price": {"gte": 100, "lte": 500}}}
      ],
      "must_not": [
        {"term": {"tags": "discontinued"}}
      ]
    }
  }
}
```

## 2. 词项级查询

```http
POST /products/_search
{
  "query": {
    "bool": {
      "filter": [
        {"terms": {"brand": ["KeyWorks", "DockPro"]}},
        {"exists": {"field": "stock"}},
        {"range": {"created_at": {"gte": "now-30d/d", "lt": "now+1d/d"}}}
      ]
    }
  }
}
```

不要用 `term` 查询分析过的 `text` 字段来猜测词元；精确匹配应查询 `.keyword` 子字段或明确的 `keyword` 字段。

## 3. 全文查询

### 单字段匹配与多字段匹配

```http
POST /products/_search
{
  "query": {
    "multi_match": {
      "query": "无线机械键盘",
      "fields": ["name^3", "description", "tags^2"],
      "type": "best_fields",
      "tie_breaker": 0.2
    }
  }
}
```

`^3` 提升 `name` 字段的权重。权重应通过带标注的查询集调试，而非不断凭感觉叠加。

### 短语匹配与最少匹配数量

```http
POST /products/_search
{
  "query": {
    "bool": {
      "must": {"match": {"description": "无线 键盘"}},
      "should": [
        {"match_phrase": {"description": {"query": "无线 机械键盘", "slop": 1}}},
        {"term": {"brand": {"value": "KeyWorks", "boost": 2}}}
      ],
      "minimum_should_match": 0
    }
  }
}
```

`should` 在已有 `must` 或 `filter` 时默认是可选条件；业务要求至少命中一个条件时，要显式设置 `minimum_should_match: 1`。

## 4. 不要默认开放的查询

- 以 `*` 开头的通配符查询、正则表达式查询和模糊查询可能扫描大量词项。
- `query_string` 查询语法复杂，直接接收最终用户输入可能报错或扩大查询范围。
- 脚本查询会对每个文档执行，成本较高。

对外搜索接口应在服务端固定允许的字段、操作符、页大小和超时，而不是原样转发任意查询 DSL。

## 5. 验证查询

```http
GET /products/_validate/query?explain=true
{
  "query": {"match": {"name": "无线键盘"}}
}

GET /products/_explain/p1001
{
  "query": {"match": {"name": "无线键盘"}}
}
```

`_explain` 很详细且有成本，只用于抽样调试。

## 练习与验收

- 写一个“有货、100-500 元、名称匹配无线键盘”的查询。
- 加入品牌加权，但不能排除其他品牌。
- 说明过滤条件为什么通常不应该放在 `must` 中参与评分。

上一节：[08｜分词](./08-analysis-and-chinese-text.md)｜下一节：[10｜相关性与分页](./10-relevance-sort-pagination.md)
