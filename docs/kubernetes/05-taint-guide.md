# Kubernetes 污点（Taint）核心特性与实践指南

> 汇总污点的核心概念、常见类型、触发条件及操作方法，是节点健康检查与调度控制的关键参考资料。

## 一、污点基础概念

污点（Taint）是 Kubernetes 节点的一种属性标记，用于标记节点的调度属性。污点与 Pod 的容忍（Toleration）配合使用，共同实现集群的调度控制策略：

- 节点添加污点后，默认拒绝所有无对应容忍的 Pod 调度。
- Pod 配置容忍后，可被调度到带有对应污点的节点。
- 污点是 Kubernetes 节点自我保护机制的核心组成部分。

## 二、常见污点类型及触发条件

污点分为**自动添加**（K8s 组件自动管理）和**手动添加**（运维场景使用）两类。

### 2.1 自动添加的污点（节点自我保护）

由 kubelet 或节点控制器（kube-controller-manager）自动添加/移除，标记节点异常状态。

#### 2.1.1 资源压力类污点

节点资源（内存、磁盘、PID 等）不足时触发，避免资源耗尽导致集群异常。

| 污点名称 | 触发条件 | 含义 | 默认效果 |
| --- | --- | --- | --- |
| `node.kubernetes.io/memory-pressure` | 内存可用量低于阈值（默认约 10%） | 节点内存压力大，可能引发 OOM | NoSchedule + 部分场景 NoExecute |
| `node.kubernetes.io/disk-pressure` | 根目录 /var/lib/kubelet 可用空间 < 10% | 节点磁盘空间不足，数据写入失败风险 | NoSchedule |
| `node.kubernetes.io/pid-pressure` | 节点 PID 数量接近上限（可用 < 10%） | 无法创建新进程，Pod 启动失败 | NoSchedule |
| `node.kubernetes.io/cpu-pressure` | CPU 负载均值持续 > 80%（部分版本支持） | 节点 CPU 压力大，Pod 响应缓慢 | NoSchedule（默认可能不启用） |

#### 2.1.2 节点状态类污点

节点自身状态异常（未就绪、不可达等）时触发，保障 Pod 运行稳定性。

| 污点名称 | 触发条件 | 含义 | 默认效果 |
| --- | --- | --- | --- |
| `node.kubernetes.io/not-ready` | 节点状态为 NotReady（kubelet 故障/网络断开等） | 节点未就绪，无法正常运行 Pod | NoSchedule + NoExecute |
| `node.kubernetes.io/unreachable` | 节点控制器无法与节点通信 | 节点不可达，Pod 无法管理 | NoSchedule + NoExecute |
| `node.kubernetes.io/network-unavailable` | 网络插件（Calico/Flannel）未就绪 | 节点网络异常，Pod 无法通信 | NoSchedule |

#### 2.1.3 硬件/系统异常类污点

节点硬件或系统故障时触发，避免数据损坏或丢失。

| 污点名称 | 触发条件 | 含义 | 默认效果 |
| --- | --- | --- | --- |
| `node.kubernetes.io/disk-failure` | 磁盘检测到坏道/RAID 失效 | 磁盘硬件故障，数据风险 | NoSchedule + NoExecute |
| `node.kubernetes.io/memory-failure` | ECC 内存检测到错误 | 内存硬件故障，数据损坏风险 | NoSchedule + NoExecute |

#### 2.1.4 容器运行时类污点

容器运行时（Docker/Containerd）异常时触发，确保 Pod 正常生命周期管理。

| 污点名称 | 触发条件 | 含义 | 默认效果 |
| --- | --- | --- | --- |
| `node.kubernetes.io/container-runtime-not-ready` | 容器运行时未启动/故障 | 无法创建/管理容器 | NoSchedule |
| `node.kubernetes.io/runtime-error` | 容器运行时严重错误（镜像拉取/启动失败） | Pod 无法正常运行 | NoSchedule |

### 2.2 手动添加的污点（运维场景）

运维人员手动添加，用于节点隔离、资源专属分配等场景。

| 污点示例 | 用途 | 常用效果 |
| --- | --- | --- |
| `node-role.kubernetes.io/control-plane:NoSchedule` | 标记控制平面节点，避免调度业务 Pod | NoSchedule |
| `dedicated=gpu-node:NoSchedule` | 标记 GPU 节点，仅允许 GPU Pod 调度 | NoSchedule |
| `env=production:NoExecute` | 生产环境节点，紧急时驱逐非生产 Pod | NoExecute |
| `node.kubernetes.io/unschedulable` | 手动 cordon 节点（维护期间） | NoSchedule |

## 三、污点核心特性

1. **自动管理**：大部分污点（如 not-ready、disk-pressure）由 K8s 组件自动添加/移除，节点状态恢复后污点自动删除。
2. **效果优先级**：污点效果决定对 Pod 的影响程度，优先级从高到低：
   - **NoExecute**：立即驱逐现有无容忍的 Pod，且禁止新 Pod 调度。
   - **NoSchedule**：禁止新 Pod 调度，现有 Pod 不受影响。
   - **PreferNoSchedule**：尽量避免调度，非强制约束。
3. **容忍机制**：Pod 需通过 `tolerations` 字段配置对污点的容忍，才能被调度到带污点的节点。例如控制平面节点的容忍配置：

```yaml
tolerations:
  - key: "node-role.kubernetes.io/control-plane"
    operator: "Exists"
    effect: "NoSchedule"
```

## 四、污点操作常用命令

| 操作目的 | 命令 | 说明 |
| --- | --- | --- |
| 查看所有节点污点 | `kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}'` | 简洁输出各节点污点信息 |
| 查看指定节点污点 | `kubectl describe node <节点名称> \| grep -A 10 "Taints:"` | 详细查看单个节点的污点及触发原因 |
| 添加污点 | `kubectl taint nodes <节点名称> <污点键>:<效果>`，例：`kubectl taint nodes node-01 dedicated=gpu:NoSchedule` | 手动添加污点 |
| 移除污点 | `kubectl taint nodes <节点名称> <污点键>:<效果>-`，例：`kubectl taint nodes node-01 node.kubernetes.io/disk-pressure:NoSchedule-` | 手动移除污点 |
| 标记节点不可调度（自动加污点） | `kubectl cordon <节点名称>` | 自动添加 `node.kubernetes.io/unschedulable` 污点 |
| 恢复节点可调度（自动删污点） | `kubectl uncordon <节点名称>` | 自动移除 `node.kubernetes.io/unschedulable` 污点 |

## 五、总结

污点是 Kubernetes 实现节点健康保护与精细化调度的核心机制：

- **自动污点**：保障节点异常时的集群稳定性，避免故障扩散。
- **手动污点**：满足运维场景的节点隔离、资源专属等需求。
- 排查节点调度问题时，优先通过 `kubectl describe node` 查看污点信息，定位节点异常原因。

