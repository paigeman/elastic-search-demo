# 14｜分片、副本、模板、别名与生命周期

## 本节目标

- 为时间序列和业务索引建立可管理结构。
- 使用组件模板、索引模板、别名和数据流。
- 理解索引滚动切换、索引生命周期管理（ILM）、数据流生命周期与分片规划。

## 1. 分片规划

一个索引由若干 **主分片** 组成；每个主分片都可以配置若干 **副本分片**。副本是对应主分片的数据复制品，不是整个索引或节点的副本。节点是承载这些分片的 Elasticsearch 实例，集群会把主分片及其副本分配到不同节点，避免单个节点故障时两者同时丢失。

例如，`number_of_shards: 3`、`number_of_replicas: 1` 表示 3 个主分片，并且每个主分片各有 1 个副本，因此共需分配 6 个分片实例。副本可以在主分片不可用时被提升，并可分担读请求，但写入仍需先由主分片处理并复制到副本，所以增加副本不等于提高写入吞吐。副本也不能替代快照备份，因为误删除和错误更新同样会被复制。

主分片与自己的副本不会分配到同一节点。因此，单节点集群配置副本时，无法分配的副本会使集群处于黄色状态；这表示主分片仍然可用，但尚未获得期望的冗余保护。

主分片数在索引创建后不能直接修改，只能拆分、收缩或重新索引。规划时应考虑：

- 单索引预计数据量、保留周期和增长速度。
- 节点数量、故障域、并行查询与恢复时间。
- 单个分片的文档量、磁盘大小、段合并与查询延迟。

不存在适用于所有场景的“每分片固定大小”。日志场景常从数十 GB/分片开始压测，商品小索引可能一个主分片就足够。先用真实数据和查询基准验证。

副本可动态调整：

```http
PUT /products-v1/_settings
{"index.number_of_replicas": 1}
```

## 2. 组件模板与索引模板

业务索引经常需要按版本或时间周期反复创建，例如 `products-v1`、`products-v2`，或每天创建一个日志索引。如果每次都手工复制分片设置和字段映射，容易出现配置遗漏或不同索引结构不一致。模板的作用就是预先保存这些建索引规则，让符合条件的新索引自动获得统一配置；模板本身不存放业务文档，也不会主动创建索引。

最核心的区别是： **组件模板只回答“有哪些配置可以复用”，索引模板才回答“这些配置要应用到哪些新索引”。**

| 对比项           | 组件模板（component template）    | 索引模板（index template）                                      |
| ---------------- | --------------------------------- | --------------------------------------------------------------- |
| 角色             | 可复用的配置零件                  | 匹配索引并装配配置的规则                                        |
| 主要内容         | `settings`、`mappings`、`aliases` | `index_patterns`、`priority`、`composed_of`，以及可选的内联配置 |
| 能否匹配索引名称 | 不能，没有 `index_patterns`       | 能，通过 `index_patterns` 匹配                                  |
| 能否单独生效     | 不能，必须被索引模板引用          | 能；即使不引用组件模板，也可以通过自身的 `template` 提供配置    |
| 主要价值         | 拆分、复用和独立维护公共配置      | 决定新索引最终采用哪组配置                                      |

例如，只创建 `products-settings-v1` 和 `products-mappings-v1` 两个组件模板后，直接创建 `products-v2`，这两个组件 **不会自动应用**。还必须创建一个索引模板，用 `index_patterns: ["products-v*"]` 指定应用对象，并用 `composed_of` 引用这两个组件。之后创建 `products-v2` 时，索引模板才会被名称匹配并把两个组件装配起来：

```text
products-settings-v1 ──┐
                       ├── products-template-v1 ── 匹配 products-v* ──> products-v2
products-mappings-v1 ──┘
```

组件模板是可选的复用机制，并不是创建索引模板的前提。对于很简单且不需要复用的配置，也可以不创建任何组件模板，直接写在索引模板的 `template` 中。反过来，组件模板不能绕过索引模板独立应用到新索引。

这两类模板与第 7 课的 **动态模板** 不同：组件模板和索引模板决定“创建新索引时采用什么整体配置”，动态模板则决定“向已有索引写入未知字段时，应该为该字段生成什么映射”。

下面先创建两个组件模板：一个集中管理商品字段映射，另一个集中管理分片与副本设置。

```http
PUT /_component_template/products-mappings-v1
{
  "template": {
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "product_id": {"type":"keyword"},
        "name": {"type":"text","fields":{"keyword":{"type":"keyword"}}},
        "price": {"type":"scaled_float","scaling_factor":100},
        "created_at": {"type":"date"}
      }
    }
  },
  "_meta": {"owner":"search-team","version":1}
}

PUT /_component_template/products-settings-v1
{
  "template": {
    "settings": {"number_of_shards":1,"number_of_replicas":1}
  }
}
```

