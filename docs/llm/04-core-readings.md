# LLM / AI Agent 核心阅读（精选 3 篇）

> 从大量资料中挑出公认最核心的 3 篇，按阅读顺序排列。先有整体框架，再懂循环原理，最后落到工程方法。

## 1. Lilian Weng《LLM Powered Autonomous Agents》

- 作者：Lilian Weng（OpenAI）
- 链接：<https://lilianweng.github.io/posts/2023-06-23-agent/>
- 地位：被引用/阅读最广的 LLM Agent 架构入门之一，社区公认的经典综述。
- 覆盖：
  - Agent 的三大核心组件：**规划（Planning）**、**记忆（Memory）**、**工具使用（Tool Use）**
  - 代表性工作拆解：ReAct、AutoGPT、Generative Agents、HuggingGPT、ChemCrow 等
- 适合：建立 Agent 的整体框架感，理解组件之间如何协作。

## 2. ReAct：Synergizing Reasoning and Acting in Language Models

- 作者：Shunyu Yao et al.（2022）
- 链接：<https://arxiv.org/abs/2210.03629>
- 地位：Agent「思考-行动-观察」循环的奠基论文。
- 覆盖：
  - 将推理轨迹（Reasoning）与行动（Action）交织：先思考、再行动、观察结果、继续推理
  - 相比纯推理（CoT）或纯行动（Act），在可解释性、错误恢复、幻觉抑制上的改进
- 适合：理解当前绝大多数 Agent 默认循环的底层原理。

## 3. Anthropic《Building Effective Agents》

- 作者：Erik Schluntz & Barry Zhang（Anthropic）
- 链接：<https://www.anthropic.com/engineering/building-effective-agents>
- 地位：生产级 Agent 构建的权威工程指南，被大量团队直接引用。
- 覆盖：
  - **Workflow 与 Agent 的区别**：代码路径预定义 vs 模型动态决策
  - 五种基础工作流模式：Prompt Chaining、Routing、Parallelization、Orchestrator-Workers、Evaluator-Optimizer
  - Agent 设计三原则：保持简单、规划透明、精心设计工具接口（ACI）
- 适合：从工程落地角度判断「什么时候该用 Agent、工具怎么设计、复杂度怎么控制」。

## 阅读顺序

```text
1 → 2 → 3
框架感 → 循环原理 → 工程方法
```

