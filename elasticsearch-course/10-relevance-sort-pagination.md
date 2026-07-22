# 10｜相关性、排序、分页与高亮

## 本节目标

- 理解 `_score` 的基本来源和相关性调优流程。
- 正确处理排序、浅分页和深分页。
- 使用高亮、字段裁剪和搜索超时。

## 操作环境与实验数据

本章继续使用第 09 章创建的 `query-dsl-products` 索引及其中的五条商品文档。开始前先确认实验数据仍然存在：

```http
GET /query-dsl-products/_count
```

预期返回 `"count": 5`。如果索引不存在或数量不是 5，请重新执行第 09 章“操作环境与实验数据”中的初始化脚本，再运行本章示例。不要改用第 07 章重建的 `products` 索引；那个索引用于映射实验，不保证保留商品测试数据。

## 1. 相关性基础

相关性表示文档内容与用户查询的匹配程度。对于会计算相关性的查询，Elasticsearch 会为每个匹配文档生成 `_score`；分数越高，通常表示该文档与本次查询越相关。

全文检索默认使用 BM25 算法计算分数，主要考虑以下因素：

- 词频：查询词在字段中出现得越多，通常越相关，但其贡献会逐渐减弱。
- 逆文档频率：衡量查询词在整个文档集合中的稀有程度；包含该词的文档越少，它区分文档的作用通常越大。
- 字段长度：在其他条件相近时，查询词出现在较短字段中通常更突出。

`_score` 是相对分数，适合比较同一次查询返回的文档。索引中的文档、字段映射、分析器或相关性算法配置发生变化后，词频等统计信息和最终得分也可能改变。因此，不应跨查询或跨索引直接比较 `_score`，也不应把它作为稳定的业务分值持久化。

调优顺序：

1. 先解决映射、分析器和数据质量问题。
2. 准备“查询 → 期望结果”的标注集。
3. 再调整字段权重、短语匹配策略（例如使用 `match_phrase` 优先匹配词序一致且位置相邻的“机械键盘”）和业务信号（例如库存、发布时间和销量）。
4. 对比离线指标和线上点击/转化，控制实验变量。

BM25 主要反映文本的匹配程度，并不了解商品是否有库存、是否刚刚上架等业务信息。文本相关性调优稳定后，可以使用函数评分查询（`function_score`）把这些业务信号加入排序。下面的查询先匹配名称中包含“键盘”的商品，再提高有库存商品的分数，并让发布时间越久的商品获得越明显的时间衰减：

