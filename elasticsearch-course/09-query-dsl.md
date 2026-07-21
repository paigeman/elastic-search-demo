# 09｜查询语言与全文检索

## 本节目标

- 区分查询上下文（query context）和过滤上下文（filter context）。
- 熟练组合布尔查询、词项级查询和全文查询。
- 写出可解释、可维护的业务查询。

## 操作环境与实验数据

本章所有请求都在 Kibana 的“开发工具（Dev Tools）→ Console”中执行。为了不依赖前面章节执行后的索引状态，本章使用独立的 `query-dsl-products` 索引。

下面的初始化脚本会删除并重建这个实验索引；不要将索引名替换为需要保留数据的业务索引。整段脚本可以直接粘贴到 Console 中，然后按顺序执行各个请求。

首先重建索引并声明字段映射：

```http
DELETE /query-dsl-products?ignore_unavailable=true

PUT /query-dsl-products
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
      "description": {"type": "text"},
      "category": {"type": "keyword"},
      "brand": {"type": "keyword"},
      "price": {"type": "scaled_float", "scaling_factor": 100},
      "stock": {"type": "integer"},
      "tags": {"type": "keyword"},
      "available": {"type": "boolean"},
      "created_at": {"type": "date"}
    }
  }
}
```

再使用 Bulk API 写入五件商品。`refresh=wait_for` 会等待数据对搜索可见，因此初始化完成后可以立即运行本章查询：

```http
POST /query-dsl-products/_bulk?refresh=wait_for&filter_path=errors,items.*.status
{"index":{"_id":"p1001"}}
{"product_id":"p1001","name":"机械键盘 K8","description":"87 键无线机械键盘","category":"keyboard","brand":"KeyWorks","price":399.0,"stock":25,"tags":["wireless","hot-swap"],"available":true,"created_at":"2026-07-01T08:00:00Z"}
{"index":{"_id":"p1002"}}
{"product_id":"p1002","name":"无线办公键盘","description":"轻薄静音无线键盘","category":"keyboard","brand":"KeyWorks","price":299.0,"stock":18,"tags":["wireless","office"],"available":true,"created_at":"2026-07-05T09:00:00Z"}
{"index":{"_id":"p1003"}}
{"product_id":"p1003","name":"无线游戏键盘","description":"无线机械键盘，旧型号清仓","category":"keyboard","brand":"GameType","price":459.0,"stock":2,"tags":["wireless","discontinued"],"available":true,"created_at":"2026-07-10T10:00:00Z"}
{"index":{"_id":"p1004"}}
{"product_id":"p1004","name":"USB-C 扩展坞","description":"支持显示器和有线键盘连接","category":"accessory","brand":"DockPro","price":499.0,"stock":8,"tags":["usb-c"],"available":true,"created_at":"2026-07-12T11:00:00Z"}
{"index":{"_id":"p1005"}}
{"product_id":"p1005","name":"人体工学键盘","description":"分体式无线办公键盘","category":"keyboard","brand":"ErgoType","price":699.0,"stock":6,"tags":["wireless","ergonomic"],"available":true,"created_at":"2026-07-15T12:00:00Z"}
```

Bulk 响应中的 `errors` 应为 `false`，每个 `index.status` 应为 `201`。

最后确认五条文档均已写入：

```http
GET /query-dsl-products/_count
```

预期返回的 `count` 是 `5`。这些数据特意包含不同的对照条件：`p1003` 带有停用标签，`p1004` 不属于键盘类目，`p1005` 的价格超过 500 元。后面的组合查询会逐步排除它们。

## 1. Query DSL 中的查询上下文与过滤上下文

Query DSL 是 Elasticsearch 统一使用的 JSON 查询语言，既能表达全文搜索，也能表达精确过滤。全文搜索条件和过滤条件都使用 Query DSL 的查询子句（query clause）来表达，例如 `match`、`term` 和 `range`。这些子句本身不等同于“过滤”；它们所在的位置决定其运行在查询上下文还是过滤上下文。

这里需要区分“查询”一词的两种用法：

- 广义的“查询”指发给 `_search` API 的整棵 Query DSL，可以同时包含评分条件和过滤条件。
- “查询上下文”中的“查询”是狭义概念，特指需要计算相关性分数的执行方式。

两种上下文分别解决不同的问题：

- 查询上下文（query context）回答“文档匹配得有多好”，满足条件的文档会获得 `_score`，适合需要按相关性排序的文本搜索。
- 过滤上下文（filter context）回答“文档是否满足条件”，结果只有“是”或“否”，不为 `_score` 增加分值，适合状态、类目、价格范围和权限等硬性条件，也更有机会被缓存。

