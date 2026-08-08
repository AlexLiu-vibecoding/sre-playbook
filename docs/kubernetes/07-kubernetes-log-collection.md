# Kubernetes 应用日志采集（Fluentd / Filebeat）

> 覆盖：采集架构与模式（文件/内存缓冲）、异构上传（ES + S3）、上传策略（重试/丢弃）、Agent 内存与性能评估。以 Filebeat 与 Fluentd 为主线。

## 一、采集架构总览

### 三类日志来源

| 来源 | 位置 | 说明 |
| --- | --- | --- |
| 容器 stdout/stderr | `/var/log/containers/*.log`（软链到 `/var/log/pods/...`） | 标准输出日志，kubelet 轮转（默认 10MB × 5 个） |
| 应用文件日志 | 容器内挂载的日志目录 | 应用直接写文件（需落盘或挂载） |
| 节点/系统日志 | `/var/log/messages`、kubelet 等 | 节点级采集 |

### 四种采集模式

| 模式 | 原理 | 适用 |
| --- | --- | --- |
| 节点级 DaemonSet | 每节点一个 Agent，读本机容器日志文件 | 默认推荐：覆盖全、成本低 |
| Sidecar 模式 | 每 Pod 一个 Agent 容器，与业务容器同 Pod | 特殊格式/多行处理/独立输出 |
| 内嵌基础镜像 | Agent 打进应用基础镜像，与应用进程同容器运行 | 特殊路径/格式、跟随应用发布 |
| 应用直推（SDK） | 应用通过 SDK 直接发送日志 | 业务级结构化日志、链路日志 |

**推荐基线**：DaemonSet + 文件采集为主，特殊业务用 Sidecar 或内嵌镜像。

### 内嵌基础镜像模式（Agent 打进应用镜像）

把 Filebeat / Fluentd 二进制与配置**打进应用的基础镜像**，容器启动时与应用进程一起运行（通过 supervisord/tini 多进程管理，或 entrypoint 里后台拉起 Agent）。

```dockerfile
FROM base-app-image

# 安装并配置日志 Agent
ADD filebeat.yml /etc/filebeat/filebeat.yml
RUN curl -L -o filebeat.tar.gz https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-8.x-linux-x86_64.tar.gz \
    && tar xzf filebeat.tar.gz -C /opt/ \
    && ln -s /opt/filebeat-8.x-linux-x86_64/filebeat /usr/local/bin/filebeat

# 多进程管理：应用 + filebeat 同容器运行
ENTRYPOINT ["/usr/local/bin/supervisord", "-c", "/etc/supervisord.conf"]
```

优点：

- **跟随应用发布**：Agent 版本与配置和应用镜像一起发布、一起回滚，版本一致性最好。
- **可采容器内任意路径**：应用直接写本地文件（如 `/app/logs/*.log`），无需 stdout 或共享卷。
- **无 DaemonSet/集群依赖**：独立环境（如非 K8s 场景）也能用同一套镜像。

缺点与注意：

- **资源重复**：每个 Pod 都多一个 Agent 进程，内存/CPU 按 Pod 数线性叠加。
- **镜像变大**：镜像体积增加；Agent 升级需要重建镜像、重新发版。
- **多进程管理**：一个容器跑多个进程，违背「单容器单主进程」惯例，需要 supervisord/tini 等管理器，进程退出/崩溃要处理（Agent 挂了不影响主进程，但日志会丢）。
- **状态易失**：位置文件（pos/registry）在容器内，Pod 重建即丢失，可能重复采集；如需断点续读要挂载持久卷。
- **只能采本 Pod 日志**：无法覆盖节点/系统日志，也不适合全集群统一治理。

适用场景：应用日志路径/格式特殊且与镜像强绑定、无法用共享卷或 DaemonSet 的环境、对 Agent 版本跟随应用有严格要求的中小规模场景。

## 二、采集模式：基于文件

### 原理

Agent 以「文件尾随」方式读容器日志文件，记录读取位置（offset），支持断点续读与日志轮转。

### Filebeat（filestream input）

