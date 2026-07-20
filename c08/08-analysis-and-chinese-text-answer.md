# 08｜分析器、中文分词与多字段：练习与验收答案

建议先独立完成练习，再使用本页核对分析结果和字段使用方式。以下标记为 `http` 的请求都在 Kibana 的开发工具（Dev Tools）中的控制台（Console）执行；词元结果可能受 Elasticsearch 版本和所选分析器影响，验收时应以当前集群的 `_analyze` 响应为准。

## 1. 比较标准分析器与关键词分词器

使用同一句文本分别执行两次 Analyze API：

```http
POST /_analyze
{
  "analyzer": "standard",
  "text": "USB-C Dock for MacBook Pro"
}
```

标准分析器会切分文本并将英文词元转换为小写，预期得到类似以下词元：

```text
位置 0：usb
位置 1：c
位置 2：dock
位置 3：for
位置 4：macbook
位置 5：pro
```

再使用关键词分词器处理相同文本：

```http
POST /_analyze
{
  "tokenizer": "keyword",
  "text": "USB-C Dock for MacBook Pro"
}
```

`keyword` 分词器不会按空格或连字符切分输入，预期只产生一个词元：

```text
位置 0：USB-C Dock for MacBook Pro
```

两次请求不能简单理解为“一个会分词、另一个完全不处理文本”。第一条请求指定的是完整的标准分析器，它包含分词器和小写词元过滤等处理；第二条请求只指定 `keyword` 分词器，没有配置小写词元过滤器，所以大小写保持不变。如果希望保留完整文本但统一为小写，可以显式增加过滤器：

```http
POST /_analyze
{
  "tokenizer": "keyword",
  "filter": ["lowercase"],
  "text": "USB-C Dock for MacBook Pro"
}
```

此时只产生一个词元：

```text
usb-c dock for macbook pro
```

验收时应能说明：标准分析器适合把自然语言文本转换为可全文检索的词元；关键词分词器把整段输入视为一个词元，适合观察完整值处理，但字段的精确匹配通常应直接使用 `keyword` 字段，而不是把 `text` 字段临时改用关键词分词器。

## 2. 解释 `name` 和 `name.raw` 的查询用途

正文中的多字段映射让同一个商品名称生成两个用途不同的索引字段：

| 字段       | 映射                           | 索引结果                                         | 适用操作                       |
| ---------- | ------------------------------ | ------------------------------------------------ | ------------------------------ |
| `name`     | `text`，使用 `standard` 分析器 | 原值被分析成多个词元                             | `match` 等全文查询和相关性评分 |
| `name.raw` | `keyword`                      | 在 `ignore_above` 限制内，将完整原值作为一个词项 | `term` 精确匹配、排序和聚合    |

对于以下文档：

```json
{
  "name": "USB-C Dock for MacBook Pro"
}
```

按词语进行全文检索时查询 `name`：

```http
GET /products-text-v1/_search
{
  "query": {
    "match": {
      "name": "macbook dock"
    }
  }
}
```

`match` 查询会使用字段的搜索分析器处理查询文本，再将查询词元与 `name` 的索引词元进行匹配，因此不要求查询文本与完整商品名称完全相同，并且可以计算相关性分数。

按完整原值进行精确匹配时查询 `name.raw`：

```http
GET /products-text-v1/_search
{
  "query": {
    "term": {
      "name.raw": "USB-C Dock for MacBook Pro"
    }
  }
}
```

`term` 查询不会像全文查询那样分析输入值。当前 `name.raw` 没有配置小写规范化器，因此大小写、空格和连字符都必须与索引中的完整词项一致。只查询 `MacBook` 或改写为全小写，均不能精确命中上面的 `name.raw`。

排序和聚合也使用 `name.raw`：

```http
GET /products-text-v1/_search
{
  "query": {
    "match_all": {}
  },
  "sort": [
    {"name.raw": "asc"}
  ],
  "aggs": {
    "product_names": {
      "terms": {"field": "name.raw"}
    }
  }
}
```

不应为了排序和聚合而直接使用 `name`。`text` 字段面向多个全文词元，默认也不提供适合这类操作的 doc values；使用 `name.raw` 可以保留稳定的完整值。`name.raw` 是索引层面的多字段，不需要在 `_source` 中重复写入。

验收时应能根据意图选择字段，而不是只记住后缀：按语义和词语搜索使用 `name`，按完整值判断、排序或分组使用 `name.raw`。如果需要不区分英文大小写的完整值匹配，则使用正文中配置了小写规范化器的 `name.lowercase`。

## 3. 为“蓝牙耳机”建立真实查询测试集

完整的检索测试集至少应包含三部分：固定的测试文档、真实用户查询，以及每条查询对应的相关性预期。只有查询词而没有文档和预期结果，无法判断分析器调整究竟改善还是破坏了搜索效果。

