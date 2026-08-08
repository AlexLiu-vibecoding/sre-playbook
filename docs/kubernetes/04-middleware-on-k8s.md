# 中间件容器化部署与调优（K8s 场景）

> 覆盖：EMQX、Elasticsearch、Redis、Kafka、MySQL 等常见中间件在 Kubernetes 内的部署、运行与调优。

## 1. 通用原则

- **有状态应用用 StatefulSet**：稳定标识、有序部署、PVC 绑定。
- **存储**：独立 PVC + StorageClass；数据目录与日志目录分离。
- **资源**：显式设置 requests/limits；JVM 类应用注意容器内存限制与堆内存匹配（避免 OOMKilled）。
- **探针**：就绪探针用业务端口/接口，不要只测 TCP。
- **监控**：接入 Prometheus（exporter）+ 告警。
- **备份**：中间件数据必须有备份 Job 或云盘快照。

## 2. Elasticsearch on K8s

- 推荐 ECK（Elastic Cloud on K8s）Operator 管理。
- 关键配置：
  - `ES_JAVA_OPTS` 堆内存 = 容器内存一半。
  - 禁用 swap（`bootstrap.memory_lock` + `vm.max_map_count`）。
  - 节点角色分离（master/data/ingest）。
  - 反亲和：同一集群实例分散到不同节点。
- 常见问题：`vm.max_map_count=262144` 未设置导致启动失败；磁盘水位触发只读。

## 3. Redis on K8s

- 模式：主从 + Sentinel（如 spotahome/redis-operator）或 Cluster（redis-cluster-operator）；云上可选托管。
- 网络注意：Pod IP 会变，客户端不要直连 Pod，走 Service/Operator 提供的端点。
- 持久化：AOF 与 RDB 目录挂 PVC；`appendfsync everysec`。
- 故障演练：主从切换后客户端是否自动重连。
- 性能：避免 `sync` 大 RDB 时节点卡顿；监控内存水位。

## 4. Kafka on K8s

- 推荐 Strimzi Operator 管理。
- 关键点：
  - 每个 broker 独立 PVC；`log.dirs` 挂载。
  - 磁盘吞吐要求高，存储类型选 SSD/云盘 high IO。
  - 网络：NodePort/LoadBalancer 暴露给外部客户端，注意 advertised.listeners 正确。
  - `min.insync.replicas` 与 replication factor 设置。
- 常见问题：Pod 重建后 broker ID 变化（用 operator 管理可规避）、磁盘满。

## 5. MySQL on K8s

- 推荐：Percona Operator for MySQL（PXC）、MySQL Operator、或云托管（RDS/云数据库）——**生产首选云托管**。
- 自建要点：
  - StatefulSet + PVC；`innodb_buffer_pool_size` 按容器内存。
  - 备份：定时 `mysqldump`/物理备份到对象存储。
  - 高可用：PXC/Group Replication 或主从 + 探活切换。
  - 避免把数据库跑在共享存储/网络盘上（延迟敏感）。

## 6. EMQX（MQTT 消息中间件）

- 集群模式：节点发现（DNS 或 etcd）；`cluster.discovery` 配置。
- StatefulSet 部署；持久化会话保留需配置。
- 监听：MQTT 1883、TLS 8883、Dashboard 18083。
- 调优：`max_connections`、文件描述符上限、CPU 亲和性。
- 监控：EMQX 自带 Prometheus 指标（消息速率、连接数、会话数）。

## 7. 容器化 vs 裸机（选型判断）

| 维度 | 容器化（K8s） | 裸机/虚机 |
| --- | --- | --- |
| 弹性扩缩容 | 优 | 一般 |
| 运维自动化 | 优（Operator） | 依赖脚本 |
| 性能稳定性 | 需精细调优 | 稳定 |
| 备份恢复 | 需额外设计 | 传统方案成熟 |

**建议**：无状态/易横向扩展的（Redis、Kafka、ES）容器化收益大；强一致、延迟敏感的数据库优先托管或裸机，避免为容器化而容器化。