```yaml
filebeat.inputs:
  - type: filestream
    id: k8s-containers
    paths:
      - /var/log/containers/*.log
    parsers:
      - container: {}          # 自动解析容器日志格式（time/stream/tag 等）
    multiline:
      pattern: '^\d{4}-\d{2}-\d{2}'
      negate: true
      match: after

processors:
  - add_kubernetes_metadata:   # 注入 namespace/pod/container 等字段
      host: ${NODE_NAME}

output.elasticsearch:
  hosts: ["https://es:9200"]
  index: "k8s-logs-%{+yyyy.MM.dd}"
```

### Fluentd（tail input）

```ruby
<source>
  @type tail
  path /var/log/containers/*.log
  tag k8s.containers.*
  <parse>
    @type regexp
    expression /^(?<time>.+) (?<stream>stdout|stderr) (?<log>.*)$/
    time_format %Y-%m-%dT%H:%M:%S.%N%z
  </parse>
  pos_file /var/log/fluentd-containers.log.pos   # 断点续读位置
  read_from_head false
</source>
```

### 关键点

- **位置文件（pos/registry）**：记录读取进度，Agent 重启不重读。
- **日志轮转**：Agent 需感知文件被轮转（如 kubelet 10MB×5），轮转后无缝切新文件。
- **多行日志**：异常堆栈等多行事件，用 multiline 合并，否则一条日志被拆成多条。
- **元数据注入**：K8s 元数据（namespace/pod/container/labels）用于检索与过滤，必须注入。

## 三、采集模式：基于内存缓冲（流式）

### 原理

Agent 把采集到的事件先放入**内存队列/缓冲**，再批量（batch）上传，解耦「采集速度」与「下游处理速度」。

| Agent | 内存机制 | 默认规模 |
| --- | --- | --- |
| Filebeat | harvester 读文件 → spooler 队列 → 批量输出 | 队列默认 2048 事件，`queue.mem.events` 可调 |
| Fluentd | input → buffer（memory 或 file）→ flush 批量输出 | `chunk_limit_size`、`flush_interval` 控制批大小与节奏 |

### Fluentd 内存 buffer 示例

```ruby
<match k8s.**>
  @type elasticsearch
  <buffer>
    @type memory
    chunk_limit_size 4MB
    flush_interval 5s
    retry_type exponential_backoff
    retry_timeout 30
  </buffer>
</match>
```

### 特点与风险

- 优点：低延迟、高吞吐、批量上传效率高。
- 风险：**纯内存缓冲在 Agent 崩溃/重启时会丢数据**；不可丢日志要落盘缓冲。

## 四、异构上传策略（ES + S3）

### 为什么要异构

- **ES**：热日志，近实时检索（保留 7-30 天）。
- **S3**：合规归档（保留数月-数年），低成本。
- **Kafka/流处理**（可选）：实时计算、告警。

### Fluentd：按 tag 路由（推荐）

```ruby
# 业务日志 → ES
<match k8s.containers.business.**>
  @type elasticsearch
  hosts ["https://es:9200"]
  index_name "business-%{yyyy.MM.dd}"
</match>

# 审计/归档日志 → S3
<match k8s.containers.audit.**>
  @type s3
  s3_bucket logs-archive
  s3_region ap-southeast-1
  path logs/%Y/%m/%d/
  store_as gzip
</match>

# 同一事件同时发多路（如 ES + Kafka）用 copy
<match k8s.containers.**>
  @type copy
  <store> @type elasticsearch ... </store>
  <store> @type kafka2 ... </store>
</match>
```

### Filebeat：多输出

Filebeat 单实例默认只支持一个 output，多输出策略：

- 多实例/多配置（不同日志路径配不同 Agent）。
- 统一发到中间层（Logstash/Kafka），由下游分流到 ES/S3。
- 新版 Filebeat 支持多 output（experimental，需评估）。

### 与数据生命周期联动

```text
业务日志 → ES（热 7 天 → 冷 30 天）→ 快照转 S3 → 合规保留 2 年
审计日志 → 直接 S3（Long-term）→ S3 生命周期分层（IA → Glacier → Deep Archive）
```

采集端只负责「正确路由 + 可靠投递」，分层与保留由 ES ILM 与 S3 Lifecycle 负责。