```http
POST /query-dsl-products/_search
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

其中，`score_mode` 控制多个评分函数如何合并，`boost_mode` 控制函数分数如何与原始查询分数合并；此处均使用乘法。

## 2. 排序

```http
POST /query-dsl-products/_search
{
  "query": {"match": {"name": "键盘"}},
  "sort": [
    {"_score": "desc"},
    {"price": "asc"},
    {"product_id": "asc"}
  ]
}
```

最后放置唯一且稳定的字段作为平局裁决字段，例如这里的 `product_id`。这样，即使两个商品的 `_score` 和 `price` 都相同，它们仍然有确定的先后顺序。

除 `_score` 等特殊排序项外，普通字段排序通常依赖列式文档值（doc values）。普通 JSON 文档以“文档”为单位保存数据，而 doc values 会在建立索引时按“字段”组织值：可以把它简单理解为把所有文档的 `price` 放在一列、所有文档的 `product_id` 放在另一列。排序时，Elasticsearch 可以直接读取某一字段对应的这一列数据，而不必逐个解析文档的 `_source`。大多数 `keyword`、数值、日期等字段默认都会建立 doc values，适合排序和聚合。

`text` 字段主要用于全文检索。它的内容会被分析器拆成多个词元，默认不建立 doc values，因此不适合直接排序。字段数据（fielddata）是一种补救机制：它会根据 `text` 字段的倒排索引，在 Java 堆内存中临时构建可供排序和聚合使用的数据结构，可能占用大量内存，而且按分词后的词元排序通常也不符合业务含义。因此，不要仅为了排序而给 `text` 字段开启 fielddata；应为它定义 `keyword` 子字段，例如使用 `name` 进行全文检索，使用 `name.keyword` 按未分词的完整名称排序。

## 3. 分页

“浅分页”和“深分页”描述的是访问位置的深浅，不是两个严格绑定的 API 名称：

- `from + size` 是偏移量分页。`from` 表示跳过前多少条，`size` 表示本页取多少条。它适合靠近结果集开头的浅分页，也便于直接跳到指定页；理论上也能继续向后翻，但偏移量越大，资源开销越高，而且默认不能越过前 10,000 条结果。
- `search_after` 是游标分页。它不再从头跳过大量结果，而是根据上一页最后一条记录的排序值继续向后取，因此更适合深分页；代价是通常只能按顺序向后翻，不能仅凭页码直接跳到任意页。
- PIT 不是分页器，也不保存上一次查询返回的结果列表。它固定的是创建 PIT 时可见的索引数据视图，避免分页期间的新增、删除或刷新改变排序结果。`search_after` 可以不配 PIT 使用，但深分页时通常将两者结合，以同时获得较低的分页开销和一致的结果视图。

PIT 固定的不是“上一条查询”，而是执行 `POST /索引名/_pit` 那一刻的索引视图。例如：

1. 10:00 创建 PIT，此时索引中有文档 A、B、C。
2. 10:01 使用该 PIT 查询第 1 页，查询看到 A、B、C。
3. 10:02 实时索引新增 D、删除 C，并完成刷新使这些变化对普通搜索可见。
4. 10:03 继续使用同一 PIT 查询第 2 页，查询仍基于 10:00 的视图：看不到 D，仍能看到当时的 C。
5. 如果此时重新创建一个 PIT，新 PIT 才会基于最新可见的索引状态。

PIT ID 本身不记录查询条件，因此同一个 PIT 技术上可以执行不同查询；但是使用 `search_after` 连续翻页时，必须保持 `query` 和 `sort` 不变，否则游标就不再对应同一套有序结果。

使用 `from + size` 进行浅分页：

```http
POST /query-dsl-products/_search
{
  "from": 0,
  "size": 20,
  "query": {"match_all": {}},
  "sort": [{"created_at":"desc"},{"product_id":"asc"}]
}
```

`from + size` 越大，每个分片需要保留的候选结果就越多。交互式深分页应使用时间点视图（Point in Time，PIT）配合 `search_after`：

```http
POST /query-dsl-products/_pit?keep_alive=1m
```

得到 PIT 标识后：

```http
POST /_search
{
  "size": 2,
  "pit": {"id": "替换为PIT_ID", "keep_alive": "1m"},
  "query": {"match_all": {}},
  "sort": [
    {"created_at":{"order":"desc","format":"strict_date_optional_time"}},
    {"product_id":"asc"}
  ]
}
```

虽然使用 PIT 时请求路径写作 `/_search`，但它不会搜索所有索引。创建 PIT 的请求是 `POST /query-dsl-products/_pit`，因此 PIT ID 标识的是该索引在创建 PIT 时的数据视图；它记录了“去哪个索引视图中查”，但没有记录“要用什么条件查”。后面的搜索请求才提供查询条件：

- `pit.id` 指定数据范围，即 `query-dsl-products` 在创建 PIT 时可见的五条文档。
- `query` 指定匹配规则。这里的 `match_all` 从这五条文档中匹配全部文档；如果改成查询 `name` 中的“键盘”，就只会匹配该 PIT 视图中名称符合条件的文档。
- `size: 2` 只限制本页最多返回两条，不会把 PIT 中的数据视图缩减为两条。

因此，可以把这次请求理解成：“在 PIT 固定的五条文档中执行 `match_all`，排序后返回前两条。”如果省略 `query`，空搜索也会采用全量匹配行为，但显式写出 `match_all` 更容易看清 PIT、查询条件和分页大小各自的职责。

上面的第一次搜索请求返回第 1 页。响应中的每一条命中文档都会带有一个 `sort` 数组，其元素与请求中的排序字段按顺序对应。准备请求第 2 页时，需要找到第 1 页响应中 `hits.hits` 数组的最后一个元素；按本章示例，它可以简化表示为：

```json
{
  "_source": { "product_id": "p1004", "created_at": "2026-07-12T11:00:00Z" },
  "sort": ["2026-07-12T11:00:00.000Z", "p1004", 3]
}
```

按示例数据和排序规则，第 1 页依次是 `p1005`、`p1004`，所以最后一条是 `p1004`。`sort` 的前两个值分别是该文档的 `created_at` 和 `product_id`；使用 PIT 时，Elasticsearch 还会自动在末尾加入 `_shard_doc` 作为内部平局裁决值。上面的 `3` 只是示例，实际值应以响应为准。客户端不需要计算这些值，只需原样复制 `p1004` 的完整 `sort` 数组，并把它作为 `search_after` 放入第 2 页请求：

```http
POST /_search
{
  "size": 2,
  "pit": {"id": "替换为最新的PIT_ID", "keep_alive": "1m"},
  "query": {"match_all": {}},
  "sort": [
    {"created_at":{"order":"desc","format":"strict_date_optional_time"}},
    {"product_id":"asc"}
  ],
  "search_after": ["2026-07-12T11:00:00.000Z", "p1004", 3]
}
```

`search_after` 可以理解为一个游标，含义是“从这条排序记录之后继续取 2 条”，而不是“跳过多少条”。按本章的五条实验数据，第二页应返回 `p1003`、`p1002`。下一页必须保持与上一页相同的查询条件和 `sort` 顺序；数组中值的数量、顺序和类型也不能自行修改。

使用 PIT 执行搜索时，响应中可能出现一个与请求值不同的最新 `pit_id`。这个新 ID **不表示 Elasticsearch 按本次搜索的时间重新冻结了最新数据**；它仍然指向最初创建 PIT 时的同一个逻辑数据视图。PIT ID 是 Elasticsearch 用来定位内部搜索上下文的不透明标识，应用程序不应解析它，也不应假设它始终不变。搜索请求中的 `keep_alive` 只是延长该视图的有效期，同样不会改变视图中的数据。

例如，10:00 创建 PIT 时得到 ID-A，视图中有 A、B、C；第 1 页响应可能返回 ID-B。即使实时索引随后新增 D，使用 ID-B 请求第 2 页时仍然只能看到 10:00 的 A、B、C。只有再次执行 `POST /query-dsl-products/_pit`，才会创建一个基于当前可见数据的新 PIT 视图。

因此，每次搜索后都应检查响应中的最新 `pit_id`：如果返回了新值，下一页请求以及最终的关闭请求都使用这个最新值；即使实际运行时 ID 没有变化，也不要让程序依赖“不变化”这一现象。

PIT 会在最后一次设置或续期的 `keep_alive` 到期后自动关闭，因此显式删除不是保证正确性的必需步骤。这里每次搜索都设置 `keep_alive: "1m"`，会把 PIT 的存活时间延长到足以等待下一次请求。尽管如此，打开的 PIT 会让 Elasticsearch 暂时保留旧索引段，并占用磁盘、文件句柄和堆内存等资源；如果分页提前结束，生产代码应主动关闭它，而不必等待自动过期：

```http
DELETE /_pit
{"id":"替换为最近一次响应中的PIT_ID"}
```

课程中的短时实验即使不执行删除请求，PIT 通常也会在一分钟后自动关闭；显式删除主要用于演示完整的资源管理流程。

批量导出优先使用 PIT 与 `search_after`；滚动搜索（scroll）主要用于需要固定快照的既有批处理场景，不用于用户翻页。

## 4. 高亮与响应裁剪

```http
POST /query-dsl-products/_search
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

