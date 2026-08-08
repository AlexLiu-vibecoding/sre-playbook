# 运维自动化：Go / Python 工具开发

> 运维自动化的核心能力：用 Go / Python 开发工具与平台模块。

## 1. 自动化选型

| 场景 | 推荐 |
| --- | --- |
| 批量脚本、数据处理、云 SDK 调用 | Python |
| 高并发工具、Agent、CLI、平台服务 | Go |
| 运维平台后端 | Go（性能）/ Python（快速迭代） |
| 指标/API 集成 | 两者皆可，看团队技术栈 |

## 2. Python 自动化示例

### 批量巡检

```python
import subprocess
import concurrent.futures

HOSTS = ["10.0.0.1", "10.0.0.2"]

def check_disk(host):
    r = subprocess.run(
        ["ssh", host, "df -h / | tail -1"],
        capture_output=True, text=True, timeout=10,
    )
    return host, r.stdout.strip()

with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
    for host, out in ex.map(check_disk, HOSTS):
        print(f"{host}: {out}")
```

### 云 API 封装（以 AWS boto3 为例）

```python
import boto3

ec2 = boto3.client("ec2", region_name="ap-southeast-1")
res = ec2.describe_instances(
    Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
)
for r in res["Reservations"]:
    for i in r["Instances"]:
        print(i["InstanceId"], i.get("InstanceType"), i.get("PublicIpAddress"))
```

## 3. Go 自动化示例

### 健康检查 CLI

```go
package main

import (
	"fmt"
	"net/http"
	"time"
)

func main() {
	targets := []string{"https://example.com/healthz"}
	for _, u := range targets {
		start := time.Now()
		resp, err := http.Get(u)
		if err != nil {
			fmt.Printf("%s DOWN: %v\n", u, err)
			continue
		}
		resp.Body.Close()
		fmt.Printf("%s OK status=%d cost=%v\n", u, resp.StatusCode, time.Since(start))
	}
}
```

### 并发批量任务（goroutine + errgroup）

```go
var g errgroup.Group
for _, node := range nodes {
	node := node
	g.Go(func() error {
		return drainNode(node)
	})
}
if err := g.Wait(); err != nil {
	log.Fatal(err)
}
```

## 4. 运维平台模块设计

### 典型模块

- **资产/CMDB**：主机、IP、业务归属、生命周期。
- **发布平台**：制品管理、灰度策略、发布记录、回滚。
- **任务平台**：批量执行、审批流、结果回传。
- **告警处理**：告警接收、认领、升级、关闭。
- **容量平台**：资源水位、预测、扩容工单。

### 平台工程原则

1. **权限与审批**：高危操作（删除、生产变更）必须有审批与审计。
2. **幂等与重试**：任务可重跑，结果可对账。
3. **可观测**：平台自身接入监控与日志。
4. **API 优先**：能力沉淀为 API，UI 只是壳。
5. **数据闭环**：记录每次操作，支撑复盘与统计。
