# 第 13 课客户端示例

不同语言的客户端分别放在独立目录中，避免依赖和运行命令互相影响：

- `python/`：使用 `uv` 管理的 Python 客户端示例；可选的 `run-search.sh` 会配置第 04 课集群的 URL 和 CA，并通过 `--api-key` 接收 API 密钥后运行搜索脚本。
- `javascript/`：使用 npm 管理的 JavaScript 客户端示例；`run-search.sh` 会配置第 04
  课集群的 URL 和 CA，并通过 `--api-key` 接收 API 密钥后运行搜索脚本。
- `java/`：使用 Java 21 和项目级 Maven Wrapper 的客户端练习实现，包含单元测试和可选的
  真实 Elasticsearch 集成测试。

实验数据、API 密钥和运行步骤参见
[第 13 课正文](../elasticsearch-course/13-application-clients.md)。
