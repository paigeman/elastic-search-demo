# 14｜分片、副本、模板、别名与生命周期：练习与验收答案

建议先独立完成练习，再使用本页核对模板合并结果、别名切换过程和数据模型选择。以下标记为 `http` 的请求都在 Kibana 的开发工具（Dev Tools）中的控制台（Console）执行，并假定使用第 14 章相同的 Elasticsearch 集群。

本答案会创建 `products-v3`、`products-v4` 和练习专用别名 `products-c14-read`。如果这些名称已经被其他实验使用，不要直接删除不清楚用途的资源；可以改用新的版本后缀和别名，并在本答案的后续请求中保持一致。

## 1. 创建组件模板和索引模板，并用它们创建 `products-v3`

### 1.1 创建两个组件模板

先创建商品字段映射组件：

```http
PUT /_component_template/products-mappings-v1
{
  "template": {
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "product_id": {"type":"keyword"},
        "name": {
          "type":"text",
          "fields": {
            "keyword": {"type":"keyword"}
          }
        },
        "price": {
          "type":"scaled_float",
          "scaling_factor":100
        },
        "created_at": {"type":"date"}
      }
    }
  },
  "_meta": {
    "owner":"search-team",
    "version":1
  }
}
```

再创建分片设置组件：

```http
PUT /_component_template/products-settings-v1
{
  "template": {
    "settings": {
      "number_of_shards":1,
      "number_of_replicas":1
    }
  },
  "_meta": {
    "owner":"search-team",
    "version":1
  }
}
```

这两个组件模板此时只是已经注册的配置零件，不会自行应用到任何索引。可以读取它们，检查名称、配置和 `_meta`：

```http
GET /_component_template/products-mappings-v1
GET /_component_template/products-settings-v1
```

### 1.2 创建负责匹配和装配的索引模板

创建索引模板，让所有名称符合 `products-v*` 的新索引使用上述两个组件：

```http
PUT /_index_template/products-template-v1
{
  "index_patterns": ["products-v*"],
  "priority": 200,
  "composed_of": [
    "products-settings-v1",
    "products-mappings-v1"
  ],
  "_meta": {
    "description":"managed product indices",
    "owner":"search-team",
    "version":1
  }
}
```

验收时必须能说明：

- `products-settings-v1` 和 `products-mappings-v1` 负责保存可复用配置。
- `products-template-v1` 通过 `index_patterns` 决定应用对象。
- `composed_of` 把两个组件装配成创建商品索引所需的完整配置。
- 只创建组件模板而不创建索引模板，`products-v3` 不会自动获得这些设置。

### 1.3 先模拟，再创建索引

在真正创建索引前模拟 `products-v3` 的模板匹配结果：

```http
POST /_index_template/_simulate_index/products-v3
```

响应中的 `template` 应同时包含：

- `settings.index.number_of_shards` 为 `1`。
- `settings.index.number_of_replicas` 为 `1`。
- `mappings.dynamic` 为 `strict`。
- `mappings.properties` 中存在 `product_id`、`name`、`price` 和 `created_at`。

模拟请求不会创建 `products-v3`。确认合并结果符合预期后再创建索引：

```http
PUT /products-v3
```

读取实际设置和映射：

```http
GET /products-v3/_settings?flat_settings=true
GET /products-v3/_mapping
```

