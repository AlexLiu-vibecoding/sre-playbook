# CI/CD：Jenkins / GitLab CI 实践

## 1. CI/CD 流程全景

```text
代码提交 → 静态检查/单元测试 → 构建制品 → 镜像构建 → 制品/镜像仓库
  → 环境部署（测试 → 预发 → 生产）→ 自动化验证 → 发布/回滚
```

## 2. 核心实践

### 流水线设计原则

- **单一可信制品**：同一个制品（镜像/包）从测试到生产不重新构建。
- **阶段化门禁**：质量门禁（测试、扫描、漏洞）不通过即失败。
- **环境隔离**：测试/预发/生产配置分离，密钥走 Secret 管理。
- **快速反馈**：提交后 10 分钟内完成构建与测试。
- **可回滚**：每次部署记录制品版本，支持一键回滚。

## 3. Jenkins 实践

### Pipeline（声明式）

```groovy
pipeline {
    agent any
    environment {
        IMAGE = "registry.example.com/app:${env.BUILD_NUMBER}"
    }
    stages {
        stage('Checkout') { steps { checkout scm } }
        stage('Test') { steps { sh 'go test ./...' } }
        stage('Build') { steps { sh 'docker build -t ${IMAGE} .' } }
        stage('Push') { steps { sh 'docker push ${IMAGE}' } }
        stage('Deploy') {
            when { branch 'main' }
            steps { sh 'kubectl set image deploy/app app=${IMAGE}' }
        }
    }
    post { failure { emailext subject: "构建失败", to: 'sre@example.com' } }
}
```

### 运维要点

- Jenkins 自身高可用：主节点 + 动态 Agent（K8s 上跑 Agent）。
- 凭据管理：用 Jenkins Credentials，不在流水线里明文写密钥。
- 共享库（Shared Library）：沉淀通用步骤（构建、推送、部署）。
- 备份：`$JENKINS_HOME` 定时备份 + 配置即代码（Jenkinsfile 入库）。

## 4. GitLab CI 实践

```yaml
stages: [test, build, deploy]

test:
  stage: test
  script:
    - go test ./...
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'

build:
  stage: build
  script:
    - docker build -t $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA .
    - docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA

deploy:
  stage: deploy
  script:
    - kubectl set image deploy/app app=$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
  environment: production
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
```

### Runner 管理

- GitLab Runner 跑在 K8s/裸机；按项目打标签（`docker`、`k8s`）。
- 并发与资源控制，防止 Runner 资源耗尽影响构建质量。

## 5. 发布与回滚

### 发布策略

- **蓝绿**：两套环境切换，回滚快但成本高。
- **金丝雀**：新版本只放 5%-10% 流量，观察指标后全量。
- **滚动更新**：K8s 默认，渐进替换（注意 maxUnavailable/maxSurge）。
- **灰度发布**：按用户/地域/比例路由（Ingress/服务网格）。

### 回滚

- 记录上次稳定版本；`kubectl rollout undo deployment/app`。
- 发布失败自动回滚（结合监控探针判断）。

## 6. 质量与安全

- 静态扫描：SonarQube、gosec、trivy（镜像漏洞）。
- 依赖锁版本，定期升级。
- 制品签名与完整性校验。
- 流水线日志脱敏（密钥不回显）。

