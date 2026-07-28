# Java 客户端练习

本目录提供第 13 课“练习与验收”的 Java 客户端实现，要求 Java 21，并使用项目自带的
Maven Wrapper。无需也不应在系统中另行安装 Maven。

## 项目内容

[`SearchProducts.java`](./src/main/java/com/example/course13/SearchProducts.java)
实现客户端连接、查询构造、429 重试和命令行入口；
[`Product.java`](./src/main/java/com/example/course13/Product.java) 负责映射返回的商品文档。
`src/test/` 包含不依赖外部服务的单元测试，以及需要显式启用的真实 Elasticsearch
集成测试。

## 验收要求

在 `SearchProducts.java` 中完成以下内容：

1. 从 `ES_URL`、`ES_CA` 和 `ES_API_KEY` 环境变量读取连接信息，使用 API 密钥和 CA
   证书创建官方 Java 客户端；不得关闭 TLS 验证，也不得在源码或日志中记录 API 密钥。
2. 实现商品搜索函数：
   - 函数只接收 `keyword`、可选的 `category` 和 `size` 三个业务参数。
   - 固定使用 `application-client-products-read` 索引，不接受调用方指定索引或任意 DSL。
   - 关键词只搜索 `name` 和 `description`。
   - 只允许使用 `category` 做可选的精确过滤，并固定加入 `available: true`。
   - `_source` 只返回 `product_id`、`name`、`price` 和 `stock`。
   - `size` 默认为 20，并限制在 1～100。
3. 对安全的读取请求处理 429：初始请求失败后最多重试 3 次，即最多尝试 4 次；最后一次
   仍返回 429 时停止重试并抛出错误。
4. 程序结束时关闭客户端及其底层连接。

## 使用 Maven Wrapper

先确认当前 Java 版本为 21：

```bash
java -version
```

首次执行时，Wrapper 会下载项目固定的 Maven 3.9.16 到用户级 Wrapper 缓存，而不会安装
系统级 `mvn`。项目还固定了 Spotless、Google Java Format 和 Checkstyle 的版本；首次使用
时，Maven 会将这些插件及其依赖下载到用户级 `~/.m2/repository` 缓存：

```bash
./mvnw --version
./mvnw spotless:apply
./mvnw verify
```

`spotless:apply` 会格式化 Java 文件；`verify` 会依次编译、测试，并执行格式检查和
Checkstyle。请始终使用 `./mvnw`，不要使用或安装全局 `mvn`。

## 运行测试

运行不依赖 Elasticsearch 的单元测试：

```bash
./mvnw test
```

单元测试验证固定索引与字段白名单、可选类目过滤、`size` 边界，以及 429 的重试上限。
真实集成测试默认跳过，因此普通测试不需要 CA 证书、API 密钥或正在运行的
Elasticsearch。

完成课程正文中的索引初始化和 API 密钥创建后，可以显式运行真实集成测试：

```bash
RUN_ES_INTEGRATION_TESTS=true \
ES_URL='https://localhost:9200' \
ES_CA='../../c04/http_ca.crt' \
ES_API_KEY='<创建 API 密钥时返回的 encoded 值>' \
./mvnw -Dtest=SearchProductsIntegrationTest test
```

该测试通过生产代码执行带类目和不带类目的两次查询，并验证课程数据的命中文档及
`Product` 字段映射。API 密钥只通过当前进程环境传入，不要写入项目文件或日志。

## 运行搜索

按照课程正文初始化索引并创建 API 密钥后，运行：

```bash
./run-search.sh \
  --api-key '<创建 API 密钥时返回的 encoded 值>' \
  --keyword '无线键盘' \
  --category 'keyboard' \
  --size 20
```

其中 `--keyword` 必填，`--category` 可省略，`--size` 可省略且默认为 20。脚本会将它们
分别导出为 `ES_SEARCH_KEYWORD`、`ES_SEARCH_CATEGORY` 和 `ES_SEARCH_SIZE`，由
`SearchProducts.main` 读取并传给商品搜索函数。`ES_SEARCH_CATEGORY` 为空字符串表示不使用
类目过滤。

脚本只开放这三个业务参数，不提供索引名、搜索字段、`available`、`_source` 或原始 DSL
参数；这些安全边界必须由 Java 代码固定。脚本还会使用 `https://localhost:9200`、
`c04/http_ca.crt` 和传入的 API 密钥，不会将密钥写入项目文件。

## 具体验收用例

初始化课程正文中的五条数据后，至少检查：

1. 使用上面的命令搜索时，只返回 `p1301`、`p1302` 和 `p1305`；不返回不可用的
   `p1303`，也不返回类目为 `accessory` 的 `p1304`。
2. 省略 `--category` 并搜索 `键盘` 时，可以返回 `p1304`，因为它的描述中包含“键盘”；
   仍不能返回 `available: false` 的 `p1303`。
3. 每个命中的 `_source` 恰好包含 `product_id`、`name`、`price` 和 `stock`，不能包含
   `description`、`category` 或 `available`。
4. 分别用 `--size 0` 和 `--size 101` 验证 Java 代码将实际请求的 `size` 限制为 1 和
   100。这个边界应通过查询构造单元测试检查，因为当前实验数据不足以仅根据命中数量区分。
5. 通过模拟客户端连续返回 429 做单元测试：前三次 429 后允许重试，第四次仍为 429
   时抛出错误；不需要为了制造 429 而压测本地 Elasticsearch。
