# 07｜映射、字段类型与动态映射：练习与验收答案

建议先独立完成练习，再使用本页核对映射、请求结果和判断过程。以下标记为 `http` 的请求都在 Kibana 的开发工具（Dev Tools）中的控制台（Console）执行。示例使用独立的 `course-orders-v1` 索引，避免影响正文中的 `products` 索引。

## 1. 为订单数据设计映射

如果需要重复执行练习，先确认 `course-orders-v1` 中没有需要保留的数据，再删除旧实验索引：

```http
DELETE /course-orders-v1
```

创建使用显式映射的订单索引：

```http
PUT /course-orders-v1
{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0
  },
  "mappings": {
    "dynamic": "strict",
    "properties": {
      "order_id": {
        "type": "keyword"
      },
      "note": {
        "type": "text",
        "fields": {
          "raw": {
            "type": "keyword",
            "ignore_above": 256
          }
        }
      },
      "amount": {
        "type": "scaled_float",
        "scaling_factor": 100
      },
      "status": {
        "type": "keyword"
      },
      "ordered_at": {
        "type": "date",
        "format": "strict_date_optional_time||epoch_millis"
      },
      "delivery_location": {
        "type": "geo_point"
      }
    }
  }
}
```

字段选择依据如下：

| 字段 | 字段类型 | 选择依据 |
| --- | --- | --- |
| `order_id` | `keyword` | 订单号需要精确匹配，不应分词 |
| `note` | `text` | 备注需要全文检索 |
| `note.raw` | `keyword` | 在确实需要时支持按备注原值排序或聚合 |
| `amount` | `scaled_float` | 按 100 倍缩放保存两位小数，避免直接使用二进制浮点数表达金额 |
| `status` | `keyword` | 状态值用于精确过滤和聚合 |
| `ordered_at` | `date` | 支持日期解析、范围查询和日期聚合 |
| `delivery_location` | `geo_point` | 支持距离和地理范围查询 |

对于要求严格精确、计算规则复杂的财务金额，也可以直接使用整数最小货币单位，例如将 `amount_cents` 映射为 `long`。`scaled_float` 的 `scaling_factor: 100` 适用于课程中保留两位小数的示例，但应结合实际币种和舍入规则设计。

写入一条符合映射的订单：

```http
PUT /course-orders-v1/_doc/o1001?refresh=wait_for
{
  "order_id": "o1001",
  "note": "请在工作日送达前电话联系",
  "amount": 299.90,
  "status": "paid",
  "ordered_at": "2026-07-19T10:30:00+08:00",
  "delivery_location": {
    "lat": 31.2304,
    "lon": 121.4737
  }
}
```

查看最终映射：

```http
GET /course-orders-v1/_mapping
```

验收时应确认：字段类型与设计一致，响应中没有旧版映射类型名称，并且 `note.raw` 位于 `note.fields` 下，而不是作为 `_source` 中需要重复写入的独立字段。

## 2. 解释显式映射、动态映射和动态模板的关系

三者的关系如下：

| 概念 | 作用 |
| --- | --- |
| 显式映射 | 开发者在写入数据前，通过 `properties` 明确声明字段类型和参数 |
| 动态映射 | 遇到未知字段时，Elasticsearch 根据 `dynamic` 设置决定自动建字段、建立运行时字段、忽略字段或拒绝文档 |
| 动态模板 | 动态映射准备新增字段时，根据字段名称、路径或检测到的数据类别定制最终生成的字段映射 |

它们不是三套并列的索引结构。最终结果都是索引映射，只是字段映射的来源和控制方式不同：

1. 已经存在于 `properties` 中的字段直接使用显式映射。
2. 未知字段才会触发 `dynamic` 的处理规则。
3. 当 `dynamic` 为 `true` 或 `runtime` 时，动态模板可以进一步控制未知字段的映射结果。
4. 当 `dynamic` 为 `strict` 时，未知字段会被直接拒绝，动态模板没有机会为它创建映射。

本答案创建的 `course-orders-v1` 使用 `dynamic: strict`，因此所有业务字段都必须先显式声明。正文第 6 节的 `events-v1` 使用动态模板，则允许 `labels.*` 下新出现的字符串字段自动映射为 `keyword`。

## 3. 区分字段类型与 Elasticsearch 8.0 移除的映射类型

字段类型（field data type）定义单个字段如何被解析、索引和查询，例如：

```json
{
  "mappings": {
    "properties": {
      "order_id": {"type": "keyword"},
      "ordered_at": {"type": "date"}
    }
  }
}
```