`bool` 是布尔复合查询（boolean compound query）。接下来的示例会使用它同时组织评分条件和过滤条件。它不是查询某个布尔类型字段，也不直接规定“如何匹配字段值”；它是一个容器，用布尔逻辑组合 `match`、`term`、`range` 等其他查询子句。

`bool` 的基本结构如下：

```json
{
  "query": {
    "bool": {
      "must": [{ "match": { "description": "无线键盘" } }],
      "should": [{ "term": { "brand": "KeyWorks" } }],
      "filter": [{ "term": { "available": true } }],
      "must_not": [{ "term": { "tags": "discontinued" } }]
    }
  }
}
```

这段结构从外到内表示：

1. 搜索 API 的 `query` 参数接收一棵 Query DSL。
2. 根查询选择 `bool` 这种复合查询。
3. `bool` 把四组子查询按照不同规则组合起来。

因此，`bool` 中并不是直接填写字段和值，而是在 `must`、`should`、`filter` 和 `must_not` 下面继续放置完整的查询子句。每个位置既规定布尔关系，也决定子句是否参与评分：

| `bool` 中的位置 | 所处上下文 | 是否影响 `_score` | 作用                                                                |
| --------------- | ---------- | ----------------- | ------------------------------------------------------------------- |
| `must`          | 查询上下文 | 是                | 必须匹配，并参与相关性评分                                          |
| `should`        | 查询上下文 | 是                | 匹配时可以提高相关性评分，是否必须匹配取决于 `minimum_should_match` |
| `filter`        | 过滤上下文 | 否                | 必须满足，但不参与相关性评分                                        |
| `must_not`      | 过滤上下文 | 否                | 必须不满足，并且不参与相关性评分                                    |

同一个数组中的多个 `must` 或 `filter` 子句都必须满足，相当于逻辑 AND；任意一个 `must_not` 子句匹配都会排除文档。`should` 更接近“满足其中若干项”：匹配的 `should` 通常会增加分数，至少必须满足几项由 `minimum_should_match` 控制。

当 `bool` 已经包含 `must` 或 `filter` 时，`should` 默认可以一项都不满足；如果既没有 `must` 也没有 `filter`，则默认至少满足一个 `should`。业务规则不应依赖读者记住这个默认差异，需要强制匹配时应显式设置 `minimum_should_match`。

在查询上下文中，`bool` 通常把命中的 `must` 和 `should` 子句分数相加，形成最终 `_score`；`filter` 和 `must_not` 只改变文档能否进入结果集，不贡献分数。`must`、`should`、`filter` 和 `must_not` 都可以接收单个查询对象或查询数组。

查询子句的类型主要决定“如何匹配”，所在位置则决定“是否评分”。例如，同一个 `term` 或 `range` 子句放在 `bool.must` 和 `bool.filter` 中，会进入不同的上下文。

下面使用刚刚写入的实验商品依次观察两种上下文。`p1001` 的 `description` 是“87 键无线机械键盘”，因此可以匹配“无线键盘”。

### 1.1 查询子句运行在查询上下文

`description` 没有显式配置分析器，因此使用默认的 `standard` 分析器。执行搜索前，先查看查询文本“无线键盘”会被分析成哪些词元：

```http
POST /query-dsl-products/_analyze?filter_path=tokens.token,tokens.position
{
  "field": "description",
  "text": "无线键盘"
}
```

预期得到四个查询词元及其位置：

```json
{
  "tokens": [
    { "token": "无", "position": 0 },
    { "token": "线", "position": 1 },
    { "token": "键", "position": 2 },
    { "token": "盘", "position": 3 }
  ]
}
```

