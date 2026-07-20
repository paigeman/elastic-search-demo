# 08｜分析器、中文分词与多字段

## 本节目标

- 理解字符过滤、分词和词元过滤链路。
- 用分析接口（Analyze API）验证索引与搜索分词。
- 为中文和精确匹配设计可维护方案。

## 1. `analyzer` 的正式定义

在字段映射中，`analyzer` 是 `text` 字段的映射参数，用于指定 Elasticsearch 分析该字段文本时所使用的分析器。写入文档时，它把字段的原始文本转换成词元，供倒排索引建立可检索的词项；执行全文查询时，如果没有另外配置 `search_analyzer`，Elasticsearch 默认也使用该分析器处理查询文本。

`analyzer` 只适用于 `text` 字段，`keyword` 字段不使用它。它处理的是用于检索的词元，不会改变 `_source` 中保存的原始文本。由于索引分析器决定倒排索引中实际生成的词项，已有字段的 `analyzer` 不能原地修改；如需更换，通常必须新建索引并重建数据。

`analyzer` 参数指定“使用哪个分析器”，而分析器本身是一条文本处理链。下面继续介绍这条处理链的组成和执行顺序。

## 2. 分析器处理流程

分析器（Analyzer）由三部分组成：

1. 字符过滤器（`char_filter`）：在分词前清洗字符，例如移除 HTML。
2. 分词器（`tokenizer`）：切分文本。
3. 词元过滤器（`filter`）：进行小写化、停用词、同义词或 n-gram 等处理。

查看标准分析器（standard analyzer）的结果：

```http
POST /_analyze
{
  "analyzer": "standard",
  "text": "USB-C Dock for MacBook Pro"
}
```

调试自定义链：

```http
POST /_analyze
{
  "tokenizer": "standard",
  "filter": ["lowercase"],
  "text": "ElasticSearch QUICK Start"
}
```

## 3. 索引时与搜索时分析

索引分析器决定倒排索引中存储哪些词元（token），搜索分析器决定把用户查询拆成哪些词元。两者应有明确的匹配策略。例如，索引时建立边缘 n-gram（edge n-gram）供前缀联想使用，搜索时仍使用标准分析器，避免把查询再次切成大量碎片。

## 4. 同义词过滤器：改写和扩展搜索词元

第 2 部分提到，词元过滤器可以修改、删除或增加分词器产生的词元。同义词过滤器就是其中一种：它接收词元流，根据同义词规则增加或替换词元，从而让不同表达方式能够匹配。同义词处理不会修改 `_source` 中的原始文本。

同义词规则常见两种写法：

```text
computer, pc, laptop
personal computer => pc
```

- 逗号分隔的是等价规则。默认情况下，组内任意词都可以扩展为其他词。
- `=>` 表示单向规则，只把左侧表达改写为右侧表达。

可以先用 Analyze API 观察同义词过滤器如何改变词元流：

```http
POST /_analyze
{
  "tokenizer": "standard",
  "filter": [
    "lowercase",
    {
      "type": "synonym_graph",
      "synonyms": ["laptop, notebook"]
    }
  ],
  "text": "Laptop stand"
}
```

标准分词器先产生 `laptop` 和 `stand`，`synonym_graph` 再在 `laptop` 所在位置加入 `notebook`。因此，查询 `laptop stand` 时也有机会匹配包含 `notebook stand` 的文档。`synonym_graph` 能正确表示多词同义词形成的词元关系，设计目标是用在搜索分析器中。

下面把索引分析器和搜索分析器明确分开：索引时只进行小写化，搜索时再扩展同义词。

```http
PUT /products-synonym-v1
{
  "settings": {
    "analysis": {
      "filter": {
        "product_synonyms": {
          "type": "synonym_graph",
          "synonyms": ["laptop, notebook"]
        }
      },
      "analyzer": {
        "product_index": {
          "type": "custom",
          "tokenizer": "standard",
          "filter": ["lowercase"]
        },
        "product_search": {
          "type": "custom",
          "tokenizer": "standard",
          "filter": ["lowercase", "product_synonyms"]
        }
      }
    }
  },
  "mappings": {
    "properties": {
      "name": {
        "type": "text",
        "analyzer": "product_index",
        "search_analyzer": "product_search"
      }
    }
  }
}
```