这段请求同时演示了命中数量、响应字段、高亮片段和执行时间四类控制，它们的职责不同：

- `size: 10`：最多返回 10 条命中文档。
- `_source: ["product_id","name","price","stock"]`：对每条命中的 `_source` 做响应裁剪，只返回页面需要的四个业务字段。它不会删除索引中的其他字段，也不会改变查询匹配结果。虽然 `description` 没有出现在返回的 `_source` 中，Elasticsearch 仍可在内部读取它并生成高亮结果。
- `highlight`：在每条命中的独立 `highlight` 对象中返回匹配位置附近的文本片段，而不是修改 `_source.description`。
- `timeout: "2s"`：限制搜索请求的执行等待时间，用于避免请求运行过久，不属于响应字段裁剪。

### `_source` 与 `filter_path` 的区别

两者都能让客户端收到的响应变小，但作用于不同阶段：

```text
搜索 API 取回命中文档
    ↓
_source 参数决定每条命中的源文档是“完整、部分还是不返回”
    ↓
Elasticsearch 组装 took、_shards、hits、highlight、aggregations 等完整响应
    ↓
filter_path 对整个响应 JSON 做最后的路径保留或排除
    ↓
返回客户端
```

因此，如果请求体已经设置：

```json
"_source": ["name", "price"]
```