这里的 `keyword` 和 `date` 是字段类型，现代 Elasticsearch 仍然需要它们。

Elasticsearch 8.0 移除的是映射类型（mapping type，也称 document type）。旧版映射曾在 `mappings` 和 `properties` 之间包含一层文档类别名称：

```json
{
  "mappings": {
    "order": {
      "properties": {
        "order_id": {"type": "keyword"}
      }
    }
  }
}
```

旧结构中的 `order` 是已移除的映射类型，不能用于 Elasticsearch 8.x；`keyword` 则是仍然有效的字段类型。移除过程可以概括为：

- 5.x 及更早版本允许一个索引包含多个映射类型。
- 6.x 新建索引只能包含一个映射类型。
- 7.x 推荐无类型 API，并弃用接受映射类型的 API。
- 8.x 移除映射类型、`_type` 元字段及相关的有类型 API。

现代请求中的 `_doc` 也不是映射类型。例如：

```http
GET /course-orders-v1/_doc/o1001
```

这里的 `_doc` 是文档 CRUD API 路径的固定组成部分，不表示索引中存在名为 `_doc` 的映射类型。

## 4. 解释为何不能在 `text` 字段上直接高效排序

`text` 字段面向全文检索。写入文本时，分析器会把原文转换成多个词元，并写入倒排索引。例如 `"Quick Brown Fox"` 经过标准分析器后会产生类似 `quick`、`brown`、`fox` 的词元。排序需要的是每个文档对应的稳定单值，而不是一组用于全文匹配的词元。

此外，`text` 字段默认不启用适合排序和聚合的 doc values。虽然可以启用 `fielddata`，但它需要从倒排索引加载数据并构建内存结构，可能消耗大量堆内存，通常不应作为常规方案。

正确做法是使用 `keyword` 字段或 `keyword` 多字段。本答案已为 `note` 定义 `note.raw`：

```json
{
  "note": {
    "type": "text",
    "fields": {
      "raw": {
        "type": "keyword",
        "ignore_above": 256
      }
    }
  }
}
```

全文检索使用 `note`：

```http
GET /course-orders-v1/_search
{
  "query": {
    "match": {
      "note": "工作日送达"
    }
  }
}
```

按原值排序使用 `note.raw`：

```http
GET /course-orders-v1/_search
{
  "sort": [
    {"note.raw": {"order": "asc", "missing": "_last"}}
  ],
  "query": {
    "match_all": {}
  }
}
```

`ignore_above: 256` 表示过长的值不会写入 `note.raw`，这类文档在排序时会按缺失值处理。实际业务更常按下单时间、金额等结构化字段排序；这里使用备注排序只是为了演示多字段的职责差异。

## 5. 演示 `dynamic: strict` 拒绝拼错的字段

`course-orders-v1` 已将根映射设置为 `dynamic: strict`。下面故意把 `status` 拼成 `order_stauts`：

```http
PUT /course-orders-v1/_doc/o1002
{
  "order_id": "o1002",
  "note": "字段拼写错误测试",
  "amount": 19.90,
  "order_stauts": "paid",
  "ordered_at": "2026-07-19T11:00:00+08:00",
  "delivery_location": {
    "lat": 31.2304,
    "lon": 121.4737
  }
}
```

请求应失败，错误主体类似：

```json
{
  "error": {
    "type": "strict_dynamic_mapping_exception",
    "reason": "mapping set to strict, dynamic introduction of [order_stauts] within [_doc] is not allowed"
  },
  "status": 400
}
```

具体 `reason` 文本可能随版本变化，验收重点是 HTTP 400、`error.type` 为 `strict_dynamic_mapping_exception`，并且错误指向未知字段 `order_stauts`。

确认失败请求没有部分写入文档：

```http
GET /course-orders-v1/_doc/o1002
```

应返回 HTTP 404 和 `"found": false`。再检查映射：

```http
GET /course-orders-v1/_mapping/field/order_stauts
```

响应应为空对象，表明拼错的字段没有进入映射。改正字段名后重新写入：

```http
PUT /course-orders-v1/_doc/o1002?refresh=wait_for
{
  "order_id": "o1002",
  "note": "字段拼写已修正",
  "amount": 19.90,
  "status": "paid",
  "ordered_at": "2026-07-19T11:00:00+08:00",
  "delivery_location": {
    "lat": 31.2304,
    "lon": 121.4737
  }
}
```

这次请求应成功，响应中的 `result` 为 `created`。该实验说明 `dynamic: strict` 会在写入阶段阻止字段拼写错误进入映射和索引，而不是先写入已知字段、再忽略未知字段。
