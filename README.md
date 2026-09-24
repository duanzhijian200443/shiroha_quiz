# Shiroha Quiz

A local-first Flutter desktop app for the Chinese CS 408 postgraduate entrance exam
(考研计算机 408). You import your **own** PDF/DOCX question banks, review them with
spaced-repetition scheduling, and can opt in to AI assistance or a read-only MCP
endpoint for external clients.

> 中文简介：Shiroha Quiz 是一个本地优先的 408 刷题桌面应用（Windows）。题库由你自己导入
> （PDF/DOCX，支持 OCR 与人工校对流程），数据全部保存在本机；AI 功能可选、需要你自己配置
> 服务商密钥；本仓库不附带任何真题、题库或第三方学习资料。

## Features

- **Local-first**: no account, no cloud sync, no third-party analytics or telemetry
  SDKs. Runtime data lives under the OS application-support directory
  (`<Application Support>/Shiroha/<profile>`).
- **Import your own documents**: PDF/DOCX parsing with page/region provenance,
  explicit OCR activation for scanned pages, and a typed draft → review → confirm
  flow before anything is persisted.
- **Typed content model**: questions, options, answers and explanations are stored as
  structural `RichContent` (Markdown, LaTeX math, images, tables).
- **Study modes**: Today (今日 / 普通 / 特训 / 考试), wrong-book (错题本), FSRS-style
  review scheduling, and bounded study plans.
- **Optional AI, bring your own key**: OpenAI-compatible endpoints, DeepSeek,
  Zhipu/BigModel, SiliconFlow, Gemini-compatible endpoints, or a local Ollama
  endpoint. Keys are kept in the OS secure storage and never enter the database,
  logs, or exports. Question-import OCR and Practice photo answers are explicit
  user actions.
- **Assistant and MCP**: a built-in assistant backed by application tools, plus a
  read-only MCP server over local stdio (exactly six read tools, no write tools in
  v0). Any agent or AI mutation requires explicit user confirmation.
- **Backup and data management**: `.shiroha` backup/restore, plus destructive
  operations that require explicit confirmation.

## Requirements

- Flutter `stable` with Dart `^3.5.0` (see `pubspec.yaml`).
- Windows desktop — this repository contains only the Windows platform target.
- SQLite: the app uses the system `winsqlite3` on Windows.

## Getting started

```bash
flutter pub get
flutter run -d windows
```

Focused checks used during development:

```bash
dart format --output=none --set-exit-if-changed <changed files>
flutter analyze <changed production files>
flutter test --concurrency=1 <focused tests>
```

Full repository verification (release-level, run from the repository root in
PowerShell):

```powershell
.\scripts\verify.ps1
```

## Repository layout

| Path | Contents |
|---|---|
| `lib/` | Flutter UI, Application layer, Domain layer, Data/infrastructure |
| `test/` | Regression, characterization and acceptance tests |
| `docs/` | Architecture contracts, ADRs and product specifications |
| `tool/` | Offline acceptance / OCR-smoke tooling |
| `windows/` | Windows desktop runner |
| `ARCHITECTURE.md` | Canonical dependency and boundary contract |

## Documents and third-party rights

This repository does **not** ship exam papers, question banks, OCR output or any
other third-party study material:

- `tool/import_cases/*.json` stores only a case id, expected question count and
  document-file metadata; you supply the actual document yourself.
- The sample documents under `tools/llm_parser/` are synthetic test inputs.

Software dependencies keep their own licenses — see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). In particular
`syncfusion_flutter_pdf` is **not** MIT-licensed and requires a Syncfusion
license (community or commercial) of your own.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 段志剑 (duanzhijian200443).
