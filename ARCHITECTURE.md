# Shiroha Quiz 架构边界规范 (Architecture Guidelines)

## 核心架构流 (Core Architecture Flow)

本项目采用严格的**单向依赖分层架构**，以确保业务逻辑的可测试性、数据持久化的安全性和代码的可维护性。

`UI Layer` ➡️ `Service Layer` ➡️ `Repository Layer` ➡️ `DatabaseHelper (SQLite)`

### 1. UI Layer (用户界面层)
- **职责**：负责页面的渲染、状态的简单控制、用户交互事件的捕捉。
- **边界限制**：
  - **绝对禁止** 直接引用 `package:sqflite/sqflite.dart`。
  - **绝对禁止** 直接调用 `DatabaseHelper.instance` 执行任何数据库读写。
  - **必须** 通过调用 `Service` 层方法或直接调用 `Repository` 层接口来获取和提交数据。

### 2. Service Layer (业务逻辑与编排层)
- **职责**：负责核心算法（如 FSRS 复习计算引擎）、异步任务队列编排、大模型对话生成、状态机控制。
- **边界限制**：
  - **绝对禁止** 直接引用 `package:sqflite/sqflite.dart`。
  - **绝对禁止** 直接调用 `DatabaseHelper.instance`。
  - 业务逻辑需要的模型数据读写，**必须**委托给对应的 `Repository`（如 `ReviewRepository`, `QuestionRepository`, `ExamRepository`）。
  - Service 应当保持为“纯粹的内存调度器”，方便脱离数据库环境进行单元测试。

### 3. Repository Layer (领域仓储层)
- **职责**：作为数据持久化的统一出口。负责将上层传来的领域模型对象（如 `ImportTask`, `QuestionDraft`）转换为数据库存储格式，或者将数据库行记录还原为领域对象。负责管理并发事务（如 `ReviewRepository.applyReviewStatesTxn`）。
- **包含组件**：
  - `AiEngineRepository` (大模型配置)
  - `ExamRepository` (模考与试卷)
  - `ImportTaskRepository` (异步导入任务)
  - `QuestionRepository` (题库核心)
  - `ReviewRepository` (FSRS引擎数据与统计)
  - `SettingsRepository` (应用配置)
  - `LatexMigrationRepository` (历史脚本迁移专用)
- **边界限制**：
  - **允许** 持有 `DatabaseHelper` 实例并调用其封装好的增删改查方法。
  - 不应该包含复杂的业务计算逻辑（那是 Service 的工作）。

### 4. DatabaseHelper (底层数据库引擎)
- **职责**：单例的 SQLite 数据库封装。负责建表（`onCreate`）、升级脚本（`onUpgrade`）、提供基础的 `query`, `insert`, `update`, `delete`, `transaction` 能力。
- **边界限制**：
  - 作为项目中最底层的核心模块，除了模型类（Model），**禁止**反向依赖任何 Repository, Service 或 UI 组件。

## ⚠️ 架构防腐红线 (Anti-Corruption Lines)
后续的任何新功能开发、脚本编写，**均不得越级调用**。
如果发现需要操作数据库的某个新场景，请首先考虑是否能复用现有的 Repository；如果跨度极大，请新建对应的 `XxxRepository`，然后供上层使用。