`match` 查询会先使用字段的搜索分析器处理查询文本，再根据 `operator` 组合得到的词元。下面设置 `operator: "and"`：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "query": {
    "match": {
      "description": {
        "query": "无线键盘",
        "operator": "and"
      }
    }
  }
}
```

这里的 `and` 不是连接原始字符串“无线键盘”，而是应用到分析后的四个词元上。可以把匹配条件概念化为：

```text
description:无 AND description:线 AND description:键 AND description:盘
```

因此，文档的 `description` 必须包含这四个词元才能命中：

- `p1001`、`p1002`、`p1003` 和 `p1005` 都包含全部四个词元，因此命中。
- `p1004` 的描述包含“有线键盘”，具有“线”“键”“盘”等词元，但缺少“无”，因此不命中。

`operator: "and"` 只要求所有查询词元都出现，不要求它们保持原顺序或彼此相邻；需要约束词元顺序和位置时，应使用后文的 `match_phrase`。由于 `match` 位于顶层 `query` 中，它运行在查询上下文，每条命中文档都会返回一个正数 `_score`。具体数值由索引中的文档、分词结果和相关性算法共同决定，不要依赖某个固定数值。

### 1.2 查询子句运行在过滤上下文

再执行一个只有过滤条件的查询：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "query": {
    "bool": {
      "filter": [
        {"term": {"available": true}},
        {"term": {"category": "keyboard"}},
        {"range": {"price": {"gte": 100, "lte": 500}}}
      ]
    }
  }
}
```

`filter` 数组中的三个条件按逻辑 AND 组合，文档必须同时满足它们：

| 过滤条件                   | 单独满足条件的文档                 |
| -------------------------- | ---------------------------------- |
| `available` 等于 `true`    | `p1001`～`p1005`                   |
| `category` 等于 `keyboard` | `p1001`、`p1002`、`p1003`、`p1005` |
| `price` 位于 100～500 元   | `p1001`、`p1002`、`p1003`、`p1004` |
| 三个条件的交集             | `p1001`、`p1002`、`p1003`          |

`term` 对布尔值和 `keyword` 值进行精确匹配，`range` 检查数值边界。虽然它们都是 Query DSL 的查询子句，但这里位于 `bool.filter` 中，因此只做过滤，不负责评分。最终三条文档的 `_score` 都是 `0.0`。

### 1.3 在业务查询中组合两种上下文

