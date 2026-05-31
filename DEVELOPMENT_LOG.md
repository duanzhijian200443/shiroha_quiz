# 🚀 自动化 Git 提交与开发日志引擎 (Git & Changelog Engine)

## [2026-05-31 23:07] - fix(ai_sanitizer): 引入占位符隔离法并修复 JSON 反斜杠转义
- **变更类型**: fix
- **影响模块**: ai_sanitizer, ui
- **详细改动明细**:
  - [x] 修改了 `lib/utils/ai_data_sanitizer.dart`，重构 `formatLatex` 方法，引入基于占位符的 `___LATEX_BLOCK_x___` 隔离机制，试图解决多重定界符冲突问题。
  - [x] 在 `cleanAndParseJson` 中修复了由于物理换行替换引发的大模型未转义 LaTeX 反斜杠（如 `\mu`, `\frac`）造成的 JSON 解析崩溃。
  - [x] 优化 `cleanLatexBeforeDB` 以处理矩阵前的系数并加强 Markdown 块级识别。
  - [x] 修改了 `lib/ui/widgets/markdown_extensions.dart`，在内联公式 `Math.tex` 的报错 Fallback 中去除了显式的橙色字体，并增加了字数超 200 降级纯文本的安全防御。
- **验证状态**: 经本地检查记录本次变动。
