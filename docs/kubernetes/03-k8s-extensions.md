# Kubernetes 扩展开发：Operator、CNI/CSI/CRI、调度

## 1. Operator 模式

### 解决的问题

有状态应用（数据库、消息队列）需要大量领域操作：初始化、备份、扩缩容、故障自愈。原生控制器不知道「MySQL 集群」的语义，Operator 把领域知识编码进控制器。

### 核心组件

- **CRD**：自定义资源定义（如 `MysqlCluster`），声明期望状态。
- **Controller**：监听 CR 变化，调谐实际资源（StatefulSet、Service、备份 Job 等）。
- **Webhook**（可选）：校验/默认值（admission webhook）。

### 开发框架

- **Kubebuilder**（controller-runtime）：官方推荐，生成脚手架。
- **Operator SDK**：基于 controller-runtime 的上层封装。
- **核心循环**：`Reconcile(ctx, req)` 收到事件 → 读取现状 → 对比期望 → 执行变更 → 返回（可 requeue）。

### 一个简单 Operator 的步骤

1. 定义 CRD（`kubebuilder init && create api`）。
2. 实现 Reconcile：创建/更新 StatefulSet、Service，维护状态字段。
3. 处理删除（finalizer）：清理依赖资源。
4. 写测试（envtest）+ 部署（make manifests、make deploy）。

### 设计要点

- 幂等：任何时刻重跑 Reconcile 结果一致。
- 事件驱动 + 定时校验（resync），防止状态漂移漏处理。
- 版本升级策略：先升级 controller，再处理 CR 的新字段。

## 2. CNI（容器网络）

### 职责

- 为 Pod 分配 IP、创建 veth/路由/策略。
- 主流实现：Calico（BGP + iptables/eBPF 策略）、Cilium（eBPF，性能与可观测性强）、Flannel（简单 overlay）。

### 排查与优化

- 网络策略（NetworkPolicy）放通问题排查。
- 大规模集群：Calico 路由数量、Cilium eBPF 资源占用。
- IP 池耗尽：IPAM 配置（`ipPool` / IP 段扩容）。

## 3. CSI（容器存储）

### 职责

- 统一存储接入：创建卷（Provision）、挂载（Attach/Mount）、快照、扩容。
- 云环境通常用官方 CSI：阿里云 CSI（云盘/NAS/OSS）、AWS EBS/EFS CSI。

### 常见运维

- StorageClass 参数（磁盘类型、AZ、回收策略）。
- 在线扩容前提：StorageClass `allowVolumeExpansion: true` 且驱动支持。
- 卷挂载失败排查：节点侧 `lsblk`、`mount` 日志、CSI 驱动 Pod 日志。

## 4. CRI（容器运行时）

### 关键点

- containerd 是当前主流运行时；`ctr`/`crictl` 是运维排障工具。
- kubelet 通过 CRI 调用运行时；sandbox（pause）容器提供 Pod 网络命名空间。
- 运行时故障：镜像 GC、快照磁盘占用、`/var/lib/containerd` 空间。

## 5. 调度器扩展

### 方式

- **调度器扩展点（Scheduling Framework）**：PreFilter/Filter/Score 等扩展点，官方推荐。
- **自定义调度器**：独立部署的第二个 scheduler，Pod 指定 `schedulerName`。
- **调度器插件**：如 NodeAffinity、TaintToleration 等内置插件可组合。

### 场景

- 自定义拓扑约束（多机房打散）。
- 结合成本/资源预测的评分。
- GPU/特殊资源感知调度。

## 6. 其他扩展点

- **HPA 自定义指标**：对接 Prometheus Adapter，按业务指标扩缩容。
- **Admission Webhook**：资源校验、注入（如自动注入 sidecar）。
- **Custom Resource + 控制器**：业务侧自定义平台能力。