同时请求地址设置：

```http
?filter_path=hits.hits._source
```

最终 `_source` **只会包含 `name` 和 `price`**，不会恢复成完整文档。`filter_path` 保留的是经过 `_source` 参数处理后的结果。

假设原始 `_source` 有 `product_id`、`name`、`price`、`stock` 和 `description` 五个字段，四种组合的区别如下：

| 请求设置                               | 最终响应结构                              | 每条命中的 `_source`   |
| -------------------------------------- | ----------------------------------------- | ---------------------- |
| 两者都不设置                           | 保留 `took`、`_shards`、`hits` 等完整结构 | 五个字段全部返回       |
| 只设置 `_source: ["name","price"]`     | 仍保留完整响应结构                        | 只返回 `name`、`price` |
| 只设置 `filter_path=hits.hits._source` | 只保留通向 `_source` 的响应结构           | 仍返回五个字段         |
| 两者同时设置                           | 只保留通向 `_source` 的响应结构           | 只返回 `name`、`price` |

两者各自不可替代的场景是：

- `_source` 不可替代：当业务只需要商品的 `name`、`price`，或者完全不需要原始文档而设置 `_source: false` 时，必须把这个意图告诉搜索或获取文档 API。`filter_path` 只在最终响应层隐藏路径，不等同于要求搜索 API 不取回 `_source`。此外，部分 API 会把 `_source` 作为原始 JSON 值直接写入响应，因此不要依赖 `filter_path=hits.hits._source.name` 之类的路径深入选择源字段；应使用专门的 `_source` 过滤。
- `filter_path` 不可替代：当需要去掉 `_source` 以外的 `took`、`_shards`、`hits.total`、聚合结果的一部分，或者需要裁剪集群健康、Bulk 等根本没有 `_source` 的 API 响应时，`_source` 参数无能为力，只能使用 `filter_path`。

需要同时精简两层时就组合使用。例如：

```http
POST /query-dsl-products/_search?filter_path=hits.hits._id,hits.hits._source,hits.hits.highlight
{
  "_source": ["product_id","name","price","stock"],
  "query": {"match": {"description": "无线机械键盘"}},
  "highlight": {"fields": {"description": {}}}
}
```

这里 `_source` 决定每条命中的业务数据只包含四个字段；`filter_path` 则把整个响应最外层的 `took`、`timed_out`、`_shards`、`hits.total` 等路径省略，只保留命中的 `_id`、裁剪后的 `_source` 和 `highlight`。如果 `filter_path` 没有包含 `hits.hits.highlight`，高亮即使已经生成，也不会出现在返回给客户端的 JSON 中。

