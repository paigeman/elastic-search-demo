# Java 客户端练习

本目录是第 13 课“练习与验收”的 Java 项目骨架，使用 mise 管理的 Java 21 和项目自带的
Maven Wrapper。无需也不应在系统中另行安装 Maven。

## 项目状态

需要由学习者完成的
[`SearchProducts.java`](./src/main/java/com/example/course13/SearchProducts.java)
已按要求保留为空文件。项目配置、官方 Elasticsearch Java 客户端依赖、运行脚本和
Maven Wrapper 已准备好。

## 验收要求

在 `SearchProducts.java` 中完成以下内容：

1. 从 `ES_URL`、`ES_CA` 和 `ES_API_KEY` 环境变量读取连接信息，使用 API 密钥和 CA
   证书创建官方 Java 客户端；不得关闭 TLS 验证，也不得在源码或日志中记录 API 密钥。
2. 实现商品搜索函数：
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
系统级 `mvn`：

```bash
./mvnw --version
./mvnw test
```

请始终使用 `./mvnw`，不要使用或安装全局 `mvn`。

## 运行搜索

完成 `SearchProducts.java` 后，先按照课程正文初始化索引并创建 API 密钥，再运行：

```bash
./run-search.sh --api-key '<创建 API 密钥时返回的 encoded 值>'
```

脚本会使用 `https://localhost:9200`、`c04/http_ca.crt` 和传入的 API 密钥，不会将密钥
写入项目文件。
