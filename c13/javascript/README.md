# JavaScript 客户端

本目录提供第 13 课的独立 JavaScript 客户端项目，使用 Node.js 20 或更高版本和
Elastic 官方 `@elastic/elasticsearch` 客户端。

## 安装依赖

```bash
npm ci
```

## 运行测试

```bash
npm test
```

单元测试会验证固定索引、字段白名单、`available` 过滤条件、可选类目过滤、
1～100 的结果数量限制，以及 429 响应的指数退避和最多三次重试，不需要连接
Elasticsearch。

## 运行搜索

先完成[课程正文](../../elasticsearch-course/13-application-clients.md)中的索引初始化和
API 密钥创建。若使用第 04 课的本地集群，并已将证书复制到 `c04/http_ca.crt`，可以运行：

```bash
./run-search.sh --api-key '<创建 API 密钥时返回的 encoded 值>'
```

也可以自行设置连接环境变量后直接启动：

```bash
export ES_URL='https://localhost:9200'
export ES_CA='/path/to/http_ca.crt'
export ES_API_KEY='<创建 API 密钥时返回的 encoded 值>'
npm start
```

API 密钥只通过命令行参数或环境变量传入，不要写入源码、`package.json` 或日志。