再创建索引模板，用 `composed_of` 引用这两个组件：

```http
PUT /_index_template/products-template-v1
{
  "index_patterns": ["products-v*"],
  "priority": 200,
  "composed_of": ["products-settings-v1","products-mappings-v1"],
  "_meta": {"description":"managed product indices"}
}
```

上述配置的应用过程如下：

1. 创建 `products-v2` 时，名称会匹配 `products-v*`。
2. Elasticsearch 选择匹配模板中 `priority` 最高的索引模板。
3. 索引模板按照 `composed_of` 中的顺序合并组件模板，于是新索引同时获得商品字段映射、一个主分片和一个副本。
4. 如果多个组件定义了同一个配置，列表中靠后的组件优先；索引模板自身 `template` 中的配置又优先于组件模板。创建索引请求中显式提供的配置优先级最高。

模板只影响之后创建的索引，不会自动修改已有索引。修改 `products-mappings-v1` 后，已经存在的 `products-v1` 不会随之改变，只有后续新建且匹配的索引才会采用新配置。

正式创建索引前，使用索引模拟接口查看指定名称最终匹配哪个索引模板，以及合并后得到的设置、映射和别名：

```http
POST /_index_template/_simulate_index/products-v99
```

响应中的 `template.settings`、`template.mappings` 和 `template.aliases` 是模拟得到的最终配置，`overlapping` 会列出名称模式重叠但本次未被采用的索引模板。模拟不会创建 `products-v99`。它与第 12 课的摄取管道 `_simulate` 作用不同：这里模拟的是创建索引时的模板匹配与合并，摄取管道模拟的是单篇文档的转换过程。

## 3. 别名与零停机切换

索引别名（index alias）是指向一个或多个索引的 **逻辑名称**。它只是一条保存在集群元数据中的指向关系，不存放或复制文档。大多数原本需要填写索引名的 API 都可以填写别名，因此应用可以使用稳定名称，而不必知道当前实际索引叫什么：

```text
应用 ──> products-read（别名）──> products-v1（实际索引）
```

别名主要用于以下场景：

- **隔离应用与实际索引名称**：应用始终访问 `products-read`，实际索引可以从 `products-v1` 升级为 `products-v2`。
- **一次搜索多个索引**：一个读取别名可以同时指向多个索引，搜索别名时会搜索它们。
- **切换版本或重建索引**：新索引准备好后，只修改别名指向，不需要修改和重新部署应用。
- **限定查询范围或路由**：别名还可以附带过滤条件和路由设置；使用前应理解其适用 API 和安全边界。

先为当前索引建立读取和写入别名：

```http
POST /_aliases
{
  "actions": [
    {"add":{"index":"products-v1","alias":"products-read"}},
    {"add":{"index":"products-v1","alias":"products-write","is_write_index":true}}
  ]
}
```

应用随后通过别名查询和写入：

```http
GET /products-read/_search
{
  "query": {"match_all": {}}
}

POST /products-write/_doc
{"product_id":"p2001","name":"Mechanical Keyboard","price":399,"created_at":"2026-07-29"}
```

### 3.1 原子切换索引

假设已经创建 `products-v2`，并完成数据迁移、增量同步和业务验证，可以在同一个请求中把两个别名从旧索引切换到新索引：

```http
POST /_aliases
{
  "actions": [
    {"remove":{"index":"products-v1","alias":"products-read","must_exist":true}},
    {"remove":{"index":"products-v1","alias":"products-write","must_exist":true}},
    {"add":{"index":"products-v2","alias":"products-read"}},
    {"add":{"index":"products-v2","alias":"products-write","is_write_index":true}}
  ]
}
```

该请求更新的是别名指向，不会复制或删除任何索引数据。切换成功后，新的查询和写入会通过别名进入 `products-v2`；应用不需要修改索引名称。多个有效动作在一个 `_aliases` 请求中完成切换，可以避免先删除旧指向、再添加新指向所产生的空档。这里为 `remove` 设置 `must_exist: true`，使预期别名不存在时整个动作列表失败，避免在前置状态不符合预期时发生部分变更。

别名切换本身很快，但“零停机”不代表 Elasticsearch 会自动迁移数据。切换前仍需把旧数据和迁移期间产生的新写入同步到 `products-v2`，并验证文档数量、关键查询和回滚路径。需要回滚时，可以用相反的 `remove` 和 `add` 动作把别名重新指向仍然保留的 `products-v1`。

