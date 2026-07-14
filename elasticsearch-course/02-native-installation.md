# 02｜原生部署：压缩包、DEB、RPM 与 Windows

## 本节目标

- 能按操作系统选择原生安装方式。
- 完成安全初始化、服务管理和连通性验证。
- 知道开发配置与生产配置的边界。

> 示例固定 `9.4.2` 以保证可复现。安装前可在[官方下载页](https://www.elastic.co/downloads/elasticsearch)确认新版本，并确保 Elastic Stack 各组件版本一致。

## 1. Linux/macOS 压缩包

压缩包适合学习、没有根用户（root）权限的环境或自定义目录；需要长期作为 systemd 服务运行时更推荐 DEB/RPM。

Linux x86_64 示例：

```bash
export ES_VERSION=9.4.2
wget "https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz"
wget "https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz.sha512"
shasum -a 512 -c "elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz.sha512"
tar -xzf "elasticsearch-${ES_VERSION}-linux-x86_64.tar.gz"
cd "elasticsearch-${ES_VERSION}"
./bin/elasticsearch
```

不要以根用户启动。首次启动会自动配置传输层安全协议（TLS）、生成 `elastic` 密码，并显示 Kibana 注册令牌（enrollment token）；立即安全保存。

另开终端验证：

```bash
export ELASTIC_PASSWORD='首次启动输出的密码'
curl --cacert config/certs/http_ca.crt \
  -u "elastic:$ELASTIC_PASSWORD" \
  https://localhost:9200
```

忘记密码或令牌时：

```bash
./bin/elasticsearch-reset-password -u elastic
./bin/elasticsearch-create-enrollment-token -s kibana
```

## 2. Debian/Ubuntu 安装

生产上优先使用官方 APT 仓库并锁定版本。以下展示包安装的关键流程，仓库配置以[官方 DEB 文档](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-with-debian-package)为准：

```bash
wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-9.4.2-amd64.deb
wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-9.4.2-amd64.deb.sha512
shasum -a 512 -c elasticsearch-9.4.2-amd64.deb.sha512
sudo dpkg -i elasticsearch-9.4.2-amd64.deb

sudo systemctl daemon-reload
sudo systemctl enable elasticsearch.service
sudo systemctl start elasticsearch.service
sudo systemctl status elasticsearch.service
```

默认路径：配置 `/etc/elasticsearch`，数据 `/var/lib/elasticsearch`，日志 `/var/log/elasticsearch`，程序 `/usr/share/elasticsearch`。

## 3. RHEL/Rocky/AlmaLinux 安装

```bash
sudo rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch
wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-9.4.2-x86_64.rpm
wget https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-9.4.2-x86_64.rpm.sha512
shasum -a 512 -c elasticsearch-9.4.2-x86_64.rpm.sha512
sudo rpm --install elasticsearch-9.4.2-x86_64.rpm

sudo systemctl daemon-reload
sudo systemctl enable elasticsearch.service
sudo systemctl start elasticsearch.service
```

也可按[官方 RPM 文档](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-with-rpm)配置 yum/dnf 仓库，便于版本管理。

查看日志：

```bash
sudo journalctl --unit elasticsearch --since "10 minutes ago"
sudo tail -f /var/log/elasticsearch/elasticsearch.log
```

## 4. Windows ZIP

1. 从官方下载 Windows `.zip` 并校验 SHA512。
2. 解压到不含特殊权限限制的目录，例如 `C:\elastic\elasticsearch-9.4.2`。
3. PowerShell 执行 `bin\elasticsearch.bat`。
4. 用 `curl.exe --cacert config\certs\http_ca.crt -u elastic https://localhost:9200` 验证。
5. 需要服务化管理时参考官方 Windows 安装文档，不要靠一直打开的终端充当生产服务。

## 5. 生产前必须检查

```bash
sysctl vm.max_map_count
ulimit -n
ulimit -u
```

- Linux 的 `vm.max_map_count`、文件描述符和线程限制须满足启动检查（bootstrap checks）。
- 数据目录使用本地高性能磁盘，避免网络文件系统的未知语义。
- 不要关闭安全功能或使用默认超级用户给业务应用连接。
- 设置明确的 `cluster.name`、`node.name`、数据与日志路径、节点发现配置和备份仓库。
- Java 虚拟机（JVM）堆内存通常由自动内存配置处理；确需固定时让 `Xms=Xmx`，且不要盲目超过约 31 GB。

## 练习与验收

- 任选压缩包或系统包完成一次安装。
- 重启进程/服务后，索引数据仍存在。
- 能从日志中找到启动完成信息，并用 CA 验证 HTTPS。

上一节：[01｜核心概念](./01-core-concepts.md)｜下一节：[03｜容器部署](./03-container-installation.md)
