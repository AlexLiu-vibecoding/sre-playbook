# Prometheus / Grafana：指标采集、告警与可视化

## 1. 监控体系设计

### 监控什么（指标选型）

- **USE 法（资源）**：利用率（Utilization）、饱和度（Saturation）、错误（Errors）——CPU、内存、磁盘、网络。
- **RED 法（服务）**：速率（Rate）、错误（Errors）、耗时（Duration）——请求维度的黄金指标。
- **四大黄金信号**：延迟、流量、错误、饱和度。

### 分层采集

```text
基础设施层：node_exporter（CPU/内存/磁盘/网络）、blackbox_exporter（探活）
容器层：cAdvisor / kube-state-metrics（容器与 K8s 对象状态）
中间件层：mysqld_exporter、redis_exporter、elasticsearch_exporter、kafka_exporter 等
应用层：客户端埋点（Prometheus 客户端库/OpenTelemetry）
业务层：核心业务指标（下载成功率、支付成功率等）
```

## 2. Prometheus 核心

### 抓取与存储

```yaml
scrape_configs:
  - job_name: node
    static_configs:
      - targets: ["10.0.0.1:9100"]
```

- 数据模型：`metric{label=value} 数值 @ 时间戳`。
- 查询：PromQL，如 `rate(http_requests_total[5m])`、`histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))`。
- 存储：本地 TSDB，默认保留 15 天；大规模/长期用 Thanos/Mimir 或云托管。

### 高可用

- 多副本 + 远程写（remote write）；告警由 Alertmanager 去重。
- 容量规划：指标基数（时间序列数量）× 采样频率 × 保留时间。

## 3. Alertmanager 告警设计

### 告警规则

```yaml
groups:
  - name: node
    rules:
      - alert: NodeDown
        expr: up{job="node"} == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "节点 {{ $labels.instance }} 失联"
```

### 告警治理原则

1. **分级**：critical（立即处理）/ warning（工作时间内处理）/ info（知会）。
2. **抑制**：父故障不重复告警（如节点宕机时抑制该节点所有 Pod 告警）。
3. **聚合**：Alertmanager 分组（按业务/集群），避免告警风暴。
4. **路由**：按团队/优先级路由到不同接收人（钉钉/邮件/Slack）。
5. **`for` 时长**：持续一定时间才告警，过滤抖动。
6. **定期治理**：统计误报/漏报/重复告警，持续收敛。

### 告警质量检查表

- 每条告警有明确的「如何排查」链接（runbook）。
- 有阈值依据（基于容量数据，而不是拍脑袋）。
- 有恢复通知（resolve）。
- 没有「永远在响」的告警（无效告警比没有告警更糟）。

## 4. Grafana

- 面板组织：按业务/团队，统一 Dashboard 规范。
- 常用面板：节点总览、Pod 总览、服务 RED、中间件面板、容量面板。
- 数据源：Prometheus、Loki（日志）、CloudWatch、阿里云监控等。
- 权限：Viewer/Editor/Admin 分级；敏感面板限制访问。
- 告警（可选）：Grafana 告警 vs Alertmanager——生产建议 Alertmanager 为主，Grafana 做展示。

## 5. 日志与指标联动（可观测性三角）

```text
指标（Prometheus）：发生了什么变化、什么时候开始
日志（Loki/ELK）：具体报错内容、上下文
链路（Jaeger/Tempo/OTel）：请求在哪一环慢
```

排查标准动作：告警 → 指标对比（故障窗口）→ 日志定位 → 链路确认 → 根因。

