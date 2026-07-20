# 07｜映射、字段类型与动态映射

## 本节目标

- 为业务数据选择正确字段类型。
- 理解 `text`、`keyword`、`object`、`nested` 字段类型的差异。
- 避免映射爆炸（mapping explosion）和不可逆的类型错误。

## 1. 显式映射与动态映射

### 1.1 显式映射

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

显式映射是指在写入数据之前，由开发者在 `mappings.properties` 中明确声明字段名称、字段类型和参数。上例显式规定了 `product_id` 是 `keyword`、`stock` 是 `integer` 等，并使用 `dynamic: strict` 拒绝所有未声明的字段。这种方式适合字段受控的核心索引。

### 1.2 动态映射

动态映射不是另一种映射结构，而是字段映射的一种产生方式。当写入文档包含尚未映射的字段时，Elasticsearch 可以根据输入值自动推断字段类型，并把推断结果加入当前索引的映射。例如：

```http
PUT /dynamic-mapping-demo
{
  "mappings": {
    "dynamic": true,
    "properties": {
      "product_id": {"type": "keyword"}
    }
  }
}

PUT /dynamic-mapping-demo/_doc/p1001
{
  "product_id": "p1001",
  "stock": 10,
  "available": true
}
```

这里的 `product_id` 来自显式映射；首次写入时，未知字段 `stock` 和 `available` 由动态映射分别推断为 `long` 和 `boolean`。两种方式可以在同一个索引中共存：已显式声明的字段使用既定映射，动态映射只处理未知字段。自动生成的字段映射一旦加入索引，也要遵守普通映射的限制，例如不能直接把 `stock` 从 `long` 原地改为 `date`。

`mappings.dynamic` 控制遇到未知字段时的行为：

| `dynamic` 值 | 未知字段的处理方式 |
| --- | --- |
| `true`（默认值） | 推断字段类型，并把具体字段加入映射 |
| `false` | 不加入映射、不建立索引，但字段仍保留在 `_source` 中 |
| `strict` | 拒绝整份包含未知字段的文档 |
| `runtime` | 推断类型，并把未知字段加入映射作为运行时字段 |

处理一个输入字段时，可以把 Elasticsearch 的判断顺序理解为：

1. 先在当前映射中查找该字段。
2. 如果字段已经存在，就按照既定字段类型解析和索引它。
3. 如果字段不存在，才读取当前层级生效的 `dynamic` 设置。
4. 只有 `true` 或 `runtime` 会继续推断未知字段的类型；`strict` 会立即抛出 `strict_dynamic_mapping_exception` 并拒绝整份文档。

因此，`strict` 不是“用更严格的规则自动推断类型”，而是“禁止自动新增字段”。文档写入是一个整体，不会只索引已知字段并丢弃未知字段；被 `strict` 拒绝后，文档和字段映射都不会写入。

### 1.3 `dynamic: true` 与 `dynamic: runtime` 的区别

二者都会识别未知字段，也都会把字段定义记录在映射中，主要区别是是否在写入时为字段建立索引：

| 对比项 | `dynamic: true` | `dynamic: runtime` |
| --- | --- | --- |
| 字段定义位置 | `mappings.properties` | `mappings.runtime` |
| 是否建立索引 | 是 | 否，查询时从 `_source` 读取值 |
| 写入与磁盘成本 | 较高 | 较低 |
| 查询性能 | 通常较快 | 通常较慢，查询可能被视为昂贵查询 |
| 典型用途 | 经常过滤、聚合、排序的正式字段 | 数据探索、低频字段、映射尚未确定的字段 |

例如，将未知字段自动定义为运行时字段：

```http
PUT /dynamic-runtime-demo
{
  "mappings": {
    "dynamic": "runtime",
    "properties": {
      "product_id": {"type": "keyword"}
    }
  }
}

PUT /dynamic-runtime-demo/_doc/p1001
{
  "product_id": "p1001",
  "stock": 10,
  "available": true
}
```

写入后，显式声明的 `product_id` 仍然位于 `properties` 中并正常建立索引；未知的 `stock` 和 `available` 则分别成为 `long` 和 `boolean` 运行时字段。运行时字段可以像普通字段一样参与查询、过滤、聚合和排序，例如：

