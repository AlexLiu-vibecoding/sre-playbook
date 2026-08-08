# Kubernetes OOM Killer 事件完整分析总结

## 一、事件背景

在 Kubernetes 集群中，部分业务 Pod 出现频繁重启现象。通过 `kubectl describe pod <pod-name>` 查看事件，发现 `OOMKilled` 状态；结合节点日志（`/var/log/messages`）确认发生内存溢出（OOM），触发内核 OOM Killer 终止 Pod 进程。

## 二、核心原因分析

1. **应用内存泄漏**（次要原因）：应用自身内存使用持续增长。
2. **容器内存缓存未有效回收**：
   - 节点和 Pod 内存在大量 Page Cache（文件内容缓存）、dentry（目录项缓存）和 inode 缓存占用；通过 `free -h` 观察到 Cached 字段占比过高（超过总内存的 30%），导致应用可用内存被挤占。
   - 内核参数 `vm.vfs_cache_pressure` 保持默认值 100，内存紧张时缓存回收优先级较低，未及时释放缓存资源。

## 三、排查过程

### 1. 确认 OOM 事件

```bash
# 查看节点日志，定位 OOM 发生时间与对应 cgroup 路径
grep -E "invoked oom-killer|killed as a result of limit of" /var/log/messages

# 筛选因 OOM 失败的 Pod，统计涉及的业务类型和节点分布
kubectl get pods -o wide --field-selector status.phase=Failed
```

### 2. 节点缓存与内核参数检查

```bash
# 查看节点内存缓存
cat /proc/meminfo | grep -E "Cached|Buffers|MemAvailable"

# 检查内核参数（确认默认值 100，未开启缓存优先回收）
sysctl vm.vfs_cache_pressure
```

发现 Cached 占用过高（如 10GB/32GB）。

### 3. 节点资源分配核查

```bash
free -h
kubectl top nodes
```

查看节点内存总占用，确认是否因过度分配导致节点级 OOM。

## 四、解决方案

### 1. 优化节点缓存与内核参数

调整 `vm.vfs_cache_pressure`，提高缓存回收优先级，避免缓存挤占应用内存：

```bash
# 临时生效
sysctl -w vm.vfs_cache_pressure=300

# 永久生效
echo "vm.vfs_cache_pressure=300" >> /etc/sysctl.conf
sysctl -p
```

定期清理缓存：在节点上配置定时任务，低峰期清理缓存（如每日凌晨 3 点）：

```bash
echo "0 3 * * * sync && echo 3 > /proc/sys/vm/drop_caches" >> /var/spool/cron/root
```

### 2. 加强监控与告警

配置 Prometheus + Grafana 监控：

- 监控 Pod 内存使用（`container_memory_usage_bytes`）、内存限制（`container_spec_memory_limit_bytes`），设置告警阈值（如内存使用率超过 80%）。
- 监控节点内存缓存（`node_memory_Cached_bytes`），当缓存占比超过 40% 时触发告警。
- 配置 OOM 事件告警：通过 kube-eventer 收集 Kubernetes 事件，当出现 `OOMKilled` 事件时推送告警至邮件/钉钉。

### 3. 优化调度策略

- 使用节点亲和性/反亲和性：避免将内存密集型 Pod 调度至同一节点。
- 配置 Pod 拓扑分布约束：确保 Pod 均匀分布在不同节点，减少单节点压力。

## 五、预防措施

1. **应用性能测试**：上线前通过压测工具（如 JMeter、Locust）模拟高负载场景，验证应用内存峰值，确保 limits 设置充足。
2. **定期内存泄漏检测**：对长期运行的应用（如 Java、Python 应用），定期导出堆 Dump 分析，及时发现潜在泄漏点。
3. **节点资源监控**：实时监控节点内存、CPU 使用率，避免资源过度分配，预留足够缓冲空间。
4. **内核参数优化**：根据集群 workload 特征，调整 `vm.vfs_cache_pressure`、`vm.swappiness` 等参数，优化内存管理效率。

## 六、总结

本次 OOM Killer 事件的核心原因是资源配置不合理、应用内存泄漏和缓存未有效回收。通过优化资源配置、修复应用漏洞、调整内核参数和加强监控，解决了 OOM 问题，提升了集群稳定性。后续需持续遵循资源配置规范，加强应用性能测试和监控，避免类似事件再次发生。