## 五、上传策略：重试与丢弃

### 重试策略

**Filebeat**：

```yaml
output.elasticsearch:
  hosts: ["https://es:9200"]
  worker: 2
  bulk_max_size: 1600
  backoff.init: 1s
  backoff.max: 60s
```

- 下游不可达时事件保留在队列，按 backoff 重试。
- 设置合理的 `queue.mem.events`，避免队列过大占内存或过小频繁丢弃。

**Fluentd**：

```ruby
<buffer>
  @type file            # 不可丢日志用 file buffer
  path /var/log/fluentd-buffer
  retry_max_times 10
  retry_timeout 60
  retry_backoff_base 2
</buffer>
```

- 重试参数：`retry_max_times`（次数）、`retry_timeout`（总时长）、backoff 递增。
- 超过重试上限或缓冲满时的行为由 `overflow_action` 决定。

### 丢弃策略

| 策略 | 行为 | 适用 |
| --- | --- | --- |
| `block`（Fluentd 默认） | 缓冲满时阻塞采集 | 不可丢日志（审计/计费） |
| `drop_oldest` | 缓冲满时丢弃最旧数据 | 可丢日志（性能/调试） |
| `throw_exception` | 抛异常停止 | 需要人工介入 |
| Filebeat 队列满 | 事件在 harvester 侧堆积或丢弃（`queue.flush` 相关） | 需监控队列水位 |

**原则**：

1. **先分类**：明确哪些日志不可丢（审计、计费、合规），哪些可丢（性能、debug）。
2. **不可丢**：file buffer（落盘）+ 重试上限 + 丢弃告警。
3. **可丢**：内存缓冲 + 限流 + `drop_oldest`，并记录丢弃计数。
4. **背压**：下游持续不可用时放慢采集（而不是无限堆积内存），避免 Agent OOM。

## 六、内存占用与性能评估

### Agent 资源特征

| Agent | 内存特征 | CPU 特征 |
| --- | --- | --- |
| Filebeat（Go） | 较低（通常几十-几百 MB），受队列大小影响 | 文件读取 + 解析 + 压缩，与日志量线性相关 |
| Fluentd（Ruby） | 较高（buffer、插件、GC 开销），几百 MB-1GB+ 常见 | 解析/过滤/多输出开销大，高吞吐需调优 |

### 关键评估指标

- **吞吐**：events/s、MB/s（每节点日志量）。
- **内存**：RSS、heap、GC 频率（Fluentd 尤其关注）。
- **CPU**：采集、解析、压缩占比。
- **可靠性**：队列积压、丢弃数、重启次数。

### 估算与调优

```text
1. 压测基线：单 Agent 在目标日志量（如 1MB/s、2000 events/s）下的内存/CPU
2. 按节点规模放大：节点日志量 × 节点数 = 总量，反推 Agent 规格
3. 调优手段：
   - 批量：bulk_max_size / chunk_limit_size 调大，减少请求数
   - flush_interval：适当延长，聚合更高效
   - 压缩：gzip（S3/ES 都支持），降带宽与存储
   - 简化解析：少用复杂正则、合并多行、裁剪不需要的字段
   - 过滤前置：在采集端就丢弃无用日志，减少后续开销
```

### K8s 资源建议

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: "1"
    memory: 512Mi
```

- 用 requests 保证基础资源，limits 防止打爆节点。
- 监控 Agent 自身（Filebeat HTTP endpoint、Fluentd monitor_agent），对积压/丢弃/OOM 告警。

## 七、生产建议与检查清单

- [ ] 默认 DaemonSet + 文件采集；特殊场景 Sidecar
- [ ] 位置文件持久化（hostPath），重启不重读
- [ ] 多行日志合并规则正确
- [ ] K8s 元数据注入完整
- [ ] 路由策略明确（ES 热 / S3 归档）
- [ ] 不可丢日志用落盘 buffer + 重试 + 告警；可丢日志限流 + 丢弃计数
- [ ] Agent 资源 requests/limits 已设置
- [ ] Agent 指标与告警（积压、丢弃、OOM、重启）已配置
- [ ] 压测基线记录，容量随节点数扩展
