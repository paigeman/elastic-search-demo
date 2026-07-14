# 04｜使用 Compose 部署 Elasticsearch 与 Kibana

## 本节目标

- 用 Compose 启动可持久化的学习环境。
- 完成 Kibana 注册。
- 理解这个 Compose 示例为何不是生产架构。

## 1. 编写 Compose 文件

在你自己的实验目录创建 `.env`：

```dotenv
STACK_VERSION=9.4.2
ES_PORT=9200
KIBANA_PORT=5601
MEM_LIMIT=1073741824
```

创建 `compose.yml`：

```yaml
services:
  es01:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    container_name: es01
    environment:
      - discovery.type=single-node
    ports:
      - "127.0.0.1:${ES_PORT}:9200"
    volumes:
      - esdata01:/usr/share/elasticsearch/data
    mem_limit: ${MEM_LIMIT}
    healthcheck:
      test: ["CMD-SHELL", "curl -s --cacert config/certs/http_ca.crt https://localhost:9200 | grep -q 'missing authentication credentials'"]
      interval: 10s
      timeout: 10s
      retries: 60

  kib01:
    image: docker.elastic.co/kibana/kibana:${STACK_VERSION}
    container_name: kib01
    ports:
      - "127.0.0.1:${KIBANA_PORT}:5601"
    depends_on:
      es01:
        condition: service_healthy

volumes:
  esdata01:
```

启动并观察：

```bash
docker compose up -d
docker compose ps
docker compose logs -f es01
```

Podman 用户可尝试 `podman compose up -d`；不同 Compose 提供程序的行为可能不同，先用 `podman compose version` 确认。

## 2. 获取凭据并连接 Kibana

```bash
docker exec -it es01 \
  /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic

docker exec -it es01 \
  /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana
```

浏览器打开 `http://localhost:5601`，粘贴注册令牌，再用 `elastic` 和重置后的密码登录。若 Kibana 要求验证码（verification code）：

```bash
docker exec -it kib01 bin/kibana-verification-code
```

Elasticsearch 与 Kibana 必须使用完全相同的版本号。

## 3. Kibana 初识

- **开发工具 / 控制台（Dev Tools / Console）**：执行 REST API，是后续主要实验界面。
- **发现（Discover）**：浏览与筛选文档，需要先创建数据视图（data view）。
- **仪表盘 / Lens（Dashboards / Lens）**：构建可视化和仪表盘。
- **技术栈管理（Stack Management）**：管理索引、数据视图、用户角色、API 密钥等。

在开发工具中运行：

```http
GET /
GET /_cluster/health
GET /_cat/nodes?v
```

## 4. 为什么这不是生产方案

它只有一个节点、一个本地数据卷，没有跨主机容灾、可信企业证书、备份、集中日志、监控告警或容量规划。生产环境至少要重新设计：

- 多节点与故障域、节点角色和分片策略。
- 密钥管理、最小权限、TLS 证书生命周期。
- 持久卷性能、快照仓库和恢复演练。
- 资源限制、启动检查、监控告警与升级流程。

## 练习与验收

- `docker compose ps` 显示 Elasticsearch 健康、Kibana 正在运行。
- 能登录 Kibana，并在开发工具中查看集群健康状态。
- 解释注册令牌与用户密码的区别。

上一节：[03｜容器部署](./03-container-installation.md)｜下一节：[05｜REST API](./05-rest-api-and-dev-tools.md)
