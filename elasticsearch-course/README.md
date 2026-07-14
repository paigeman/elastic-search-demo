# Elasticsearch 从零到企业日常实战

这是一套以动手实验为主的 Elasticsearch 课程。完成全部章节后，你应该能够独立安装开发环境、设计索引、编写查询与聚合、接入数据，并处理企业中常见的权限、备份、扩容、慢查询和故障排查任务。

## 课程基线

- 文档校对日期：2026-07-14。
- 示例版本：Elasticsearch 与 Kibana `9.4.2`，两者必须使用相同版本。
- 应用程序接口（API）示例主要使用 `curl` 和 Kibana 开发工具（Dev Tools），适用于 Elasticsearch 9.x；使用其他版本时先阅读对应版本的不兼容变更说明。
- 本地学习建议 Docker/Podman；生产环境不能直接照搬单节点开发配置。
- Elasticsearch 发行包已捆绑兼容的 OpenJDK，通常不需要另装 Java。

## 学习路线

| 阶段 | 章节 | 完成后能够 |
| --- | --- | --- |
| 入门准备 | 00-04 | 选型并用原生包、Docker 或 Podman 部署 Elasticsearch 和 Kibana |
| 基础使用 | 05-10 | 完成增删改查、映射、分词、搜索、相关性和聚合 |
| 数据工程 | 11-13 | 批量写入、清洗数据、接入应用并建立稳定的数据模型 |
| 企业运维 | 14-18 | 管理生命周期、权限、监控、备份升级与性能容量 |
| 综合实战 | 19-20 | 处理日常工单并交付一个可验收的搜索项目 |

## 章节目录

1. [00｜学习准备与实验约定](./00-study-guide.md)
2. [01｜核心概念与架构](./01-core-concepts.md)
3. [02｜原生部署：压缩包、DEB、RPM 与 Windows](./02-native-installation.md)
4. [03｜容器部署：Docker 与 Podman](./03-container-installation.md)
5. [04｜使用 Compose 部署 Elasticsearch 与 Kibana](./04-compose-and-kibana.md)
6. [05｜REST API、curl 与开发工具](./05-rest-api-and-dev-tools.md)
7. [06｜索引、文档增删改查与批量操作](./06-index-document-crud.md)
8. [07｜映射、字段类型与动态映射](./07-mapping-and-field-types.md)
9. [08｜分析器、中文分词与多字段](./08-analysis-and-chinese-text.md)
10. [09｜查询语言与全文检索](./09-query-dsl.md)
11. [10｜相关性、排序、分页与高亮](./10-relevance-sort-pagination.md)
12. [11｜聚合分析](./11-aggregations.md)
13. [12｜数据接入、批量操作与摄取管道](./12-data-ingestion.md)
14. [13｜应用接入与客户端实践](./13-application-clients.md)
15. [14｜分片、副本、模板、别名与生命周期](./14-index-management.md)
16. [15｜安全：TLS、用户、角色与 API 密钥](./15-security.md)
17. [16｜监控与故障排查](./16-monitoring-and-troubleshooting.md)
18. [17｜快照、恢复与滚动升级](./17-backup-restore-upgrade.md)
19. [18｜性能优化与容量规划](./18-performance-and-capacity.md)
20. [19｜企业日常任务手册](./19-enterprise-runbook.md)
21. [20｜结课项目与验收](./20-capstone-project.md)
22. [附录｜常用 API 速查](./appendix-api-cheatsheet.md)

## 使用方法

按编号学习，不建议跳过 00-08。每节先复制命令完成实验，再做章末练习。示例中：

```bash
export ES_URL=https://localhost:9200
export ELASTIC_PASSWORD='替换为安装时生成的密码'
export ES_CA=/path/to/http_ca.crt

curl --cacert "$ES_CA" -u "elastic:$ELASTIC_PASSWORD" "$ES_URL"
```

如果只在隔离的本机临时实验，可用 `curl -k` 跳过证书校验；企业脚本必须提供可信 CA，不能保留 `-k`。

## 官方资料

- [安装 Elasticsearch](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/installing-elasticsearch)
- [Docker 安装](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-with-docker)
- [配置 Elasticsearch](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/configure-elasticsearch)
- [Elasticsearch API 文档](https://www.elastic.co/docs/api/doc/elasticsearch/)
- [版本兼容与升级](https://www.elastic.co/docs/deploy-manage/upgrade)