这两个只读接口在[第 5 课的“API 调试习惯”](../elasticsearch-course/05-rest-api-and-dev-tools.md#5-api-调试习惯)中出现过，但当时只列出了调试命令；这里进一步说明它们各自检查什么：

- `GET /products-v3/_settings` 读取索引级设置，例如主分片数、副本数、刷新间隔和生命周期配置。`flat_settings=true` 只改变响应的展示方式，把嵌套结构展开成 `index.number_of_shards` 这样的点号键名，不会修改索引设置。
- `GET /products-v3/_mapping` 读取索引当前实际生效的字段映射，例如 `dynamic` 策略、字段类型、多字段和 `scaled_float` 的缩放倍数。

设置响应的关键部分应类似：

```json
{
  "products-v3": {
    "settings": {
      "index.number_of_shards": "1",
      "index.number_of_replicas": "1"
    }
  }
}
```

实际响应还会包含索引 UUID、创建时间和版本等系统生成的设置，具体值不需要与示例一致。设置值在响应中通常表示为字符串，因此这里的 `"1"` 仍表示数值配置 1。

映射响应的关键部分应类似：

```json
{
  "products-v3": {
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "product_id": { "type": "keyword" },
        "name": {
          "type": "text",
          "fields": {
            "keyword": { "type": "keyword" }
          }
        },
        "price": {
          "type": "scaled_float",
          "scaling_factor": 100
        },
        "created_at": { "type": "date" }
      }
    }
  }
}
```

索引模板模拟接口回答“如果现在创建这个索引，将合并出什么配置”；`_settings` 和 `_mapping` 则回答“索引创建后实际采用了什么配置”。两边的关键分片设置和字段映射应一致。模板只在创建索引时应用；之后修改组件模板或索引模板，不会自动改写已经存在的 `products-v3`。

课程的单节点环境无法把主分片及其副本分配到不同节点，所以本例设置一个副本后，集群可能显示黄色。可以检查：

```http
GET /_cluster/health/products-v3
GET /_cat/shards/products-v3?v
```

黄色状态在这里表示主分片已经分配、索引仍可读写，但副本分片无处放置；它不表示模板创建失败。生产环境不能仅为了消除黄色状态就机械地把副本设为 `0`，而应根据节点和故障域设计冗余。

## 2. 通过别名在两个索引间原子切换并验证回滚

### 2.1 准备两个可区分的索引版本

创建 `products-v4`。它同样匹配 `products-v*`，因此会自动使用第 1 题创建的索引模板：

```http
PUT /products-v4
```

分别向两个索引写入相同 `_id`、但名称不同的实验文档：

```http
PUT /products-v3/_doc/p1401?refresh=wait_for
{
  "product_id":"p1401",
  "name":"Mechanical Keyboard v3",
  "price":399,
  "created_at":"2026-07-29T10:00:00+08:00"
}

PUT /products-v4/_doc/p1401?refresh=wait_for
{
  "product_id":"p1401",
  "name":"Mechanical Keyboard v4",
  "price":429,
  "created_at":"2026-07-29T11:00:00+08:00"
}
```

这里使用不同的名称和价格，是为了通过返回内容判断别名当前指向哪个索引。

### 2.2 建立初始别名

让练习专用别名先指向 `products-v3`：

```http
POST /_aliases
{
  "actions": [
    {
      "add": {
        "index":"products-v3",
        "alias":"products-c14-read"
      }
    }
  ]
}
```

查看别名并通过它读取文档：

```http
GET /_alias/products-c14-read
GET /products-c14-read/_doc/p1401?filter_path=_index,_source
```

此时响应中的 `_index` 应为 `products-v3`，`_source.name` 应为 `Mechanical Keyboard v3`。

### 2.3 原子切换到 `products-v4`

在同一个 `_aliases` 请求中删除旧指向并添加新指向：

```http
POST /_aliases
{
  "actions": [
    {
      "remove": {
        "index":"products-v3",
        "alias":"products-c14-read",
        "must_exist":true
      }
    },
    {
      "add": {
        "index":"products-v4",
        "alias":"products-c14-read"
      }
    }
  ]
}
```

再次验证：

```http
GET /_alias/products-c14-read
GET /products-c14-read/_doc/p1401?filter_path=_index,_source
```

现在 `_index` 应为 `products-v4`，`_source.name` 应为 `Mechanical Keyboard v4`。应用访问的名称一直是 `products-c14-read`，只有集群元数据中的别名指向发生了变化。

`must_exist: true` 用来检查切换前置状态。如果预期的旧别名不存在，请求会失败，而不是在错误状态下继续进行部分切换。切换请求本身不会把 `products-v3` 的数据复制到 `products-v4`；正式迁移必须先完成全量数据复制、增量同步和业务验证。

### 2.4 回滚到 `products-v3`

用相反的动作恢复旧指向：

```http
POST /_aliases
{
  "actions": [
    {
      "remove": {
        "index":"products-v4",
        "alias":"products-c14-read",
        "must_exist":true
      }
    },
    {
      "add": {
        "index":"products-v3",
        "alias":"products-c14-read"
      }
    }
  ]
}
```

最后验证：

```http
GET /_alias/products-c14-read
GET /products-c14-read/_doc/p1401?filter_path=_index,_source
```

响应应再次来自 `products-v3`。验收时不应只检查 `_aliases` 请求是否返回成功，还应检查：

- 别名当前只指向预期索引。
- 通过别名执行的实际业务查询返回预期版本的数据。
- `products-v3` 和 `products-v4` 都仍然存在，切换与回滚没有删除索引。
- 如果应用还通过别名写入，应在同一个切换请求中同步调整写入别名，并保证只有一个目标被标记为 `is_write_index: true`。

## 3. 判断商品主数据与应用日志应使用普通索引还是数据流

推荐选择如下：

| 数据       | 推荐模型             | 主要理由                                                                         |
| ---------- | -------------------- | -------------------------------------------------------------------------------- |
| 商品主数据 | 普通索引配合读写别名 | 保存每件商品的当前状态，经常按稳定 `_id` 更新；适合通过版本化索引完成重建和切换  |
| 应用日志   | 数据流               | 持续追加、具有明确时间戳、数据不断增长；适合自动维护后备索引、滚动切换和到期清理 |

### 3.1 商品主数据

商品主数据通常具有以下特点：

- 每个商品由 `product_id` 或稳定 `_id` 标识。
- 价格、库存、上下架状态等字段会被反复更新。
- 业务通常关心商品当前是什么状态，而不是把每次修改都作为独立文档追加。
- 修改映射或重建数据时，可以创建 `products-v4`，完成迁移后把 `products-read` 和 `products-write` 切换过去。

因此更适合：

```text
products-read  ──> products-v3
products-write ──> products-v3
```

版本升级后变为：

```text
products-read  ──> products-v4
products-write ──> products-v4
```

普通索引并不表示没有生命周期需求。仍需规划旧版本索引保留多久、何时创建快照以及何时删除，但通常不需要像日志那样频繁滚动产生新索引。

### 3.2 应用日志

应用日志通常具有以下特点：

- 每条日志都是一次新的事件，主要采用追加写入。
- 每篇文档都能提供 `@timestamp`。
- 数据持续增长，需要限制单个索引大小并按保留期清理旧数据。
- 查询经常跨越最近几小时、几天或更长时间范围。

因此更适合：

```text
app-logs-production（数据流）
├── ...-000001  历史后备索引
├── ...-000002  历史后备索引
└── ...-000003  当前写入索引
```

应用始终写入和查询 `app-logs-production`。数据流负责维护唯一的当前写入索引；数据流生命周期或 ILM 再负责滚动、保留和删除。

### 3.3 选型边界

不能仅凭“数据中有时间字段”就选择数据流。验收时还应说明数据的更新模型：

- 如果保存的是商品当前状态，并且需要频繁覆盖同一商品，应使用普通索引与别名。
- 如果保存的是“商品价格发生变化”这样的不可变事件历史，则这部分事件数据也可以单独使用数据流。
- 如果所谓日志需要频繁使用相同 `_id` 覆盖旧记录，它已经偏离追加事件模型，应重新评估是否使用普通索引。

合格答案必须同时提到“是否持续追加”“是否频繁更新既有文档”“是否需要自动滚动与保留”，而不能只回答“商品用索引、日志用数据流”。