### 3.2 为什么只能有一个写入索引

一个别名可以指向多个索引。用这个别名搜索时，Elasticsearch 可以查询所有目标；但用它写入一篇文档时，文档只能写进一个具体索引，Elasticsearch 不能自行猜测目标。

假设别名的指向关系如下：

```text
products-all ──┬──> products-v1
               └──> products-v2
```

此时 `GET /products-all/_search` 可以同时搜索两个索引，但如果没有指定写入索引，`POST /products-all/_doc` 会因为目标不明确而被拒绝。使用 `is_write_index: true` 可以明确指定写入目标：

```http
POST /_aliases
{
  "actions": [
    {"add":{"index":"products-v1","alias":"products-all"}},
    {"add":{"index":"products-v2","alias":"products-all","is_write_index":true}}
  ]
}
```

现在通过 `products-all` 搜索仍会覆盖 `products-v1` 和 `products-v2`，通过它发出的写请求则只会进入 `products-v2`。所以，更准确的规则是：

- 索引别名只指向一个索引时，即使没有设置 `is_write_index`，该索引也会自动作为写入索引；显式设置可以让意图更清楚。
- 别名指向多个索引并用于写入时，必须用 `is_write_index: true` 明确指定其中唯一的写入索引。
- 如果没有指定写入索引，写请求会被拒绝；同一个别名也不应有两个写入索引。

可以使用下面的接口查看每个别名当前指向哪些索引，以及其中哪个索引被标记为写入索引：

```http
GET /_alias/products-read
GET /_alias/products-write
GET /_cat/aliases?v
```

## 4. 数据流与生命周期

### 4.1 数据流是什么

数据流（data stream）是 Elasticsearch 为日志、指标、审计事件等持续产生的时间序列数据提供的一种 **逻辑数据资源**。这里的“流”不是网络连接或消息队列，也不是数据处理管道；可以把它理解成一个稳定名称，背后由 Elasticsearch 管理一组按时间不断滚动产生的索引。

这些内部索引称为 **后备索引（backing index）**。数据流始终有且只有一个当前写入索引：

```text
app-logs-production（数据流，对应用保持同一个名称）
│
├── .ds-app-logs-production-...-000001  较早的后备索引
├── .ds-app-logs-production-...-000002  较新的后备索引
└── .ds-app-logs-production-...-000003  当前写入索引
```

应用不需要知道后备索引的名称：

- 写入 `app-logs-production` 时，新文档只进入当前写入索引。
- 搜索 `app-logs-production` 时，查询会覆盖该数据流的所有后备索引。
- 发生索引滚动切换（rollover）时，Elasticsearch 创建一个新的后备索引并将其设为写入索引；原写入索引继续保留供查询，但不再接收通过数据流发出的新写入。

索引滚动切换不是把旧索引拆开，也不会把已有文档搬到新索引。它只是关闭旧索引的“当前写入目标”身份，让后续数据进入一个新的索引，从而避免单个索引无限增长。后备索引的具体名称属于实现细节，应用和日常查询应使用数据流名称。

数据流中的每篇文档必须包含 `@timestamp` 字段，其映射类型必须是 `date` 或 `date_nanos`。数据流主要面向追加写入：可以不断加入新事件，但如果业务需要频繁按照 `_id` 修改或删除既有文档，直接操作后备索引会使使用和维护变得复杂。

### 4.2 创建并使用数据流

数据流必须匹配一个启用了数据流的索引模板。索引模板中的 `data_stream: {}` 表示匹配 `app-logs-*` 的名称要创建成数据流，而不是普通索引；模板中的映射和设置会应用到每个新建的后备索引。

下面同时配置一个简单的数据流生命周期：数据至少保留 30 天，之后由 Elasticsearch 自动清理符合条件的旧后备索引。

```http
PUT /_index_template/app-logs-template-v1
{
  "index_patterns": ["app-logs-*"],
  "priority": 300,
  "data_stream": {},
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0
    },
    "mappings": {
      "properties": {
        "@timestamp": {"type":"date"},
        "service_name": {"type":"keyword"},
        "message": {"type":"text"}
      }
    },
    "lifecycle": {
      "data_retention": "30d"
    }
  }
}

PUT /_data_stream/app-logs-production
```

这里把副本数设为 `0` 是为了适配课程的单节点实验环境；生产环境应根据节点与故障域重新规划。

