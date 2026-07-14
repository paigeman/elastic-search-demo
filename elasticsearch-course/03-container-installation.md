# 03｜容器部署：Docker 与 Podman

## 本节目标

- 使用 Docker 或 Podman 启动持久化单节点。
- 处理密码、证书、内存和 Linux 内核参数。
- 理解容器命令适用范围。

## 1. Docker 快速启动

```bash
export ES_VERSION=9.4.2
docker network create elastic
docker pull "docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}"
docker volume create esdata01

docker run --name es01 --net elastic \
  -p 9200:9200 \
  -m 1GB \
  -v esdata01:/usr/share/elasticsearch/data \
  -e discovery.type=single-node \
  -it "docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}"
```

首次启动输出密码。若错过输出：

```bash
docker exec -it es01 \
  /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic
```

复制 CA 并验证：

```bash
docker cp es01:/usr/share/elasticsearch/config/certs/http_ca.crt ./http_ca.crt
export ELASTIC_PASSWORD='真实密码'
curl --cacert ./http_ca.crt -u "elastic:$ELASTIC_PASSWORD" https://localhost:9200
```

容器生命周期命令：

```bash
docker stop es01
docker start es01
docker logs --tail 100 es01
docker stats es01
```

不要用删除容器验证持久化，除非你清楚数据卷仍在且删除动作符合环境管理规则。命名卷与容器生命周期分离，但它不是备份。

## 2. Podman 等价部署

Elastic 发布的是符合开放容器倡议（OCI）规范的镜像，Podman 通常可直接运行；生产支持范围需根据你的 Elastic 订阅和平台矩阵确认。以下为无根模式（rootless）的 Podman 示例：

```bash
export ES_VERSION=9.4.2
podman network create elastic
podman volume create esdata01
podman run --name es01 --network elastic \
  -p 9200:9200 \
  --memory 1g \
  -v esdata01:/usr/share/elasticsearch/data:Z \
  -e discovery.type=single-node \
  -d "docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}"

podman logs es01
podman exec -it es01 \
  /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic
podman cp es01:/usr/share/elasticsearch/config/certs/http_ca.crt ./http_ca.crt
```

说明：

- 启用 SELinux 的主机进行绑定挂载（bind mount）或卷挂载时，通常需要 `:Z` 或正确的安全上下文。
- 无根容器受用户级控制组（cgroup）、端口、资源限制（ulimit）和 systemd 会话影响。
- 可使用 Quadlet/systemd 管理长期运行的容器，但生产集群还要补齐证书、资源、节点发现、备份与滚动维护方案。

## 3. 常见启动失败

### `vm.max_map_count` 太低

Linux 主机临时调整：

```bash
sudo sysctl -w vm.max_map_count=1048576
```

生产环境应写入系统配置并由基础设施代码管理，重启后复核。Docker Desktop 的设置位置依平台版本而异。

### 容器因内存不足被终止

```bash
docker inspect es01 --format '{{.State.OOMKilled}}'
docker stats es01
```

给容器设置合理的内存限制，不要仅调小堆内存来掩盖聚合或分片设计问题。

### 数据目录无权限

命名卷通常更省心。使用绑定挂载时，确保容器内 Elasticsearch 用户可写，且 SELinux 标签正确；不要粗暴使用 `chmod 777`。

## 4. 安全提醒

- `discovery.type=single-node` 仅适合单节点实验或明确的单节点用途。
- 不要为了省事设置 `xpack.security.enabled=false`。
- 不把 9200 暴露到公网；至少通过防火墙、私网和身份认证限制访问。
- 镜像使用明确版本，升级前验证兼容性；可按官方流程使用 Cosign 验证签名。

## 练习与验收

- 用 Docker 或 Podman 启动 Elasticsearch，能通过证书颁发机构证书和密码请求根接口。
- 停止再启动容器，已写入的测试文档仍存在。
- 能判断一次启动失败属于内核参数、内存还是目录权限问题。

上一节：[02｜原生部署](./02-native-installation.md)｜下一节：[04｜Compose 与 Kibana](./04-compose-and-kibana.md)