下面继续解释本节开头请求中的高亮参数。该请求没有设置 `filter_path`，所以实际响应仍会包含 `took`、`_shards`、`hits.total` 等结构。为了突出 `_source` 与 `highlight` 的关系，下面仅截取 `hits.hits` 数组中的一条命中，并对其进行简化展示。`<em>` 标签的具体位置和拆分方式会受分析器与高亮器影响；这个示例只用于说明响应结构，实际标签形式未必完全相同：

```json
{
  "_source": {
    "product_id": "p1003",
    "name": "无线游戏键盘",
    "price": 459.0,
    "stock": 2
  },
  "highlight": {
    "description": ["……<em>命中词元</em>……"]
  }
}
```

从这条命中可以看出，`_source` 和 `highlight` 是两个并列对象：`_source` 列表决定返回哪些完整业务字段；高亮参数则决定一个长文本字段返回多少段、每段多长的摘要。它们分别控制业务字段和高亮摘要，互不替代。

上面的“命中词元”是结构占位符，不代表 Elasticsearch 一定会把原文中的某一整段文字作为一个整体包在 `<em>` 中。标签位置主要按以下过程确定：

1. 查询文本先按照字段的搜索分析器拆成词元。例如，`match` 查询中的“无线机械键盘”会按照 `description` 字段使用的分析器进行处理。
2. 高亮器从查询中提取需要高亮的词元或短语，并找出它们在原文中的起止字符偏移量（`start_offset`、`end_offset`）。偏移量可能来自倒排索引、词项向量，或者由高亮器重新分析原文得到。
3. 高亮器在这些字符范围前后插入 `pre_tags` 和 `post_tags`。默认标签分别是 `<em>` 和 `</em>`，也可以在高亮配置中改成其他标签。

因此，标签插入在哪里主要取决于查询类型、字段分析器产生的词元、匹配偏移量以及所用高亮器。本例没有指定高亮器 `type`，因此使用默认的 `unified` 高亮器。`fragment_size` 只影响截取多长的上下文，`number_of_fragments` 只影响最多返回几段；它们不直接决定 `<em>` 包住哪些字符。相邻的多个查询词元可能分别产生多个相邻标签，复杂布尔查询的高亮结果也不一定能完全复现查询的布尔判断过程，所以应以实际响应为准。

可以使用 `_analyze` 查看本章 `description` 字段如何拆分查询文本以及各词元的偏移量：

```http
POST /query-dsl-products/_analyze
{
  "field": "description",
  "text": "无线机械键盘"
}
```

- `fragment_size: 80`：每个高亮片段的目标长度为 80 个字符。高亮器会尽量在词语或句子边界附近截断，因此实际长度不一定恰好是 80。
- `number_of_fragments: 2`：每条命中文档的 `description` 字段最多返回两个高亮片段。若查询词出现在文章多个位置，可以用两段上下文展示不同命中位置；不足两段时只返回实际生成的数量。

如果将 `number_of_fragments` 设为 `0`，Elasticsearch 会返回高亮后的整个字段内容，此时 `fragment_size` 会被忽略。这通常只适合标题、地址等较短字段，不适合很长的正文。

默认情况下，命中的文本会由 `<em>` 和 `</em>` 包裹。将高亮内容插入网页前仍需采用安全的输出方式；不要因为标签由 Elasticsearch 添加，就信任源文档中的其他 HTML 内容。

## 练习与验收

- 实现按相关性、价格、唯一标识的稳定排序。
- 用 PIT 和 `search_after` 连续获取两页且不重复。
- 只在 `_source` 中返回页面需要的 `product_id`、`name`、`price`、`stock` 4 个字段，并为 `description` 增加高亮。

上一节：[09｜查询语言](./09-query-dsl.md)｜下一节：[11｜聚合](./11-aggregations.md)
