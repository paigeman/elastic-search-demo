# Java 客户端练习

本目录是第 13 课“练习与验收”的 Java 项目骨架，使用 mise 管理的 Java 21 和项目自带的
Maven Wrapper。无需也不应在系统中另行安装 Maven。

## 项目状态

需要由学习者实现的入口文件是
[`SearchProducts.java`](./src/main/java/com/example/course13/SearchProducts.java)
。项目配置、官方 Elasticsearch Java 客户端依赖、运行脚本和 Maven Wrapper 已准备好；
本目录的其他文件不会代替学习者实现客户端连接、查询构造和重试逻辑。

## 验收要求

在 `SearchProducts.java` 中完成以下内容：

1. 从 `ES_URL`、`ES_CA` 和 `ES_API_KEY` 环境变量读取连接信息，使用 API 密钥和 CA
   证书创建官方 Java 客户端；不得关闭 TLS 验证，也不得在源码或日志中记录 API 密钥。
2. 实现商品搜索函数：
   - 函数只接收 `keyword`、可选的 `category` 和 `pageSize` 三个业务参数。
   - 固定使用 `application-client-products-read` 索引，不接受调用方指定索引或任意 DSL。
   - 关键词只搜索 `name` 和 `description`。
   - 只允许使用 `category` 做可选的精确过滤，并固定加入 `available: true`。
   - `_source` 只返回 `product_id`、`name`、`price` 和 `stock`。
   - `size` 默认为 20，并限制在 1～100。
3. 对安全的读取请求处理 429：初始请求失败后最多重试 3 次，即最多尝试 4 次；最后一次
   仍返回 429 时停止重试并抛出错误。
4. 程序结束时关闭客户端及其底层连接。

## 使用 Maven Wrapper

确认 Java 来自 mise：

```bash
mise current java
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

## 运行搜索

完成 `SearchProducts.java` 后，先按照课程正文初始化索引并创建 API 密钥，再运行：

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
