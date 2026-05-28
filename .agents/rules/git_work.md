# 🚀 自动化 Git 提交与开发日志引擎 (Git & Changelog Engine)

## 🎯 激活条件 (Activation Triggers)
当人类下达包含以下指令或意图时，必须无条件拦截并触发本规则流：
**关键词**：“commit”、“提交”、“push”、“推送到远程”、“备份代码”、“存盘”、“生成日志”。
*注意：在准备调用本地 Git 终端工具之前，必须强制前置执行本套协议。*

## ⚙️ 核心执行协议 (Standard Operating Procedure)

### 步骤 1：【变更深度侦查】(Diff Analysis)
绝对禁止凭空捏造或凭记忆伪造提交说明！
你必须首先调用终端工具执行 `git status` 和 `git diff --cached`（或 `git diff`）。
精准提取本次真实修改的文件列表、受影响的逻辑模块以及具体的代码变动。

### 步骤 2：【组装 Angular 规范日志】(Commit Message Generation)
基于步骤 1 的侦查结果，在你的“大脑（Thinking）”中生成 100% 严格符合 Angular 规范的 Commit Message。格式如下：

    <type>(<scope>): <subject>
    
    [optional body]

**参数约束字典**：
- **type (类型)** 必须严格限定为：
  - `feat`: 新增功能、新页面、新业务架构
  - `fix`: 修复 Bug、解决崩溃或异常
  - `docs`: 文档变更（如 README、注释更新）
  - `style`: 代码格式调整（不影响运行逻辑的 UI 颜色、空格、排版）
  - `refactor`: 重构代码（既不是新增功能也不是修复 Bug 的底层优化/拆分）
  - `test`: 增加或修改测试用例
  - `chore`: 构建过程、依赖变动（如更新 pubspec.yaml）
- **scope (作用域)**：受影响的模块名（如 `database`, `ui`, `ai_engine`, `rag`）。
- **subject (主题)**：用一句精炼的中文简述改动，动词开头，绝不超过 50 个字。

### 步骤 3：【全自动沉淀开发日志】(Update DEVELOPMENT_LOG.md)
在执行本地 `git commit` 之前，必须调用文件读写工具：
1. 检查项目根目录下是否存在 `DEVELOPMENT_LOG.md`（若不存在则调用 `write_file` 自动创建）。
2. 将本次变更记录以高可读性的结构，**前置追加（Prepend/Insert at the top）**到该文件的顶部。

**日志写入模板规范**：
    ## [YYYY-MM-DD HH:mm] - <Angular 规范中的主标题>
    - **变更类型**: <type>
    - **影响模块**: <scope>
    - **详细改动明细**:
      - [x] 修改了 `xxx.dart`，优化了 YYY 逻辑。
      - [x] 补齐了 ZZZ 的防御性编程，修复了潜在崩溃。
    - **验证状态**: 经本地静态检查/重构验证通过。

### 步骤 4：【原子化存盘与云端同步】(Atomic Execution)
在完成步骤 3 的文件写入后，按照以下绝对顺序调用终端执行命令：
1. `git add DEVELOPMENT_LOG.md`（将刚才更新的日志加入暂存区）。
2. `git add .`（或精准 add 相关文件，确保无遗漏）。
3. `git commit -m "<在此处填入步骤2生成的 Message>"`。
4. `git push`（推送到远程仓库）。

## 🚨 终极防御自检 (Red Line Check)
在执行步骤 4 之前，你必须停顿审查：写入日志文件的修改项，是否与 `git diff` 的实际变动**百分之百对齐**？是否存在漏记或错记？
全部成功执行后，使用极其专业、极客的语气向人类汇报：
**“报告长官：已按照 Angular 规范完成代码原子化存盘，开发日志（DEVELOPMENT_LOG.md）已同步更新，代码已安全推送至远端仓库！”**