这种搜索时扩展策略让倒排索引保持稳定，同义词规则变化时不必为了重新生成历史词元而重建全部数据。若在索引时应用同义词，扩展结果会直接写入倒排索引，规则变更通常需要重建索引；索引时应使用 `synonym` 过滤器，而不是面向搜索分析器的 `synonym_graph`。

同义词匹配的是分词后的词元或词元序列，不是未经分析的原始字符串。中文规则尤其依赖前一步的分词结果：在加入 `蓝牙耳机, 无线耳机` 之类的规则前，应先用 `_analyze` 确认所选中文分词器产生了与规则一致的词元边界，否则规则可能不会生效。

同义词还是需要持续维护的业务资产。规则应有版本、评审、测试集和回滚方案，并通过真实查询验证召回率、精确率和相关性。生产中优先将可更新的同义词集用于搜索分析器，避免规则调整导致全量重建；过滤器顺序也必须固定并经过测试，因为位于同义词过滤器之前的词元过滤器同样会参与同义词规则的解析。

官方参考：[Synonym graph token filter](https://www.elastic.co/docs/reference/text-analysis/analysis-synonym-graph-tokenfilter)、[Analyze API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-analyze)。

## 5. 中文分词策略

内置 `standard` 对中文能做基础切分，但业务效果通常有限。可选方案：

- 使用与 Elasticsearch 版本完全匹配且经过评估的中文分析插件。
- 在上游进行受控分词，把词元写入专用字段。
- 对品牌、类目、SKU 使用 `keyword`，不要对所有字段都做中文分词。
- 用业务查询集评估召回率、精确率和延迟，而不是仅凭肉眼查看几个词元。

安装插件会改变节点运行环境。必须在所有相关节点安装相同版本的插件并滚动重启，升级 Elasticsearch 前先确认插件兼容性；生产前应建立离线镜像和回滚流程。

## 6. 多字段（multi-fields）：一份原值，多种检索方式

同一个业务字段往往需要支持不同的检索方式。例如，商品名称既要参与全文检索，又要保留完整原值用于精确匹配、排序和聚合。单一的字段映射很难同时妥善承担这些职责：`text` 适合分词后的全文检索，`keyword` 更适合把整个值作为一个词项处理。

Elasticsearch 的多字段功能允许使用不同的数据类型或分析方式，把同一个字段值表示为多个可独立查询的索引字段。文档只需在 `_source` 中保存一份原始值，映射中的 `fields` 会定义额外的子字段；父字段和各个子字段拥有各自的映射与索引结果。

```http
PUT /products-text-v1
{
  "settings": {
    "analysis": {
      "normalizer": {
        "lowercase_normalizer": {
          "type": "custom",
          "filter": ["lowercase"]
        }
      }
    }
  },
  "mappings": {
    "properties": {
      "name": {
        "type": "text",
        "analyzer": "standard",
        "fields": {
          "raw": {"type": "keyword", "ignore_above": 256},
          "lowercase": {"type": "keyword", "normalizer": "lowercase_normalizer"}
        }
      }
    }
  }
}
```

写入文档时仍然只提供 `name`：

```http
POST /products-text-v1/_doc/p1001
{
  "name": "USB-C Dock for MacBook Pro"
}
```

这个值会按照三套规则分别建立索引：

```text
_source 中的一份 name 原值
├── name            → text + standard，供全文检索
├── name.raw        → keyword，供原值精确匹配、排序和聚合
└── name.lowercase  → keyword + lowercase，供不区分英文大小写的精确匹配
```

例如，全文检索查询主字段：

```http
GET /products-text-v1/_search
{
  "query": {
    "match": {"name": "macbook dock"}
  }
}
```

精确匹配、排序或聚合则使用相应的 `keyword` 子字段：

```http
GET /products-text-v1/_search
{
  "query": {
    "term": {"name.lowercase": "usb-c dock for macbook pro"}
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

`name.raw` 和 `name.lowercase` 是索引层面的子字段，不会作为重复字段出现在 `_source` 中。这里的“多字段”也不是让业务文档保存多个名称，而是让同一个名称同时获得多种可检索表示。

## 练习与验收

- 用 `_analyze` 比较同一句话经标准分析器与关键词分词器处理后的结果。
- 解释 `name` 和 `name.raw` 分别应该用于什么查询。
- 为“蓝牙耳机”列出至少 5 条真实用户查询，作为分词效果测试集。

上一节：[07｜映射](./07-mapping-and-field-types.md)｜下一节：[09｜查询语言](./09-query-dsl.md)