商品搜索通常既要根据关键词计算相关性，又要应用不能违反的业务条件：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "query": {
    "bool": {
      "must": [
        {"match": {"description": {"query": "无线键盘", "operator": "and"}}}
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

这个查询的执行逻辑是：

1. `must` 中的 `match` 要求文档匹配“无线键盘”，并计算相关性分数。
2. `filter` 只保留有货、属于键盘类目且价格在 100～500 元的商品。
3. `must_not` 排除带有 `discontinued` 标签的商品。

按照初始化数据逐步缩小结果集：

| 执行阶段          | 剩余文档                           | 变化原因                           |
| ----------------- | ---------------------------------- | ---------------------------------- |
| `must` 的全文匹配 | `p1001`、`p1002`、`p1003`、`p1005` | 四条文档都包含“无”“线”“键”“盘”词元 |
| 再应用 `filter`   | `p1001`、`p1002`、`p1003`          | `p1005` 的价格超过 500 元          |
| 再应用 `must_not` | `p1001`、`p1002`                   | `p1003` 带有 `discontinued` 标签   |

最终只会返回 `p1001` 和 `p1002`，其 `_score` 来自 `must` 中的 `match`。`filter` 和 `must_not` 会改变哪些文档能够进入结果集，但不会因为文档满足了更多过滤条件而提高分数。在索引数据不变的情况下，对同一文档使用相同的 `match` 子句，第 1.1 节和本节得到的相关性分数应当相同。

三次查询需要重点比较的是：

| 查询                          | `p1001` 的 `_score` | 原因                                                    |
| ----------------------------- | ------------------- | ------------------------------------------------------- |
| 第 1.1 节：只有 `match`       | 正数                | `match` 在查询上下文中负责评分                          |
| 第 1.2 节：只有 `filter`      | `0.0`               | 没有负责评分的查询子句                                  |
| 第 1.3 节：`match` 加过滤条件 | 与第 1.1 节相同     | 过滤条件只控制是否进入结果集，不改变 `match` 产生的分数 |

因此，设计业务查询时通常遵循这条原则：需要影响相关性排序的条件放入查询上下文；只表示业务约束的条件放入过滤上下文。

## 2. 词项级查询

词项级查询（term-level query）是一类查询，不是专指 `term` 查询。它们直接使用精确词项或结构化值，不会像 `match` 那样先对查询文本做全文分析，适合 `keyword`、数值、布尔值和日期等字段。

“词项级”描述的是查询如何匹配值，与查询上下文、过滤上下文是两个不同维度。词项级查询放在 `must` 或 `should` 中可以参与评分，放在 `filter` 或 `must_not` 中则只用于筛选；结构化业务条件通常不需要相关性，因此更常放在过滤上下文。

Elasticsearch 常见的词项级查询包括：

| 查询        | 作用                           | 典型用途或注意点                           |
| ----------- | ------------------------------ | ------------------------------------------ |
| `term`      | 匹配一个精确词项               | 单个状态、类目、品牌、布尔值               |
| `terms`     | 匹配数组中的任意一个精确词项   | 多选品牌或类目；数组内部按 OR 匹配         |
| `terms_set` | 要求至少匹配数组中的若干词项   | 标签集合需要达到指定匹配数量               |
| `range`     | 匹配指定上下界内的值           | 数值、日期、IP 地址范围                    |
| `exists`    | 检查字段是否具有已建立索引的值 | 区分有值与缺失字段                         |
| `ids`       | 根据文档 `_id` 匹配            | 已知一组 Elasticsearch 文档标识时批量读取  |
| `prefix`    | 匹配具有指定前缀的词项         | 编码或关键字前缀；字段设计不当时可能较昂贵 |
| `wildcard`  | 使用 `*`、`?` 匹配词项         | 模式匹配，尤其要避免不受控的前导通配符     |
| `regexp`    | 使用正则表达式匹配词项         | 表达能力强，但可能展开大量候选词项         |
| `fuzzy`     | 按编辑距离匹配相近词项         | 容忍少量拼写错误，但要限制扩展数量         |

其中 `term`、`terms`、`range`、`exists` 和 `ids` 常用于结构化条件；`prefix`、`wildcard`、`regexp` 和 `fuzzy` 也属于词项级查询，但可能需要枚举或扩展大量词项，使用限制见第 5 节。

第 1.2 节已经使用 `term` 分别匹配一个精确的 `available` 值和 `category` 值。下面进一步组合 `terms`、`exists` 和 `range`：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "query": {
    "bool": {
      "filter": [
        {"terms": {"brand": ["KeyWorks", "DockPro"]}},
        {"exists": {"field": "stock"}},
        {"range": {"created_at": {"gte": "2026-07-01", "lt": "2026-08-01"}}}
      ]
    }
  }
}
```

这个 `filter` 数组仍按逻辑 AND 组合：

- `terms` 要求 `brand` 至少等于数组中的一个值。数组内部是 OR，因此可以匹配 `KeyWorks` 或 `DockPro`，得到 `p1001`、`p1002` 和 `p1004`。
- `exists` 要求文档具有已建立索引值的 `stock` 字段；初始化的五条文档都满足。
- `range` 要求 `created_at` 位于 2026 年 7 月；初始化的五条文档都满足。

三个条件取交集后返回 `p1001`、`p1002` 和 `p1004`。因为所有子句都位于过滤上下文，三条结果的 `_score` 都是 `0.0`。

不要用 `term` 查询分析过的 `text` 字段来猜测词元。例如，`name` 是 `text` 字段，写入“无线办公键盘”后保存的是分析产生的词元，不一定存在完整的“无线办公键盘”词项。精确匹配应查询 `.keyword` 子字段或明确的 `keyword` 字段；本章的 `brand`、`category` 和 `tags` 就是 `keyword` 字段。

## 3. 全文查询

全文查询（full-text query）也是一类查询，不只包括下面重点讲解的 `match`、`match_phrase` 和 `multi_match`。它们主要用于分析过的 `text` 字段，会先使用字段的搜索分析器处理输入文本，再用得到的词元构造查询；这正是它们与词项级查询的主要区别。

与“词项级”一样，“全文”描述的是查询如何处理文本，并不决定执行上下文。全文查询通常放在 `must` 或 `should` 中计算相关性；虽然也能放在 `filter` 中只判断是否匹配，但这样会丢弃它原本可以提供的相关性分数。

Elasticsearch 当前主要的全文查询包括：

| 查询                  | 作用                                                 | 典型用途或注意点                                           |
| --------------------- | ---------------------------------------------------- | ---------------------------------------------------------- |
| `match`               | 分析并匹配单个字段中的查询文本                       | 最常用的单字段全文查询                                     |
| `match_phrase`        | 按词元顺序和相对位置匹配短语                         | 精确短语或允许少量间隔的近似短语                           |
| `multi_match`         | 将 `match` 扩展到多个字段                            | 同时搜索名称、描述等字段并设置字段权重                     |
| `combined_fields`     | 将多个文本字段视为一个组合字段进行匹配               | 查询词可能分布在多个字段时使用，要求字段使用兼容的分析方式 |
| `match_bool_prefix`   | 除最后一个词元使用前缀匹配外，其余词元按普通词项匹配 | 搜索框输入过程中的按词前缀匹配                             |
| `match_phrase_prefix` | 在短语匹配基础上，将最后一个词元作为前缀             | 需要保持前面词元顺序的输入联想                             |
| `intervals`           | 精细控制词元的顺序、距离和包含关系                   | 对位置关系有复杂要求的高级文本检索                         |
| `query_string`        | 使用 Lucene 查询字符串语法表达字段、布尔和分组条件   | 功能强但语法复杂，更适合受信任的高级用户                   |
| `simple_query_string` | 使用容错更好的简化查询字符串语法                     | 需要向最终用户开放有限搜索语法时考虑                       |

本章重点展开最常用、也是理解其他全文查询基础的 `match`、`match_phrase` 和 `multi_match`。前缀联想、复杂位置约束和用户查询语法只在这里建立分类认知，实际使用时应再结合字段映射、输入来源和性能要求选择。

### 3.1 单字段全文查询：`match`

`match` 是最基础的全文查询，它针对一个字段分析并匹配查询文本。查询“无线机械键盘”时，当前 `standard` 分析器会得到：

```text
无、线、机、械、键、盘
```

先使用默认的 OR 操作符：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "query": {
    "match": {
      "description": "无线机械键盘"
    }
  }
}
```

可以把它概念化为：

```text
description:无 OR description:线 OR description:机 OR
description:械 OR description:键 OR description:盘
```

只要匹配至少一个词元，文档就可以进入结果集。因此初始化的五条文档都会命中：即使 `p1004` 的描述是“有线键盘”，也包含“线”“键”“盘”。匹配词元越多、词元区分度越高，通常 `_score` 越高，但分数还会受到字段长度等因素影响。

如果业务要求所有查询词元都出现，可以设置 `operator: "and"`：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "query": {
    "match": {
      "description": {
        "query": "无线机械键盘",
        "operator": "and"
      }
    }
  }
}
```

此时条件相当于“无 AND 线 AND 机 AND 械 AND 键 AND 盘”，只返回包含全部六个词元的 `p1001` 和 `p1003`。若 OR 太宽、AND 又太严格，可以使用 `minimum_should_match` 指定至少需要匹配的词元数量或比例。

对同一个 `text` 字段，`term` 和 `match` 的差异可以概括为：

| 写法                       | 是否分析“无线机械键盘”        | 本例结果                     |
| -------------------------- | ----------------------------- | ---------------------------- |
| `term` 查询 `description`  | 否，直接查找完整词项          | 找不到完整词项，通常没有结果 |
| `match`，默认 OR           | 是，得到六个词元并按 OR 组合  | 五条文档都能匹配部分词元     |
| `match`，`operator: "and"` | 是，得到六个词元并按 AND 组合 | `p1001`、`p1003`             |

### 3.2 短语查询：`match_phrase`

`match_phrase` 同样会分析查询文本，但还会检查词元的顺序和相对位置。下面要求“无线键盘”的四个词元连续出现：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "query": {
    "match_phrase": {
      "description": {
        "query": "无线键盘",
        "slop": 0
      }
    }
  }
}
```

`slop: 0` 不允许额外的位置间隔，因此只有描述包含连续“无线键盘”的 `p1002` 命中。`p1001` 和 `p1003` 是“无线机械键盘”，`p1005` 是“无线办公键盘”，查询词元之间都多了两个词元。

如果把 `slop` 改为 `2`，允许这两个额外位置后，`p1001`、`p1002`、`p1003` 和 `p1005` 都可以匹配。相比之下，`match` 配合 `operator: "and"` 只要求所有词元存在，不要求顺序相同或距离足够近。

`slop` 是整次短语匹配允许的最大位置编辑距离，不是每两个相邻查询词元都可以分别间隔 `slop` 个位置。对于词序不变、只是在中间插入其他词元的常见情况，可以把它理解为整条短语共同使用的间隔预算。例如：

```text
查询词元：A B C D
文档词元：A X B Y C Z D
```

三个间隔中各插入了一个词元，但不是设置 `slop: 1` 就能让每个间隔各放一个；整条短语一共偏离三个位置，需要 `slop` 至少为 `3`。词序交换也会消耗位置编辑距离，例如相邻的 `A B` 变成 `B A` 需要 `slop: 2`。因此不要把 `slop` 简单理解为“每个词元之间最多允许几个词”，应把它理解为整次短语对齐的最大位置偏差；偏差更小的短语匹配通常也会得到更高分数。

### 3.3 多字段全文查询：`multi_match`

`multi_match` 可以理解为把同一份 `match` 查询应用到多个字段。下面仍使用“无线机械键盘”作为查询文本：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
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

#### 每个字段先单独匹配和评分

在 `best_fields` 模式下，Elasticsearch 会为每个字段分别生成一个 `match` 子查询，再用 `dis_max` 查询合并它们。前面的 `multi_match` 可以概念化为：

```json
{
  "dis_max": {
    "queries": [
      { "match": { "name": { "query": "无线机械键盘", "boost": 3 } } },
      { "match": { "description": { "query": "无线机械键盘" } } },
      { "match": { "tags": { "query": "无线机械键盘", "boost": 2 } } }
    ],
    "tie_breaker": 0.2
  }
}
```

一次搜索中，每个字段会先得到自己的子分数，但这些子分数不会作为独立字段直接出现在普通搜索响应中：

1. `name` 和 `description` 各自使用自己的分析器分析查询文本；`tags` 是 `keyword` 字段，会把整段查询文本视为一个词项。
2. 每个字段上的 `match` 独立计算 BM25 分数。词频、文档频率和字段长度等统计量都以对应字段为范围，因此同一个词元在 `name` 和 `description` 中的原始分数不一定相同。
3. 字段权重随后作用于对应的子分数：`name^3` 将 `name` 子分数乘以 3，`description` 保持默认权重 1，`tags^2` 将 `tags` 子分数乘以 2。
4. `dis_max` 根据 `best_fields` 和 `tie_breaker` 将各字段子分数合并成最终 `_score`。

本例的中文查询不会匹配英文 `tags` 值，所以 `tags^2` 不会产生分数；字段权重再高，也不能让原本不匹配的字段获得分数。

#### `best_fields` 与 `tie_breaker` 如何计算

设应用字段权重后的三个子分数分别为：

```text
S_name、S_description、S_tags
```

`best_fields` 使用的合并公式可以写成：

```text
最终分数 = 最高子分数
         + tie_breaker × 其他所有匹配字段的子分数之和
```

也就是：

```text
S_final = max(S_i) + tie_breaker × (sum(S_i) - max(S_i))
```

`tie_breaker` 的典型取值含义是：

| `tie_breaker` | 合并方式                               |
| ------------- | -------------------------------------- |
| `0.0`         | 只采用最高的字段子分数，这也是默认值   |
| `0.2`         | 最高子分数加上其他匹配字段子分数的 20% |
| `1.0`         | 将所有匹配字段的子分数相加             |

它虽然名为“平局裁决”，但不只在两个字段分数恰好相等时生效；只要同一文档匹配多个字段，其他字段就会按该比例贡献额外分数。

下面用一组示意数字计算 `p1001`。这些数字只用于展示公式，实际 BM25 分数要以本地 `_explain` 输出为准：

| 字段          | 假设的原始 BM25 分数 | 字段权重 | 应用权重后的子分数 |
| ------------- | -------------------: | -------: | -----------------: |
| `name`        |                 1.20 |        3 |               3.60 |
| `description` |                 2.00 |        1 |               2.00 |
| `tags`        |                    0 |        2 |                  0 |

最高子分数是 `name` 的 3.60，其他匹配字段只有 `description`，因此：

```text
tie_breaker = 0.0：3.60
tie_breaker = 0.2：3.60 + 0.2 × 2.00 = 4.00
tie_breaker = 1.0：3.60 + 1.0 × 2.00 = 5.60
```

`tie_breaker` 还可能改变文档顺序。例如，文档 A 只在一个字段得到 5.00 分，文档 B 的最佳字段得到 4.60 分、另一个字段得到 3.00 分：

```text
tie_breaker = 0.0：A = 5.00，B = 4.60，A 排在前面
tie_breaker = 0.2：A = 5.00，B = 4.60 + 0.2 × 3.00 = 5.20，B 排在前面
```

这体现了 `best_fields` 的意图：仍然以表现最好的单个字段为主，但可以适度奖励同时匹配其他字段的文档。它不同于 `most_fields`；后者的主要目的就是把多个字段的分数相加。

#### 查看本地真实计算过程

使用 `_explain` 可以看到 `p1001` 的真实字段子分数以及 `dis_max` 的合并过程：

```http
GET /query-dsl-products/_explain/p1001?filter_path=matched,explanation
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

在 `explanation.details` 中可以逐层查看 `name`、`description` 的 BM25 计算、字段 boost 和类似“最高分加其他分数的 0.2 倍”的 `dis_max` 说明。普通搜索返回的 `_score` 就是这些步骤合并后的最终结果。

这个查询没有设置 `operator`，所以各字段上的 `match` 默认使用 OR。文档只要在任一字段中匹配部分查询词元就可能进入结果集；因此五条文档都会命中。

`operator` 不是 `best_fields` 的子参数。它和 `type` 都直接属于 `multi_match`，语法层级如下：

```json
{
  "multi_match": {
    "query": "无线机械键盘",
    "fields": ["name^3", "description", "tags^2"],
    "type": "best_fields",
    "operator": "and"
  }
}
```

`type: "best_fields"` 选择多字段查询的执行模式；同级的 `operator: "and"` 控制查询词元如何组合。在 `best_fields` 模式下，Elasticsearch 会为每个字段分别生成 `match` 子查询，因此这个 `operator` 会分别应用到每个字段，而不是跨字段统一应用。所有查询词元需要在同一个候选字段中匹配，本例将只留下 `description` 包含全部词元的 `p1001` 和 `p1003`。

如果业务含义是“查询词可以分散在多个字段中”，应考虑词项中心的 `combined_fields`，而不是在采用 `best_fields` 模式的 `multi_match` 中设置 `operator: "and"`。

## 4. 组合查询与加权

`bool` 是复合查询（compound query），负责组合其他查询子句，本身不属于全文查询类别。它既可以组合 `match`、`match_phrase` 等全文查询，也可以组合 `term`、`range` 等词项级查询。

下面是一个综合示例：先用全文查询进行宽泛召回，再使用短语和品牌条件为部分商品加分。

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
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

这个查询把“必须满足的召回条件”和“用于加分的偏好条件”分开：

| 子句                  | 本例作用                                           | 匹配情况                                                   |
| --------------------- | -------------------------------------------------- | ---------------------------------------------------------- |
| `must.match`          | 使用默认 OR 召回描述中含任一查询词元的文档         | 五条文档都能匹配“线”“键”“盘”等部分词元                     |
| `should.match_phrase` | 奖励按顺序匹配“无线机械键盘”的文档                 | `p1001`、`p1003` 中存在连续短语，即使 `slop` 为 0 也能匹配 |
| `should.term`         | 奖励品牌精确等于 `KeyWorks` 的文档，并应用两倍权重 | `p1001`、`p1002`                                           |

这里显式设置了 `minimum_should_match: 0`，因此两个 `should` 都是可选的：`p1004`、`p1005` 即使不满足任何加分条件，也不会被排除。`p1001` 同时命中短语和品牌条件，会从两处获得额外分数。若改为 `minimum_should_match: 1`，文档必须至少满足一个 `should`，结果集将缩小为 `p1001`、`p1002` 和 `p1003`。

这个例子也说明 `term` 并不天然等于过滤。这里的品牌 `term` 位于 `should`，所以运行在查询上下文并参与评分；只有放在 `filter` 或 `must_not` 等过滤位置时，它才不计算分数。

## 5. 不要默认开放的查询

某些 Query DSL 子句功能很强，但成本或输入风险也更高：

| 查询方式                                        | 主要风险                                                              | 更稳妥的处理                                                             |
| ----------------------------------------------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| 前缀、以 `*` 开头的通配符、正则表达式、模糊查询 | 在字段映射或模式不合适时，可能枚举或比较大量词项，消耗较多 CPU 和内存 | 限定允许搜索的字段、模式长度和扩展数量；固定前缀需求应考虑适合的字段设计 |
| `query_string`                                  | 最终用户输入会被解释成查询语法，特殊字符可能报错或意外改变逻辑        | 由服务端构造固定 DSL；确需简化语法时评估 `simple_query_string`           |
| 脚本查询                                        | 可能对大量候选文档逐条执行脚本                                        | 优先在写入时计算并索引可查询字段，或先用普通过滤条件缩小候选集           |

对外搜索接口应在服务端固定允许的字段、操作符、页大小和超时，而不是原样转发任意查询 DSL。

## 6. 验证查询

### 6.1 只检查查询能否构造

先调用 Validate Query API，不实际执行搜索：

```http
GET /query-dsl-products/_validate/query
{
  "query": {"match": {"description": {"query": "无线键盘", "operator": "and"}}}
}
```

响应类似下面这样：

```json
{
  "_shards": {
    "total": 1,
    "successful": 1,
    "failed": 0
  },
  "valid": true
}
```

这里的 `valid` 是 Elasticsearch 返回的响应字段：

- `valid: true` 表示 Query DSL 能被解析，并能针对当前索引映射构造成查询。
- `valid: false` 表示查询无法构造；配合 `explain=true` 可以在响应的 `error` 或 `explanations[].error` 中查看原因。
- `_shards` 表示查询验证在哪些分片上成功或失败，不是搜索命中的文档数量。

Validate Query API 不返回 `hits`，也不会证明查询一定能命中文档。例如，查询一个不存在的词仍可能得到 `valid: true`，因为查询结构本身是有效的。

### 6.2 查看生成的底层查询

`explain` 和 `rewrite` 是 Validate Query API 的两个不同参数：

- `explain=true` 主要用于返回查询无效的具体原因，也可以返回查询的说明字符串。
- `rewrite=true` 返回更详细的、实际准备交给 Lucene 执行的查询表示。
- `all_shards=true` 在所有分片上验证。某些查询的改写结果可能依赖分片中的词项，因此查看改写结果时通常与 `rewrite=true` 一起使用。本章索引只有一个分片，所以只会得到一份说明。

执行：

```http
GET /query-dsl-products/_validate/query?rewrite=true&all_shards=true
{
  "query": {"match": {"description": {"query": "无线键盘", "operator": "and"}}}
}
```

省略 `_shards` 后，响应中的关键部分类似：

```json
{
  "valid": true,
  "explanations": [
    {
      "index": "query-dsl-products",
      "shard": 0,
      "valid": true,
      "explanation": "+description:无 +description:线 +description:键 +description:盘"
    }
  ]
}
```

这里所说的“改写”不是 Elasticsearch 修改了提交的 JSON，也不是修改索引数据，而是把面向用户的 Query DSL 转换成可以执行的底层 Lucene 查询。本例经历的关键步骤是：

1. `match` 使用 `description` 的 `standard` 分析器处理“无线键盘”。
2. 得到“无”“线”“键”“盘”四个查询词元。
3. `operator: "and"` 将四个词元构造成必须全部匹配的布尔查询。
4. `explanation` 使用 Lucene 的文本形式表示这个查询；每个 `+` 表示对应词项是必须匹配的条件。

对模糊、前缀、同义词或其他复杂查询，底层查询还可能包含词项扩展、子查询组合等结果，因此 `rewrite=true` 常用于确认高层 DSL 最终变成了什么查询。

## 7. 解释查询结果

Explain API 是独立于 Validate Query API 的另一个接口。它不是继续“验证查询”，而是针对指定文档执行查询，并解释该文档为什么匹配或不匹配、最终分数是如何计算出来的。

要分析 `p1001`，执行：

```http
GET /query-dsl-products/_explain/p1001
{
  "query": {"match": {"description": {"query": "无线键盘", "operator": "and"}}}
}
```

本例的关键响应字段是：

| 响应字段                  | 本例预期             | 含义                                        |
| ------------------------- | -------------------- | ------------------------------------------- |
| `_index`                  | `query-dsl-products` | 被解释文档所在的索引                        |
| `_id`                     | `p1001`              | 被解释的文档标识                            |
| `matched`                 | `true`               | 该文档是否满足整个查询                      |
| `explanation.value`       | 以实际浮点数为准     | 该文档的最终 `_score`                       |
| `explanation.description` | 一段计算说明         | 当前层级如何得到该分数                      |
| `explanation.details`     | 嵌套数组             | 各词元的 boost、IDF、词频和字段长度等子计算 |

三个相关功能的区别可以概括为：

| 功能                           | 回答的问题                                 | 是否针对具体文档 |
| ------------------------------ | ------------------------------------------ | ---------------- |
| `_validate/query`              | 这个 Query DSL 能否构造成查询？            | 否               |
| `_validate/query?rewrite=true` | 这个 DSL 最终会生成什么底层 Lucene 查询？  | 否               |
| `_explain/{id}`                | 指定文档为什么匹配或不匹配，分数如何计算？ | 是               |

`_explain` 输出很详细，执行也有成本，只适合针对少量代表性文档抽样调试，不要在普通搜索请求中批量调用。

## 练习与验收

- 写一个“有货、100-500 元、商品描述匹配无线键盘”的查询。
- 在上一题基础上为 `KeyWorks` 品牌加权，但不能排除其他品牌。
- 说明过滤条件为什么通常不应该放在 `must` 中参与评分。
- 将第 4 节的 `minimum_should_match` 分别设置为 `0` 和 `1`，对比返回的文档集合和 `_score`。

上一节：[08｜分词](./08-analysis-and-chinese-text.md)｜下一节：[10｜相关性与分页](./10-relevance-sort-pagination.md)
