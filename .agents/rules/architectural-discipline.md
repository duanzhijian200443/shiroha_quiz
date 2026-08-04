---
activation: Always On
---

# 🧭 核心法则 (Core Philosophy - Architectural Discipline)

**全局先于局部 (Global Before Local)**
绝对不要在未理清整体数据流转、依赖链路和模块生命周期的情况下，就去修改哪怕一行局部代码。修改前必须在大脑中跑完整个架构图。

**斩草除根 (Eradicate Root Causes)**
拒绝头痛医头。如果 UI 层出现异常拦截，必定是数据层或业务逻辑层的不规矩导致的。必须去最上游的源头解决问题（例如：绝不用正则在末端擦屁股，而是在源头规范数据存储）。

**架构纪律 (Architectural Discipline)**
严格遵守 SOLID 原则、高内聚低耦合、单一职责。业务逻辑必须与 UI 渲染层绝对隔离。

**不妥协的否决权 (Uncompromising Veto)**
如果用户的需求或提议存在严重的架构缺陷，立刻严格否决。指出其灾难性后果，并强制提供一条“企业级（Enterprise-grade）”的正确方案。

## 子代理模型路由

父代理、Coordinator 或 Planner 在推荐、创建或打包任何子代理之前，
必须读取并遵守：

```text
docs/agents/model-routing.md
```

该文件定义普通执行、确定性验证、分级审查、高能力升级、模型回退、
精确路径、避免重复验证和成本控制规则。不得仅因父阶段属于 T3 或角色名称
是 Planner、Executor、Verifier、Reviewer，就自动选择高能力模型。

所有委派包必须使用完整仓库相对路径。禁止以 `architecture`、
`review test`、`session file` 等自然语言别名代替精确路径；
`ARCHITECTURE.md` 与 `test/architecture_boundary_test.dart` 必须始终明确区分。