```http
GET /dynamic-runtime-demo/_search
{
  "query": {
    "range": {
      "stock": {"gt": 0}
    }
  },
  "fields": ["product_id", "stock", "available"],
  "_source": false
}
```

该查询需要在查询阶段从 `_source` 读取并解析 `stock`，而 `dynamic: true` 创建的具体字段可以直接使用写入时建立的索引结构。如果集群设置了 `search.allow_expensive_queries: false`，针对运行时字段的查询会被拒绝。

#### 能否同时设置 `true` 和 `runtime`

同一个映射层级的 `dynamic` 只能有一个值，不能同时设置为 `true` 和 `runtime`。因此，“高频字段建立索引、其余字段作为运行时字段”的推荐配置，不是给高频字段单独设置 `dynamic: true`，而是：

1. 在 `properties` 中显式声明已知的高频字段，使其正常建立索引。
2. 在同一层级设置 `dynamic: runtime`，只让剩余的未知字段自动成为运行时字段。

前面的 `/dynamic-runtime-demo` 就是这种配置：`product_id` 是显式建立索引的字段，`stock` 和 `available` 是由 `dynamic: runtime` 接管的未知字段。

`dynamic` 还可以分别设置在根映射和内部 `object` 上；内部对象默认继承父级设置，也可以显式覆盖。因此，同一个创建索引请求可以在不同层级使用不同值：

```http
PUT /mixed-dynamic-demo
{
  "mappings": {
    "dynamic": "runtime",
    "properties": {
      "product_id": {"type": "keyword"},
      "metrics": {
        "type": "object",
        "dynamic": true
      }
    }
  }
}
```

在这个映射中：

- `product_id` 是显式声明并建立索引的字段。
- `metrics` 下出现的未知子字段会按照 `dynamic: true` 建立索引。
- 其他未知的顶层字段会继承根级 `dynamic: runtime`，成为运行时字段。

这里的两个 `dynamic` 分别控制根映射和 `metrics` 对象，并没有在同一层级发生冲突。需要接收未知字段但不希望它们默认建立索引时，可以使用“显式高频字段 + 根级 `dynamic: runtime`”；字段完全受控的核心索引仍可选择 `dynamic: strict`。只有希望未知字段默认都建立索引时，才选择根级 `dynamic: true`。

两种模式的自动类型推断也不完全相同：普通字符串在 `dynamic: true` 下默认映射为带 `.keyword` 子字段的 `text`，在 `dynamic: runtime` 下默认映射为 `keyword` 运行时字段；JSON 浮点数通常分别映射为 `float` 和 `double`。JSON 对象在 `dynamic: true` 下可以产生 `object` 映射，而 `dynamic: runtime` 不会为对象本身添加运行时字段。无论使用哪种模式，`nested` 都不会被自动推断，必须显式声明。