### 3.1 建立固定的测试语料

创建独立索引，避免测试数据和其他课程数据互相影响。这里先使用内置标准分析器作为基线；更换中文分析器后，应对同一批文档和查询重新测试并比较结果。

```http
DELETE /course-headphones-v1?ignore_unavailable=true

PUT /course-headphones-v1
{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0
  },
  "mappings": {
    "dynamic": "strict",
    "properties": {
      "name": {
        "type": "text",
        "analyzer": "standard"
      },
      "category": {
        "type": "keyword"
      }
    }
  }
}
```

写入 6 条覆盖核心商品、属性变体和干扰类目的测试文档：

```http
POST /_bulk?refresh=wait_for
{"index":{"_index":"course-headphones-v1","_id":"h001"}}
{"name":"主动降噪蓝牙耳机","category":"headphones"}
{"index":{"_index":"course-headphones-v1","_id":"h002"}}
{"name":"运动防水蓝牙耳机","category":"headphones"}
{"index":{"_index":"course-headphones-v1","_id":"h003"}}
{"name":"蓝牙5.3长续航耳机","category":"headphones"}
{"index":{"_index":"course-headphones-v1","_id":"h004"}}
{"name":"苹果手机兼容无线耳机","category":"headphones"}
{"index":{"_index":"course-headphones-v1","_id":"h005"}}
{"name":"有线监听耳机","category":"headphones"}
{"index":{"_index":"course-headphones-v1","_id":"h006"}}
{"name":"便携蓝牙音箱","category":"speakers"}
```

确认 6 条文档均已写入：

```http
GET /course-headphones-v1/_count
```

预期 `count` 为 `6`。

### 3.2 定义查询集和预期结果

下面的 8 条查询构成可实际验收的查询测试集。表格记录的是业务目标，不是标准分析器必然产生的基线结果。业务目标不应根据当前搜索结果反向修改；如果基线分析器没有达到目标，应记录失败，再调整分析器、同义词或查询策略。

| 编号 | 用户查询               | 业务上重点相关的文档                                | 业务上不应排在前列 | 测试目的                        |
| ---- | ---------------------- | --------------------------------------------------- | ------------------ | ------------------------------- |
| Q01  | `蓝牙耳机`             | `h001`、`h002`、`h003`；配置同义词后还应召回 `h004` | `h005`、`h006`     | 核心类目词及“蓝牙/无线”同义表达 |
| Q02  | `无线耳机`             | `h004`；配置同义词后还应召回 `h001`、`h002`、`h003` | `h005`、`h006`     | 同义词方向和召回范围            |
| Q03  | `降噪蓝牙耳机`         | `h001` 应排在首位                                   | `h005`、`h006`     | 功能属性与类目组合              |
| Q04  | `运动防水蓝牙耳机`     | `h002` 应排在首位                                   | `h005`、`h006`     | 多个连续属性词的切分与排序      |
| Q05  | `蓝牙耳机 续航长`      | `h003` 应排在首位                                   | `h005`、`h006`     | 空格、词序变化和长续航意图      |
| Q06  | `蓝牙5.3耳机`          | `h003` 应排在首位                                   | `h005`、`h006`     | 中文与版本号混合输入的词元边界  |
| Q07  | `苹果手机用的无线耳机` | `h004` 应排在首位                                   | `h005`、`h006`     | 口语化长查询和设备兼容性        |
| Q08  | `蓝牙音箱`             | `h006` 应排在首位                                   | `h001` 至 `h005`   | 与耳机共享“蓝牙”词元的干扰类目  |

Q01 和 Q02 特意把“当前基线结果”与“配置同义词后的业务目标”分开。使用标准分析器但没有同义词规则时，`蓝牙耳机` 和 `无线耳机` 不一定互相召回；测试集的作用正是暴露这种差距。

以 Q02 为例，标准分析器可能把 `无线耳机` 处理为 `无`、`线`、`耳`、`机`。`h005` 的“有线监听耳机”虽然不是无线耳机，却可能命中其中的 `线`、`耳`、`机`；加上示例 `match` 查询默认采用 OR 语义，它可能排在第二名。这表示当前基线没有达到“`h005` 不应排在前列”的业务目标，应在验收记录中判为失败，而不是把 `h005` 改成相关文档。

后续可以使用经过业务评估的中文分词器，使“无线”“有线”“耳机”等形成更合理的词元，再配置“无线耳机”和“蓝牙耳机”的同义词关系并重新运行同一测试集。也可以结合查询操作符、短语匹配或类目过滤改善精度，但这些查询策略不能替代对中文分词结果的检查。

### 3.3 执行查询示例

以下请求与 Q01 至 Q08 一一对应。`filter_path` 只保留文档编号、分数和名称，便于人工核对排名。

