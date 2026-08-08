# Kubernetes 架构与运行原理

## 1. 整体架构

```text
┌─ 控制平面（Control Plane）─────────────────────┐
│  kube-apiserver  所有操作的入口，etcd 唯一写者 │
│  etcd            集群状态存储（键值，RAFT）     │
│  kube-scheduler  为 Pod 选择合适节点            │
│  kube-controller-manager  各类控制器循环调谐    │
│  cloud-controller-manager（云环境）             │
└───────────────────────────────────────────────┘

┌─ 工作节点（Node）─────────────────────────────┐
│  kubelet         与 apiserver 通信，管理容器   │
│  kube-proxy      维护 Service 网络规则（iptables/ipvs/eBPF）│
│  CRI 运行时      容器运行时（containerd/docker）│
│  CNI 插件        容器网络（Calico/Cilium/Flannel）│
│  CSI 插件        存储接入（云盘/网络存储）      │
└───────────────────────────────────────────────┘
```

## 2. 关键对象与工作原理

### Pod

- Kubernetes 最小调度单位，一个 Pod 可含多个容器（共享网络命名空间与存储卷）。
- 生命周期：Pending → Running → Succeeded/Failed；被删除或节点故障时由控制器重建。
- 静态 Pod：由 kubelet 直接管理（常用于部署控制面组件）。

### 控制器（Controller）

- Deployment：无状态应用，负责滚动更新、副本管理。
- StatefulSet：有状态应用，稳定网络标识（`pod-0`）、稳定存储（PVC）、有序部署。
- DaemonSet：每节点一个（日志、监控 Agent）。
- Job / CronJob：一次性/定时任务。
- HPA：按指标自动扩缩容。

### Service 与网络

- Service 提供稳定访问入口；ClusterIP（集群内）、NodePort（节点端口）、LoadBalancer（云 LB）。
- kube-proxy 实现转发：iptables 模式简单但有性能瓶颈；IPVS 性能好；eBPF（Cilium）为现代推荐。
- Ingress：七层入口（HTTP/HTTPS 路由、TLS 终结）。
- DNS：CoreDNS 提供 `service.namespace.svc.cluster.local` 解析。

### 调度器

调度流程：过滤（Feasibility，资源/污点/亲和性）→ 打分（Priority，资源均衡/拓扑）→ 绑定。

## 3. 声明式与调谐循环

- 用户声明期望状态（YAML），控制器持续对比实际状态并调谐（Reconcile）。
- 理解「调谐」是理解 K8s 的钥匙：控制器重试直至达成期望，冲突时以期望状态为准。

## 4. 容器运行时接口（CRI / CNI / CSI）

| 接口 | 职责 | 实现示例 |
| --- | --- | --- |
| CRI | kubelet 与运行时通信：拉镜像、启停容器 | containerd、CRI-O、docker（经 cri-dockerd） |
| CNI | Pod 网络：IP 分配、网络策略 | Calico、Cilium、Flannel |
| CSI | 存储卷：挂载/卸载/快照 | 云盘 CSI（阿里云/aws-ebs）、NFS CSI |

## 5. 调度与资源

### 资源管理

- `requests`：调度与 QoS 依据；`limits`：运行上限。
- 服务质量：Guaranteed（requests=limits）> Burstable > BestEffort；OOM 时优先杀低 QoS 的 Pod。
- 未设置 limits 的 Burstable Pod 可能打满节点，生产建议统一资源配额（LimitRange/ResourceQuota）。

### 污点与容忍

- 污点（Taint）让节点拒绝调度；容忍（Toleration）允许特定 Pod 调度上去（如专用 GPU 节点、控制面节点）。

## 6. 高可用设计

- 控制面 ≥ 3 节点（etcd 奇数成员，多数派存活即可服务）。
- etcd 与 kubelet 证书定期巡检；备份 etcd 快照。
- 工作节点多可用区分布；Pod 反亲和（跨节点/跨可用区）。
- 关键应用多副本 + PodDisruptionBudget（PDB）防止驱逐导致全部不可用。

## 7. 版本升级

- 升级顺序：etcd → 控制面 → 工作节点；一次只升一个次要版本。
- 升级前：备份 etcd、检查 addon 兼容性、节点排空演练。
- 节点排空：`kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`。

