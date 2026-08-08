# SRE Playbook

运维工程笔记与工具集：CDN 与大规模文件分发、Kubernetes、中间件、监控与 SLO、DevOps 自动化、公有云实践（阿里云 / AWS）。

## 内容组织

| 模块 | 内容 | 入口 |
| --- | --- | --- |
| 网络基础 | TCP/HTTP/DNS、负载均衡 | [docs/fundamentals/](docs/fundamentals/) |
| CDN 与文件分发 | 架构、下载链路排查、发布与容量 SOP | [docs/cdn/](docs/cdn/) |
| 中间件 | MySQL、Redis、ELK、MongoDB、Nginx、Kafka 等 | [docs/middleware/](docs/middleware/) |
| Kubernetes | 架构原理、排障、扩展开发、中间件容器化 | [docs/kubernetes/](docs/kubernetes/) |
| 监控与 SLO | Prometheus/Grafana、告警治理、容量规划 | [docs/monitoring/](docs/monitoring/) |
| DevOps | CI/CD、Go/Python 自动化、On-call/变更/复盘机制 | [docs/devops/](docs/devops/) |
| 虚拟化 | VMware vSphere | [docs/virtualization/](docs/virtualization/) |
| 公有云 | 阿里云 / AWS 实践、多地域多机房部署 | [docs/cloud/](docs/cloud/) |
| 排查手册 | 高频故障速查、下载链路排查 | [docs/troubleshooting/](docs/troubleshooting/) |
| SOP | On-call、变更管理、故障响应 | [docs/sop/](docs/sop/) |
| 工具代码 | Go / Python 运维工具 | [tools/](tools/) |

## 写文档的原则

1. **经验诚实**：实操经验与学习沉淀分开标注，不虚构生产经验。
2. **可落地**：每个主题尽量按「原理 → 排查路径 → SOP」三层展开，故障场景给出可执行的排查步骤。
3. **思考可见**：排查方法论和设计取舍会写明「为什么这么做」，而不只是结论。

## 关于

- 方向：SRE / 系统运维 / 云原生运维
- 实操领域：阿里云、AWS
- 持续更新中

