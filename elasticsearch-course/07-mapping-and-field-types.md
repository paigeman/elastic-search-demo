# 07｜映射、字段类型与动态映射

## 本节目标

- 为业务数据选择正确字段类型。
- 理解 `text`、`keyword`、`object`、`nested` 字段类型的差异。
- 避免映射爆炸（mapping explosion）和不可逆的类型错误。

## 1. 显式映射

删除并重建实验索引前，先确认其中没有需保留的数据：

```http
DELETE /products

PUT /products
{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0
  },
  "mappings": {
    "dynamic": "strict",
    "properties": {
      "product_id": {"type": "keyword"},
      "name": {
        "type": "text",
        "fields": {"keyword": {"type": "keyword", "ignore_above": 256}}
      },
      "description": {"type": "text"},
      "category": {"type": "keyword"},
      "brand": {"type": "keyword"},
      "price": {"type": "scaled_float", "scaling_factor": 100},
      "stock": {"type": "integer"},
      "tags": {"type": "keyword"},
      "available": {"type": "boolean"},
      "created_at": {"type": "date"},
      "attributes": {"type": "flattened"}
    }
  }
}
```

`dynamic: strict` 会拒绝未知字段，适合字段受控的核心索引；探索性日志可以使用动态模板，但仍要控制字段数量。

## 2. 常见字段选择

| 需求 | 推荐类型 | 原因 |
| --- | --- | --- |
| 全文搜索标题 | `text` | 会分词并计算相关性 |
| 精确过滤、聚合、排序 | `keyword` | 整值索引，不分词 |
| 金额 | `scaled_float` 或整数分 | 避免二进制浮点精度问题 |
| 时间 | `date`/`date_nanos` | 支持范围、日期数学和日期聚合 |
| IP、地理位置 | `ip`、`geo_point` | 专用查询与存储优化 |
| 任意键值属性 | `flattened` | 控制动态键造成的字段爆炸 |
| 向量 | `dense_vector` | 语义检索；维度和相似度需预先设计 |

数组不需要单独类型，同一字段多个值即可，但数组元素必须类型兼容。

## 3. 对象类型与嵌套类型

对象数组默认会被扁平化，字段之间的对应关系可能丢失：

```json
{"variants":[{"color":"red","stock":0},{"color":"blue","stock":10}]}
```

若要查询“同一个变体的颜色为 `red` 且库存 `stock>0`”，应把 `variants` 定义为嵌套类型（`nested`），并使用嵌套查询。嵌套文档会增加存储和查询成本。只有在无法进行反规范化，而且更新模式确实需要时，才考虑使用 `join` 类型表达父子关系。

## 4. 映射不能随意修改

已有字段通常不能从 `keyword` 原地改为 `date`，也不能随意改变分析器。标准迁移流程如下：

1. 创建映射正确的新索引 `products-v2`。
2. 用 `_reindex` 或从源系统重放数据。
3. 比较文档数、抽样查询和业务指标。
4. 原子切换别名。
5. 保留旧索引一段回滚窗口，再按审批清理。

## 5. 动态模板

```http
PUT /events-v1
{
  "mappings": {
    "dynamic_templates": [
      {
        "strings_as_keywords": {
          "match_mapping_type": "string",
          "path_match": "labels.*",
          "mapping": {"type": "keyword", "ignore_above": 256}
        }
      }
    ]
  }
}
```

模板要使用有代表性的数据进行测试。由用户控制的任意 JSON 键容易造成映射爆炸，导致集群状态膨胀和堆内存压力。

## 练习与验收

- 为订单数据设计映射：订单号、备注、金额、状态、下单时间、收货坐标。
- 解释为何不能在 `text` 字段上直接高效排序。
- 演示 `dynamic: strict` 拒绝一个拼错的字段。

上一节：[06｜增删改查与批量操作](./06-index-document-crud.md)｜下一节：[08｜分词](./08-analysis-and-chinese-text.md)
