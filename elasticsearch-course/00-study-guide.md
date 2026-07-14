# 00｜学习准备与实验约定

## 本节目标

- 知道 Elasticsearch 适合与不适合解决什么问题。
- 准备可重复使用的实验环境。
- 建立企业操作的基本习惯：先观察、再变更、后验证、可回滚。

## 1. Elasticsearch 是什么

Elasticsearch 是分布式搜索与分析引擎，常用于站内搜索、日志检索、可观测性、安全分析和近实时聚合。它擅长按相关性搜索文本、组合多条件过滤以及在大量数据上做聚合。

它通常不是关系数据库的直接替代品：不擅长复杂事务、跨表连接（JOIN）、强外键约束，也不应成为业务唯一数据源。典型架构是业务数据库保存事实，消息队列或同步任务把适合检索的数据写入 Elasticsearch。

## 2. 机器要求

学习环境最低建议：

- 64 位处理器，至少 4 GB 可用内存；同时运行 Kibana 建议 8 GB。
- 20 GB 可用磁盘。
- Docker 20.10.10+ 或较新的 Podman；也可使用 Linux/macOS/Windows 原生包。
- `curl`、文本编辑器；可选 `jq`。

先检查端口：

```bash
curl -sS http://localhost:9200 || true
curl -sS http://localhost:5601 || true
```

默认端口：`9200` 是 Elasticsearch 的 HTTP API，应用程序和 Kibana 通过它访问 Elasticsearch；`9300` 用于 Elasticsearch 集群中各 ES 节点之间的传输（transport）通信，不用于 Elasticsearch 与 Kibana 之间的通信；`5601` 是 Kibana 的 Web 服务端口。Elasticsearch 可以采用单节点部署，此时没有跨节点通信需求，通常无需对外映射或开放 `9300`；多节点部署时也只应在集群内部开放该端口，不要暴露到公网。

## 3. 统一变量

后续命令默认启用安装时自动配置的 HTTPS：

```bash
export ES_VERSION=9.4.2
export ES_URL=https://localhost:9200
export ELASTIC_PASSWORD='替换为真实密码'
export ES_CA="$PWD/http_ca.crt"

alias escurl='curl --silent --show-error --cacert "$ES_CA" -u "elastic:$ELASTIC_PASSWORD"'
```

命令行解释器（Shell）的别名（alias）在脚本中不可靠，正式脚本应封装函数或显式写完整参数。密码不要写入 Git、命令历史、Compose 文件或日志；应通过 Secret 管理系统或密钥库（keystore）保存敏感凭据，并在运行时以受限文件或环境变量的方式注入。

## 4. 学习数据约定

全课程以商品搜索为主线，文档大致如下：

```json
{
  "product_id": "p1001",
  "name": "机械键盘 K8",
  "description": "87 键无线机械键盘",
  "category": "keyboard",
  "brand": "KeyWorks",
  "price": 399.00,
  "stock": 25,
  "tags": ["wireless", "hot-swap"],
  "available": true,
  "created_at": "2026-07-01T08:00:00Z"
}
```

## 5. 企业变更四步法

1. **观察**：记录集群健康、目标索引、当前配置和指标。
2. **变更**：明确影响范围，尽量使用可撤销的小步骤。
3. **验证**：验证 API 返回、业务查询、错误率和资源指标。
4. **回滚**：别名切回、恢复配置或从快照恢复；保留操作记录。

任何删除、关闭索引、强制合并、重分片和升级操作都应先确认快照与回滚路径。

## 练习与验收

- 写出一个适合 Elasticsearch 的业务场景和一个不适合的场景。
- 能解释 9200、9300、5601 三个端口的用途。
- 在终端设置统一变量，并确保密码未进入项目文件。

下一节：[01｜核心概念与架构](./01-core-concepts.md)