请求中的 `size: 6` 表示最多返回相关性排名靠前的 6 条命中文档，并不要求 Elasticsearch 凑满 6 条：如果只有 1 条文档匹配，`hits.hits` 中就只有 1 条；如果有 10 条文档匹配，则只返回前 6 条。实际匹配总数可查看未经 `filter_path` 隐藏的 `hits.total.value`。本测试语料一共只有 6 条文档，因此显式设置为 `6`，方便查看全部命中候选；省略 `size` 时默认最多返回 10 条，所以在本例中省略它也不会截断结果。

Q01——核心查询：

```http
GET /course-headphones-v1/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "size": 6,
  "query": {
    "match": {"name": "蓝牙耳机"}
  }
}
```

Q02——同义表达与基线误匹配观察：

```http
GET /course-headphones-v1/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "size": 6,
  "query": {
    "match": {"name": "无线耳机"}
  }
}
```

Q03——降噪属性：

```http
GET /course-headphones-v1/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "size": 6,
  "query": {
    "match": {"name": "降噪蓝牙耳机"}
  }
}
```

Q04——运动与防水属性：

```http
GET /course-headphones-v1/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "size": 6,
  "query": {
    "match": {"name": "运动防水蓝牙耳机"}
  }
}
```

Q05——空格和词序变化：

```http
GET /course-headphones-v1/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "size": 6,
  "query": {
    "match": {"name": "蓝牙耳机 续航长"}
  }
}
```

Q06——版本号：

```http
GET /course-headphones-v1/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "size": 6,
  "query": {
    "match": {"name": "蓝牙5.3耳机"}
  }
}
```

Q07——口语化长查询：

```http
GET /course-headphones-v1/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "size": 6,
  "query": {
    "match": {"name": "苹果手机用的无线耳机"}
  }
}
```

Q08——干扰类目：

```http
GET /course-headphones-v1/_search?filter_path=hits.hits._id,hits.hits._score,hits.hits._source.name
{
  "size": 6,
  "query": {
    "match": {"name": "蓝牙音箱"}
  }
}
```

这些请求使用 `match` 查询，让查询文本经过 `name` 字段的搜索分析器后再执行匹配。这里不增加类目过滤条件，因为本题需要观察分析器和相关性排序本身能否区分“蓝牙耳机”与“蓝牙音箱”；真实业务查询通常还会结合类目过滤和其他字段。

### 3.4 核对查询词元

排名异常时，先用 `_analyze` 查看对应查询实际产生了哪些词元。例如检查 Q06：

```http
POST /course-headphones-v1/_analyze
{
  "field": "name",
  "text": "蓝牙5.3耳机"
}
```

再检查 Q02：

```http
POST /course-headphones-v1/_analyze
{
  "field": "name",
  "text": "无线耳机"
}
```

通过 `field` 参数测试时，Elasticsearch 会从字段映射中取得分析器。如果业务另外配置了中文搜索分析器，应把 `field` 替换为 `analyzer`，并填写实际的搜索分析器名称。应对 Q01 至 Q08 逐条执行 `_analyze`，记录词元、位置和偏移量，并确认同义词规则中的词元边界与实际分析结果一致。

### 3.5 验收记录

每次调整分析器或同义词后，至少记录以下结果：

| 编号 | 实际词元             | 实际前三名       | 是否达到预期 | 问题说明               |
| ---- | -------------------- | ---------------- | ------------ | ---------------------- |
| Q01  | 根据 `_analyze` 填写 | 根据搜索响应填写 | 是/否        | 记录漏召回或误召回     |
| Q02  | 根据 `_analyze` 填写 | 根据搜索响应填写 | 是/否        | 重点检查同义词         |
| Q03  | 根据 `_analyze` 填写 | 根据搜索响应填写 | 是/否        | 重点检查降噪属性       |
| Q04  | 根据 `_analyze` 填写 | 根据搜索响应填写 | 是/否        | 重点检查运动、防水属性 |
| Q05  | 根据 `_analyze` 填写 | 根据搜索响应填写 | 是/否        | 重点检查空格和词序     |
| Q06  | 根据 `_analyze` 填写 | 根据搜索响应填写 | 是/否        | 重点检查版本号         |
| Q07  | 根据 `_analyze` 填写 | 根据搜索响应填写 | 是/否        | 重点检查口语表达       |
| Q08  | 根据 `_analyze` 填写 | 根据搜索响应填写 | 是/否        | 重点检查干扰类目       |

例如，如果 Q02 的实际前两名是 `h004`、`h005`，应记录为“未达到预期”，问题说明填写“标准分析器把中文拆成单字词元，`h005` 因命中 `线`、`耳`、`机` 被错误提升”，而不能因为它实际排在第二名就修改预期相关性。

验收时应同时检查召回和排序：相关文档是否出现、重点相关文档是否进入前列，以及干扰文档是否被错误提升。只确认 `_analyze` 输出“看起来合理”，不能证明搜索效果已经满足业务要求。