创建后直接使用数据流名称写入和搜索，不需要访问隐藏的后备索引。数据流要求写入操作的 `op_type` 为 `create`；下面的 `POST /_doc` 让 Elasticsearch 自动生成文档 `_id`，因此默认就是创建操作。如果需要自行指定 `_id`，应使用 `PUT /app-logs-production/_create/<id>`，而不是用普通索引的覆盖写入方式。

```http
POST /app-logs-production/_doc
{
  "@timestamp": "2026-07-29T10:15:00+08:00",
  "service_name": "catalog-api",
  "message": "product search completed"
}

GET /app-logs-production/_search
{
  "query": {
    "range": {
      "@timestamp": {"gte":"now-1d"}
    }
  }
}
```

可以查看数据流的后备索引、当前代数和生命周期配置，也可以在实验中手动触发一次索引滚动切换：

```http
GET /_data_stream/app-logs-production
GET /_data_stream/app-logs-production/_lifecycle
POST /app-logs-production/_rollover
```

滚动切换后再次执行 `GET /_data_stream/app-logs-production`，可以看到代数增加，并出现新的当前写入索引。

### 4.3 数据流、普通索引与别名如何选择

数据流和索引别名都能为多个索引提供一个稳定名称，但职责不同：

| 场景或能力 | 数据流                          | 普通索引与别名                             |
| ---------- | ------------------------------- | ------------------------------------------ |
| 典型数据   | 日志、指标、追踪、审计事件      | 商品、账户、订单当前状态                   |
| 写入模式   | 持续追加新事件                  | 经常按 `_id` 更新或删除                    |
| 时间字段   | 每篇文档必须有 `@timestamp`     | 没有这一强制要求                           |
| 底层索引   | 自动管理后备索引和当前写入索引  | 由使用者创建索引并维护别名指向             |
| 滚动与保留 | 与数据流生命周期或 ILM 直接集成 | 需要正确配置写入别名、滚动和 ILM           |
| 版本切换   | 不以手工切换业务版本为主要用途  | 适合 `products-v1` 到 `products-v2` 的切换 |

因此，“商品主数据频繁按标识更新时，普通索引与别名通常更直观”不是一条孤立规则，而是两种模型的选型边界：商品索引保存对象的 **当前状态**，日志数据流保存随时间持续追加的 **事件历史**。

### 4.4 生命周期解决什么问题

时间序列数据会持续增长。如果一直写入同一个索引，它会越来越大；如果只滚动而不清理，后备索引又会无限累积。生命周期管理用于自动完成“滚动、降低旧数据存储成本、到期删除”等工作。

Elasticsearch 提供两种相关机制，应根据需求选择一种，不要让同一数据流同时由两套策略管理：

- **数据流生命周期**：只适用于数据流，配置更简单，负责自动滚动、保留期和可选的降采样。上面模板中的 `lifecycle.data_retention: 30d` 就属于这种方式。`30d` 表示至少保留 30 天，并不保证文档一到 30 天就立刻逐条删除；清理以已经滚动的后备索引为单位，在之后的生命周期执行中完成。
- **索引生命周期管理（ILM）**：既能管理普通索引，也能管理数据流的后备索引。它支持更细致的 hot、warm、cold、frozen 和 delete 阶段，适合需要迁移数据层、调整副本、强制合并或执行其他分阶段动作的自管集群。

ILM 的常见阶段包括：

- 热阶段（hot）：当前写入和高频查询，通常使用性能较高的节点，并在达到大小或时间条件时滚动。
- 温阶段（warm）：已经停止写入但仍会查询，可以迁移到成本较低的数据层并进行适当整理。
- 冷或冻结阶段（cold/frozen）：查询频率很低，进一步降低本地存储成本。
- 删除阶段（delete）：超过保留期限后删除整个索引。

下面是一个 ILM 策略示意。它是上面“数据流生命周期 30 天保留”的 **另一种选择**，不要直接把两者同时配置给 `app-logs-production`。

```http
PUT /_ilm/policy/app-logs-tiered-30d
{
  "policy": {
    "phases": {
      "hot": {"actions":{"rollover":{"max_primary_shard_size":"30gb","max_age":"1d"}}},
      "warm": {"min_age":"2d","actions":{"forcemerge":{"max_num_segments":1}}},
      "delete": {"min_age":"30d","actions":{"delete":{}}}
    }
  }
}
```

其中 hot 阶段的 `rollover` 动作表示：当非空的当前写入索引有任一主分片达到 `30gb`，或者写入索引的年龄达到 `1d` 时，ILM 创建下一代后备索引并切换写入目标。假设切换前的结构是：

```text
app-logs-production
└── ...-000001  当前写入索引
```

切换后会变为：

```text
app-logs-production
├── ...-000001  保留历史数据，仍可查询
└── ...-000002  新的当前写入索引
```

