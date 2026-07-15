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

Elastic 发布的是符合开放容器倡议（OCI）规范的镜像，Podman 通常可直接运行；生产支持范围需根据你的 Elastic 订阅和平台矩阵确认。

### 无根模式与有根模式

Podman 可以使用无根模式（rootless）或有根模式（rootful）运行。无根模式是指普通用户直接执行 `podman`，Podman 通过用户命名空间把容器内的用户映射为主机上的非特权用户；容器内即使显示为 `root`，也不等于取得了主机的 root 权限。Linux 上用 `sudo podman` 或 root 用户运行的通常是有根模式。

- 无根模式不需要把主机 root 权限交给容器引擎，适合本地学习和多数普通服务，安全影响面通常更小。
- 有根模式在低端口、主机设备、网络和系统级资源管理方面限制较少，但容器进程获得的主机权限也更高。
- 两种模式的容器、镜像、网络和卷相互隔离。不要交替使用 `podman` 与 `sudo podman` 管理同一个实验，否则可能看到“容器不存在”或使用了不同的数据卷。
- 无根模式可能受从属 UID/GID、用户级控制组（cgroup）、低端口、资源限制（ulimit）、存储驱动和 systemd 用户会话影响。课程使用的 `9200` 高位端口通常不需要额外权限。

可检查当前连接是否为无根模式：

```bash
podman info --format '{{.Host.Security.Rootless}}'
```

输出 `true` 表示当前使用无根模式。

### 命令适用平台

本节命令使用 Bash/Zsh 语法，可直接用于 Linux 和 macOS 终端。Linux 上的 Docker Engine 和 Podman 直接运行 Linux 容器；macOS 和 Windows 上则分别由 Docker Desktop 或 Podman Machine 在 Linux 虚拟机中运行容器。首次使用 Podman Machine 时通常需要：

```bash
podman machine init
podman machine start
```

如果默认虚拟机已经存在，只需执行 `podman machine start`。Windows PowerShell 的环境变量和续行语法不同，不能原样复制本节的 `export` 与反斜杠续行命令。后文的 `vm.max_map_count` 是 Linux 内核参数；在 macOS 或 Windows 使用 Podman 时，需要在 Podman Machine 的 Linux 虚拟机中检查或调整，而不是修改宿主系统内核。

### 启动单节点

以下为无根模式的 Podman 示例：

```bash
export ES_VERSION=9.4.2
podman network create elastic
podman volume create esdata01
podman run --name es01 --network elastic \
  -p 9200:9200 \
  --memory 1g \
  -v esdata01:/usr/share/elasticsearch/data \
  -e discovery.type=single-node \
  -d "docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}"

podman logs es01
podman exec -it es01 \
  /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic
podman cp es01:/usr/share/elasticsearch/config/certs/http_ca.crt ./http_ca.crt

export ELASTIC_PASSWORD='真实密码'
curl --cacert ./http_ca.crt \
  -u "elastic:$ELASTIC_PASSWORD" \
  https://localhost:9200
```

说明：

- Elasticsearch 首次启动时会自动启用安全配置，并生成 HTTP 层证书及集群本地 CA。节点证书由该 CA 签发；复制 `http_ca.crt` 后，`curl --cacert` 会显式信任这个 CA，而不是关闭证书校验。
- 可使用 Quadlet/systemd 管理长期运行的容器，但生产集群还要补齐证书、资源、节点发现、备份与滚动维护方案。

## 3. 命名卷、绑定挂载与 SELinux

本节的 Docker 和 Podman 示例都使用容器引擎管理的命名卷 `esdata01`，而不是把一个普通主机目录直接挂入容器。容器引擎会管理命名卷的存储位置和安全标签，因此两种写法都不需要附加 `:Z`：

```bash
# Docker
-v esdata01:/usr/share/elasticsearch/data

# Podman
-v esdata01:/usr/share/elasticsearch/data
```

SELinux 不是 Podman 独有的考虑，也不会因为 Docker 守护进程以 root 身份运行而失效。在使用 SELinux 的 Linux 主机上可先检查状态：

```bash
getenforce
```

输出 `Enforcing` 时，SELinux 会阻止不符合策略的访问；`Permissive` 只记录违规，`Disabled` 表示未启用。在 Fedora、RHEL 等 SELinux enforcing 主机上，如果改为绑定普通主机目录，Docker 和 Podman 都可能需要正确的 SELinux 标签，参数写法相同：

```bash
-v "$PWD/esdata":/usr/share/elasticsearch/data:Z
```

`:Z` 表示把内容标记为当前容器私有；需要由多个容器共享同一目录时使用 `:z`。重新标记会修改主机目录的 SELinux 上下文，不要对 `/home`、`/usr` 等大型或系统目录随意使用。`:Z` 只处理 SELinux 标签，不能修复 UID/GID 映射或普通文件读写权限。

macOS 宿主系统没有 SELinux。Docker Desktop 和 Podman Machine 会在 Linux 虚拟机内解释挂载选项；对于它们管理的命名卷，仍然不需要 `:Z`。如果绑定 macOS 目录，虚拟机共享文件系统未必支持 Linux SELinux 扩展属性，机械添加 `:Z` 可能没有作用，或出现 `lsetxattr: operation not supported`、`operation not permitted` 等错误。此时应优先使用命名卷，并按 Docker Desktop 或 Podman Machine 的文件共享与权限机制排查。

## 4. 常见启动失败

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

## 5. 安全提醒

- `discovery.type=single-node` 仅适合单节点实验或明确的单节点用途。
- 不要为了省事设置 `xpack.security.enabled=false`。
- 仅在隔离的本机实验或临时诊断中，可以用 `curl -k` 跳过客户端对服务端证书的校验。它不会关闭 HTTPS 或身份认证，但会失去服务端身份验证，存在中间人攻击风险；企业脚本和生产环境必须使用 `--cacert`、受信任的企业 CA 或正式 CA 签发的证书。
- 不把 9200 暴露到公网；至少通过防火墙、私网和身份认证限制访问。
- 镜像使用明确版本，升级前验证兼容性；可按官方流程使用 Cosign 验证签名。

## 练习与验收

- 用 Docker 或 Podman 启动 Elasticsearch，能通过证书颁发机构证书和密码请求根接口。
- 停止再启动容器，已写入的测试文档仍存在。
- 能判断一次启动失败属于内核参数、内存还是目录权限问题。

上一节：[02｜原生部署](./02-native-installation.md)｜下一节：[04｜Compose 与 Kibana](./04-compose-and-kibana.md)
