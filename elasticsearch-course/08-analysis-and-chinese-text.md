# 08｜分析器、中文分词与多字段

## 本节目标

- 理解字符过滤、分词和词元过滤链路。
- 用分析接口（Analyze API）验证索引与搜索分词。
- 为中文和精确匹配设计可维护方案。

## 1. 分析器处理流程

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

## 2. 索引时与搜索时分析

索引分析器决定倒排索引中存储哪些词元（token），搜索分析器决定把用户查询拆成哪些词元。两者应有明确的匹配策略。例如，索引时建立边缘 n-gram（edge n-gram）供前缀联想使用，搜索时仍使用标准分析器，避免把查询再次切成大量碎片。

## 3. 中文分词策略

内置 `standard` 对中文能做基础切分，但业务效果通常有限。可选方案：

- 使用与 Elasticsearch 版本完全匹配且经过评估的中文分析插件。
- 在上游进行受控分词，把词元写入专用字段。
- 对品牌、类目、SKU 使用 `keyword`，不要对所有字段都做中文分词。
- 用业务查询集评估召回率、精确率和延迟，而不是仅凭肉眼查看几个词元。

安装插件会改变节点运行环境。必须在所有相关节点安装相同版本的插件并滚动重启，升级 Elasticsearch 前先确认插件兼容性；生产前应建立离线镜像和回滚流程。

## 4. 多字段设计

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
          "folded": {"type": "keyword", "normalizer": "lowercase_normalizer"}
        }
      }
    }
  }
}
```

- `name` 用于全文检索。
- `name.raw` 用于原值排序、聚合。
- `name.folded` 用于不区分英文大小写的精确匹配。

## 5. 同义词注意事项

同义词是业务资产，不只是配置文件。需要版本、审批、测试和回滚。`手机, 移动电话` 这类扩展可能提高召回，也可能降低精度。优先在搜索时使用可更新同义词机制，避免每次修改都全量重建索引；具体能力和许可证以所用版本官方文档为准。

## 练习与验收

- 用 `_analyze` 比较同一句话经标准分析器与关键词分词器处理后的结果。
- 解释 `name` 和 `name.raw` 分别应该用于什么查询。
- 为“蓝牙耳机”列出至少 5 条真实用户查询，作为分词效果测试集。

上一节：[07｜映射](./07-mapping-and-field-types.md)｜下一节：[09｜查询语言](./09-query-dsl.md)