数据流名称没有改变，已有文档也仍留在 `000001`；只有切换后的新文档进入 `000002`，搜索数据流时则会查询两者。ILM 在后台周期性检查条件，因此切换不一定恰好发生在达到阈值的瞬间。旧索引在后续满足 `min_age` 后进入 warm 阶段，最终进入 delete 阶段。

warm 阶段中的 `forcemerge` 是 **强制合并 Lucene 段**。每个分片底层都是一个独立的 Lucene 索引，写入和刷新会在各个分片内不断产生新的不可变段；查询一个分片时，需要在它的多个段中执行查询并合并结果。后台通常会自动逐步合并这些段，而 `forcemerge` 会分别在每个分片内部进行合并，使该分片的段数不超过指定上限。

本例中的配置：

```json
{ "forcemerge": { "max_num_segments": 1 } }
```

表示把 **每个分片** 尽量合并到最多一个段，而不是把多个分片合成一个分片，也不是把多个后备索引合成一个索引。合并可以清理已标记删除的文档，并减少旧索引的段管理与查询开销，因此适合已经完成滚动切换、之后基本不再写入的历史索引。

强制合并会大量使用磁盘输入输出、处理器和临时磁盘空间，耗时也可能较长。如果索引之后继续写入，又会产生新段，使这次合并的收益逐渐消失；过大的合并段也不会再像普通小段那样参与常规自动合并。因此不要为了“整理数据”频繁执行 `forcemerge`，也不要对当前写入索引执行。本策略把它放在 warm 阶段，就是为了等待 `000001` 不再承担写入后再处理。

若选择 ILM 管理数据流，应从索引模板中移除 `lifecycle.data_retention`，改为在模板的 `settings` 中指定策略：

```json
{
  "index.lifecycle.name": "app-logs-tiered-30d"
}
```

这里的 `index.lifecycle.name` 用于指定管理该索引的 ILM 策略。另一个容易遇到的设置是 `index.lifecycle.rollover_alias`，它用于 **普通索引与写入别名组成的滚动模式**，告诉 ILM：“这个索引需要滚动时，应通过哪个别名切换写入目标。”

例如，普通索引采用下面的结构：

```text
logs-write（写入别名）
└── logs-000001  当前写入索引，is_write_index: true
```

如果 `logs-000001` 配置了：

```json
{
  "index.lifecycle.name": "logs-tiered-30d",
  "index.lifecycle.rollover_alias": "logs-write"
}
```

那么达到 ILM 的 rollover 条件时，Elasticsearch 可以创建 `logs-000002`，并调整别名指向：

```text
logs-write（写入别名）
├── logs-000001  历史索引，is_write_index: false
└── logs-000002  新写入索引，is_write_index: true
```

`index.lifecycle.rollover_alias` 只是告诉 ILM 使用哪个别名，不会单独创建初始索引或别名。采用这种模式时，初始索引名称必须以数字结尾，例如 `logs-000001`；指定的别名必须指向该索引，并将它标记为写入索引。

数据流已经内置了“多个后备索引 + 唯一当前写入索引”的关系，rollover 时会自行创建下一代后备索引并切换写入目标，因此使用 ILM 管理数据流时不需要配置 `index.lifecycle.rollover_alias`：

| ILM 管理对象 | 如何确定滚动写入目标                               |
| ------------ | -------------------------------------------------- |
| 普通索引     | 通过 `index.lifecycle.rollover_alias` 指定写入别名 |
| 数据流       | 数据流自己维护当前写入索引，无需滚动别名           |

ILM 策略还必须与实际数据层和节点角色相匹配，并避免让大量历史索引在业务繁忙时段同时进入强制合并步骤。

## 5. 防止失控

- 为租户创建独立索引前，计算索引与分片总数；小租户通常共享索引并按租户字段过滤。
- 为索引模板和组件模板建立版本记录，明确负责维护、评审变更和处理故障的团队，并保留回滚方案。可以在 `_meta` 中记录 `owner`、`version` 等说明信息，但 `_meta` 只是供人员和工具读取的元数据，不会自动实施权限控制、审批或版本回滚。
- 定期检查空索引、小分片、未分配分片和长期不删除的数据。
- 删除前确认快照、保留策略与合规要求。

## 练习与验收

- 创建组件模板和索引模板，并用它们创建 `products-v3`。
- 通过别名在两个索引间原子切换并验证回滚。
- 判断商品主数据与应用日志分别应使用普通索引还是数据流。

上一节：[13｜应用客户端](./13-application-clients.md)｜下一节：[15｜安全](./15-security.md)
