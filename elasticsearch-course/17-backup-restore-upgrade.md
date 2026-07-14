# 17｜快照、恢复与滚动升级

## 本节目标

- 配置快照仓库并完成恢复演练。
- 理解快照不是复制数据目录。
- 能制定兼容、可回滚的升级计划。

## 1. 快照原则

唯一受支持的集群备份方式是快照与恢复（snapshot/restore）。不要复制运行中节点的数据目录作为备份，也不要依赖独立磁盘冗余阵列（RAID）、云盘快照或数据卷本身替代集群快照。

快照仓库可以使用共享文件系统或对象存储插件。集群节点必须以一致方式访问仓库，凭据应放在密钥库或云身份中，不得以明文写入 `elasticsearch.yml`。

## 2. 文件系统仓库实验

先在所有主节点和数据节点上配置允许的仓库路径，例如：

```yaml
path.repo: ["/mnt/es-backups"]
```

滚动重启使配置生效后注册：

```http
PUT /_snapshot/course-repo
{
  "type": "fs",
  "settings": {"location":"/mnt/es-backups/course","compress":true}
}

POST /_snapshot/course-repo/_verify
```

创建快照：

```http
PUT /_snapshot/course-repo/snapshot-2026-07-14?wait_for_completion=true
{
  "indices": "products-*",
  "include_global_state": false,
  "metadata": {"reason":"course restore drill","owner":"search-team"}
}
```

查看：

```http
GET /_snapshot/course-repo/snapshot-2026-07-14
GET /_snapshot/course-repo/_status
```

## 3. 恢复演练

不要直接覆盖线上同名索引。恢复为新名称：

```http
POST /_snapshot/course-repo/snapshot-2026-07-14/_restore
{
  "indices": "products-v1",
  "include_global_state": false,
  "rename_pattern": "products-(.+)",
  "rename_replacement": "restored-products-$1"
}
```

验证文档数、映射、抽样数据、关键查询和权限。备份成功不等于能够恢复；应定期在隔离环境演练，并记录恢复点目标（RPO）和恢复时间目标（RTO）。

## 4. 快照生命周期管理

使用快照生命周期管理（SLM）定时创建、保留和删除快照。策略应覆盖业务索引、必要的功能状态与合规保留要求，并监控失败情况。不同环境或集群使用同一仓库时，只能有一个写入者，其他集群应将仓库注册为只读，以避免仓库损坏。

## 5. 升级计划

1. 阅读目标版本的发布说明、不兼容变更、插件和客户端兼容矩阵。
2. 运行升级助手和弃用接口，修复弃用项。
3. 确认最近快照成功且完成恢复演练。
4. 在预生产用真实数据量、查询和客户端验证。
5. 按官方版本路径升级，不能任意跨版本；保持 Elastic Stack 各组件版本兼容。
6. 滚动升级按官方节点顺序执行，每次等待节点加入和集群稳定。
7. 验证集群健康、分片、写入、查询、Kibana、采集链路和业务指标。

升级节点会修改磁盘数据格式，通常不能通过简单降级二进制回滚。真正回退往往需要旧版本集群 + 升级前快照/数据重放，因此升级前必须明确回滚架构。

## 练习与验收

- 创建一个快照并恢复成不同索引名。
- 抽样验证恢复索引的文档与查询。
- 写出升级前检查表，包含快照、插件、客户端、弃用项和回滚方式。

上一节：[16｜监控与排障](./16-monitoring-and-troubleshooting.md)｜下一节：[18｜性能与容量](./18-performance-and-capacity.md)
