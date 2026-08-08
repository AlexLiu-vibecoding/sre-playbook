# Kubernetes 故障排查手册

> 原则：**自下而上**：先看 Pod 状态 → 事件 → 日志 → 节点资源 → 网络/存储；用 `kubectl describe` 的事件定位，不靠猜。

## 1. Pod 常见状态排查

### 1.1 Pending（无法调度）

```bash
kubectl describe pod <pod> -n <ns>
kubectl get events -n <ns> --sort-by=.lastTimestamp
```

常见原因：

- 节点资源不足（CPU/内存 requests 超节点可分配）
- 节点污点无容忍；节点 `NotReady`/`SchedulingDisabled`
- PVC 未绑定（存储不可用）
- 亲和性/反亲和无满足节点

### 1.2 ImagePullBackOff / ErrImagePull

- 镜像名/标签错误；私有仓库认证失败（imagePullSecrets）
- 镜像仓库不可达（网络/DNS）
- 查看：`kubectl describe pod` 事件中的拉取错误信息

### 1.3 CrashLoopBackOff

```bash
kubectl logs <pod> --previous   # 上一次退出的日志
kubectl logs <pod> -n <ns> --tail=200
```

原因方向：应用启动即报错、配置错误、依赖服务未就绪、探针误判（startupProbe 未给足时间）。

### 1.4 OOMKilled

- 检查 `limits` 是否过小、内存泄漏；`kubectl describe` 看 exit code 137。
- 增加内存或优化应用；用 `kubectl top pod` 看真实用量，结合压测设合理 requests/limits。

### 1.5 探针失败（Readiness/Liveness）

- Readiness 失败 → 从 Service 摘除，但不重启。
- Liveness 失败 → 重启容器（可能导致抖动）。
- 排查：探针路径/端口是否正确、超时（initialDelay、periodSeconds）是否合理、应用是否真的卡死。

## 2. 节点异常

```bash
kubectl get nodes
kubectl describe node <node>
kubectl get events -A | grep -i <node>
```

### Node NotReady

排查顺序：

1. 节点网络/SSH 是否可达（节点本身挂了还是 kubelet 挂了）。
2. kubelet 状态：`systemctl status kubelet`，证书是否过期。
3. 磁盘/内存/CPU 是否耗尽（kubelet 压力驱逐：`MemoryPressure`、`DiskPressure`）。
4. 容器运行时是否正常：`crictl ps`。
5. 磁盘空间（容器镜像/日志占满）→ 清理 + 配置日志轮转。

### 节点上的 Pod 卡 Terminating

- 强制删除：`kubectl delete pod <pod> --force --grace-period=0`（慎用，先确认应用可丢）。
- 底层原因通常是：节点失联、挂载卷未卸载、finalizer 卡住。

## 3. 网络问题

### Service 不通

```bash
# 1. Service 与 Endpoint
kubectl get svc; kubectl get endpoints <svc>
# 2. 后端 Pod 是否 Ready（readiness 探针）
kubectl get pods -o wide
# 3. 从 Pod 内测试
kubectl exec -it <pod> -- curl http://<svc>.<ns>.svc
# 4. DNS 解析
kubectl exec -it <pod> -- nslookup <svc>.<ns>.svc
```

常见原因：selector 标签不匹配（Endpoint 为空）、readiness 未通过、kube-proxy 规则异常、CoreDNS 故障。

### 跨节点 Pod 不通

- CNI 插件状态：Calico/Cilium 各组件 Pod 是否正常。
- 节点防火墙/安全组是否放行容器网段。
- 查看节点路由：`ip route`、`calicoctl node status` / `cilium status`。

### DNS 故障

- CoreDNS Pod 重启/资源不足；`kubectl -n kube-system get cm coredns` 检查配置。
- 大量 DNS 超时：调大 CoreDNS 副本、开启 NodeLocal DNSCache。

## 4. 存储问题

- PVC Pending：StorageClass 不存在、云盘配额、AZ 不匹配。
- Pod 挂载失败：`kubectl describe pod` 看 mount 事件。
- 磁盘满：PVC 容量、节点 docker/containerd 数据目录、日志。
- 快照/扩容：CSI 是否支持在线扩容（`allowVolumeExpansion`）。

## 5. 控制面问题

### apiserver 异常

- 端口 6443 探测；etcd 健康：`etcdctl endpoint health`。
- 证书过期（kubelet/apiserver 证书 1 年）：提前巡检续期。
- 大集群性能：审计日志、请求量、etcd 碎片整理。

### etcd 异常

- 成员数、磁盘空间（`defrag` 前预留空间）。
- 从快照恢复：停止 apiserver → 恢复 etcd 数据目录 → 重启。
- **定期备份 etcd + 演练恢复**是控制面安全的底线。

## 6. 排障工具箱

```bash
kubectl get events -A --sort-by=.lastTimestamp
kubectl describe pod/node/svc
kubectl logs -f <pod> --previous
kubectl top node / kubectl top pod
kubectl exec -it <pod> -- bash
ctr -n k8s.io images ls / crictl ps   # 运行时侧
```

## 7. 快速分诊表

| 症状 | 首选动作 |
| --- | --- |
| Pod Pending | describe 看调度事件 + PVC |
| Pod 反复重启 | logs --previous + describe 看退出原因 |
| 服务不通 | 查 endpoints + readiness + DNS |
| 节点 NotReady | kubelet/磁盘/内存/运行时四查 |
| 全集群异常 | 先查 apiserver/etcd 健康与证书 |
| 偶发超时 | CoreDNS、kube-proxy、网络策略、节点负载 |