官方参考：[dynamic 参数](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/dynamic)、[运行时字段](https://www.elastic.co/docs/manage-data/data-store/mapping/runtime-fields)。

动态映射适合探索性数据或字段变化较多的场景，但自动推断结果不一定符合业务语义。例如订单号 `"10001"` 可能需要 `keyword`，日期格式也可能需要明确约束。核心字段应优先显式定义；需要自动接收未知字段时，再结合第 6 节的动态模板约束字段名称和推断结果。动态模板不是第三种映射方式，而是对动态映射规则的定制；在 `dynamic: strict` 下，未知字段会直接被拒绝，不会由动态模板自动添加。

## 2. 字段类型不等于已移除的映射类型

本节所说的“字段类型”（field data type）是 `mappings.properties` 下每个字段的 `type`，例如 `text`、`keyword`、`date` 和 `nested`。它决定字段如何被解析、索引和查询，是 Elasticsearch 8.x 及后续版本映射机制的组成部分，并未被移除。例如：

```json
{
  "mappings": {
    "properties": {
      "name": {"type": "text"},
      "created_at": {"type": "date"}
    }
  }
}
```

Elasticsearch 8.0 移除的是“映射类型”（mapping type，也称 document type），即旧版本中位于 `mappings` 与 `properties` 之间、用于给文档分类的一层名称。旧式结构如下，仅用于理解历史，不要在 8.x 中执行：

```json
{
  "mappings": {
    "product": {
      "properties": {
        "name": {"type": "text"}
      }
    }
  }
}
```

这里的 `product` 是已移除的映射类型，而 `text` 是仍然有效的字段类型。二者虽然都曾被简称为 type，但处于不同层级，作用也完全不同。映射类型的移除过程如下：

- 5.x 及更早版本：一个索引可以包含多个映射类型。
- 6.x：新建索引只能包含一个映射类型；从 5.x 升级而来的多类型索引仍可兼容使用。
- 7.x：引入并推荐无类型 API，接受映射类型的 API 被弃用。
- 8.x：映射类型、`_type` 元字段以及相关的有类型 API 被移除。

在现代版本中，`PUT /products/_doc/p1001` 里的 `_doc` 是文档 CRUD API 路径的固定组成部分，不是名为 `_doc` 的映射类型，也不表示映射类型仍然存在。同样，第 6 节动态模板中的 `match_mapping_type` 表示 Elasticsearch 根据输入值识别出的 JSON 数据类别，用于匹配模板，也不是已移除的映射类型。

官方参考：[字段数据类型](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/field-data-types)、[移除映射类型](https://www.elastic.co/docs/manage-data/data-store/mapping/removal-of-mapping-types)。

## 3. 常见字段选择

| 需求 | 推荐字段类型 | 原因 |
| --- | --- | --- |
| 全文搜索标题 | `text` | 会分词并计算相关性 |
| 精确过滤、聚合、排序 | `keyword` | 整值索引，不分词 |
| 金额 | `scaled_float` 或整数分 | 避免二进制浮点精度问题 |
| 时间 | `date`/`date_nanos` | 支持范围、日期数学和日期聚合 |
| IP、地理位置 | `ip`、`geo_point` | 专用查询与存储优化 |
| 任意键值属性 | `flattened` | 控制动态键造成的字段爆炸 |
| 向量 | `dense_vector` | 语义检索；维度和相似度需预先设计 |

数组不需要单独类型，同一字段多个值即可，但数组元素必须类型兼容。

## 4. 对象类型与嵌套类型

### 4.1 对象类型与对象数组的关系

`object` 是映射中的字段类型；“对象数组”是文档 `_source` 中的一种 JSON 数据结构。下面的 `manufacturer` 是单个对象，`variants` 是对象数组：

```json
{
  "manufacturer": {
    "name": "Example Inc.",
    "country": "CN"
  },
  "variants": [
    {"color": "red", "stock": 0},
    {"color": "blue", "stock": 10}
  ]
}
```

Elasticsearch 没有单独的 `array` 字段类型，因此字段是单值还是多值并不会改变它的映射类型。在没有预先声明映射时，动态映射会按以下方式处理：

| `_source` 中的值 | 数据结构称呼 | 默认字段类型 |
| --- | --- | --- |
| `{"name":"Example Inc.","country":"CN"}` | 单个对象 | `object` |
| `[{"color":"red"},{"color":"blue"}]` | 对象数组 | `object` |

也就是说，对象数组默认仍然是 `object` 类型，并不存在名为“对象数组”的字段类型。单个对象只有一组子字段值，扁平化通常不会造成元素对应关系问题；对象数组包含多组子字段值，按照 `object` 索引时才可能丢失不同数组元素内部的字段对应关系。

上面的代码只表示 `_source` 的数据形状，并不能单独证明 `variants` 是 `object` 还是 `nested`。若希望保留对象数组中每个元素内部的字段关系，必须在写入数据之前将 `variants` 显式映射为 `nested`；不会因为写入了对象数组而自动变成 `nested`。

### 4.2 `object`：默认扁平化对象数组

当 `dynamic` 为 `true`，而 `variants` 尚未显式映射时，Elasticsearch 看到 JSON 对象或对象数组后，会为它自动创建 `object` 映射。动态映射不会根据对象数组自动选择 `nested`。如果已经确定不需要保留数组元素内部的字段关系，也可以显式声明为 `object`：

注意，第 1.1 节的 `/products` 索引设置了 `dynamic: strict`。如果它的显式映射中没有 `variants`，直接写入该字段会导致整份文档被拒绝，而不会自动创建 `object` 映射。要在该索引中使用 `variants`，需要先通过更新映射 API 显式添加它：

```http
PUT /products/_mapping
{
  "properties": {
    "variants": {
      "type": "object",
      "properties": {
        "color": {"type": "keyword"},
        "stock": {"type": "integer"}
      }
    }
  }
}
```

添加映射之后，`variants` 已经不再是未知字段，因此即使根级仍为 `dynamic: strict`，也可以正常写入：

```http
PUT /products/_doc/p1001
{
  "variants": [
    {"color": "red", "stock": 0},
    {"color": "blue", "stock": 10}
  ]
}
```

`object` 不会把数组中的每个对象作为独立单元建立索引。上面的对象数组在索引内部可以概念性地理解为：

```json
{
  "variants.color": ["red", "blue"],
  "variants.stock": [0, 10]
}
```

原始 `_source` 不会因此改变，但 `red` 与 `0`、`blue` 与 `10` 的元素对应关系在索引结构中丢失。所以下面的普通布尔查询会匹配该文档：

```http
GET /products/_search
{
  "query": {
    "bool": {
      "filter": [
        {"term": {"variants.color": "red"}},
        {"range": {"variants.stock": {"gt": 0}}}
      ]
    }
  }
}
```

这是一个不符合业务语义的匹配：颜色为 `red` 的变体库存是 `0`，库存大于 `0` 的其实是另一个 `blue` 变体。查询只确认两个字段各自包含符合条件的值，无法要求它们来自数组中的同一个对象。

### 4.3 `nested`：保留每个数组元素的字段关系

如果业务需要查询“同一个变体的颜色为 `red` 且库存大于 `0`”，应在创建索引时把 `variants` 映射为 `nested`：

```http
PUT /products-nested-demo
{
  "mappings": {
    "properties": {
      "variants": {
        "type": "nested",
        "properties": {
          "color": {"type": "keyword"},
          "stock": {"type": "integer"}
        }
      }
    }
  }
}
```

写入的 `_source` 仍然是 4.1 节展示的对象数组，不需要增加特殊的 JSON 标记：

```http
PUT /products-nested-demo/_doc/p1001
{
  "variants": [
    {"color": "red", "stock": 0},
    {"color": "blue", "stock": 10}
  ]
}
```

`nested` 会在索引内部将每个数组元素作为隐藏的独立文档处理，从而保留同一元素内各字段的对应关系。查询时必须使用 `nested` 查询并指定路径：

```http
GET /products-nested-demo/_search
{
  "query": {
    "nested": {
      "path": "variants",
      "query": {
        "bool": {
          "filter": [
            {"term": {"variants.color": "red"}},
            {"range": {"variants.stock": {"gt": 0}}}
          ]
        }
      }
    }
  }
}
```

该查询不会匹配示例文档，因为不存在同时满足两个条件的同一个变体。

选择时遵循以下原则：不需要保持数组元素内部字段关系时使用 `object`；需要对同一个数组元素组合多个条件时使用 `nested`。`nested` 会增加索引文档数量、存储开销和查询成本，而且已有 `object` 字段不能原地改成 `nested`，需要创建新索引并重建数据。`join` 类型解决的是同一索引中独立父子文档之间的关系，不是对象数组的默认替代方案；只有确实需要独立更新父子文档且无法反规范化时才考虑使用。

## 5. 映射为何不能随意修改

映射不是只记录“字段叫什么类型”的说明文档，而是 Elasticsearch 建立索引时实际执行的规则。一个字段的映射既包含 `type`，也包含适用于该类型的映射参数。`analyzer` 正是 `text` 字段的一项映射参数，所以修改已有字段的 `analyzer`，本质上就是修改该字段的映射。

例如，下面整段都是 `name` 的字段映射，其中 `type` 决定它是全文文本字段，`analyzer` 决定它在建立索引时如何产生词元：

```json
{
  "properties": {
    "name": {
      "type": "text",
      "analyzer": "standard"
    }
  }
}
```

这个映射会参与从原始文档到索引结构的转换：

```text
_source 中的 "Quick Brown Fox"
        ↓ name 字段的映射：type=text, analyzer=standard
倒排索引中的 quick、brown、fox
```

原始字符串仍保留在 `_source` 中，但全文查询主要匹配倒排索引中的词元。分析器通常由字符过滤、分词和词元过滤组成，第 08 节会详细介绍。`analyzer` 参数只适用于 `text` 字段；`keyword` 字段不使用分词分析器，如需规范化精确值，应使用 `normalizer`。

### 5.1 字段映射与已有索引数据绑定

字段类型和索引分析器不能原地修改，原因相同：它们都决定已经写入的索引数据是什么样子。

下面用同一个输入值对比修改前后的索引结果。表格最后一列是假设 Elasticsearch 允许修改时，后续新文档会产生的结果；实际更新请求会被拒绝：

| 拟进行的映射修改 | 历史文档已有的索引结果 | 假设修改后，新文档会产生的结果 |
| --- | --- | --- |
| `type: keyword` 改为 `type: date` | `"2026-07-19"` 按完整字符串建立精确值索引 | `"2026-07-19"` 被解析并按照日期值建立索引 |
| `analyzer: standard` 改为 `analyzer: keyword` | `"Quick Brown Fox"` 产生 `quick`、`brown`、`fox` 三个词元 | `"Quick Brown Fox"` 产生保留原内容的单个词元 |

以第二行为例，如果只修改映射而不重建数据，历史文档中的三个词元不会自动合并成新分析器期望的单个词元；同一个字段的新旧文档会具有不一致的索引结构，查询可能漏掉其中一部分。

因此，Elasticsearch 不允许通过更新映射 API 修改已有 `text` 字段的 `analyzer`，就像不能把已有字段从 `keyword` 原地改为 `date` 一样。限制的并不是“分析器”这个孤立概念，而是任何会改变已有索引数据解释方式的字段映射。若确实需要改变字段类型或索引时分词规则，就必须用新映射重建索引数据。

### 5.2 `search_analyzer` 是查询阶段的例外

`search_analyzer` 也写在字段映射中，但它只处理用户提交的查询文本，不改变已经存储的倒排索引，因此更新限制不同：

| 参数 | 使用阶段 | 是否重建历史词元 | 已有字段能否更新 |
| --- | --- | --- | --- |
| `analyzer` | 写入文档、建立倒排索引时；未单独配置时也用于搜索 | 是 | 不能，通常需要新索引并重建数据 |
| `search_analyzer` | 将用户查询文本转换为搜索词元时 | 否 | 可以通过更新映射 API 修改 |

虽然 `search_analyzer` 可以更新，但新的搜索词元仍需与索引中已有词元匹配，因此修改前必须使用真实查询集验证召回率、精确率和相关性。只有自动补全、搜索时同义词等明确场景，才通常会有意使用不同的索引分析器和搜索分析器。

官方参考：[analyzer 参数](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/analyzer)、[search_analyzer 参数](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/search-analyzer)。

需要改变字段类型或索引分析器时，标准迁移流程如下：

1. 创建映射正确的新索引 `products-v2`。
2. 用 `_reindex` 或从源系统重放数据。
3. 比较文档数、抽样查询和业务指标。
4. 原子切换别名。
5. 保留旧索引一段回滚窗口，再按审批清理。

## 6. 动态模板：约束动态映射

动态模板（dynamic template）在动态映射发现未知字段时，根据字段路径、字段名称或检测到的数据类型，决定应该生成什么字段映射。它不会覆盖已经存在的显式映射；多个模板同时匹配时，使用列表中第一个匹配的模板。

```http
PUT /events-v1
{
  "mappings": {
    "dynamic": true,
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

PUT /events-v1/_doc/e1001
{
  "labels": {
    "environment": "production"
  }
}
```

写入 `labels.environment` 时，动态映射先识别出输入值属于 `string`，然后模板通过 `path_match: "labels.*"` 命中该字段，最终生成 `keyword` 映射，而不是直接采用默认字符串映射规则。这里的 `match_mapping_type` 是动态类型检测条件，与第 2 节所说的旧版映射类型无关。

模板要使用有代表性的数据进行测试。由用户控制的任意 JSON 键容易造成映射爆炸，导致集群状态膨胀和堆内存压力。若索引设置为 `dynamic: strict`，未知字段会被直接拒绝，动态模板没有机会为其创建字段映射。

## 练习与验收

- 为订单数据设计映射：订单号、备注、金额、状态、下单时间、收货坐标。
- 解释显式映射、动态映射和动态模板之间的关系。
- 解释字段类型与 Elasticsearch 8.0 移除的映射类型有何区别。
- 解释为何不能在 `text` 字段上直接高效排序。
- 演示 `dynamic: strict` 拒绝一个拼错的字段。

上一节：[06｜增删改查与批量操作](./06-index-document-crud.md)｜下一节：[08｜分词](./08-analysis-and-chinese-text.md)
