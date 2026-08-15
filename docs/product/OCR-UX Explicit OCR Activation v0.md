# OCR-UX Explicit OCR Activation v0

Status: **Canonical OCR-UX product/application contract. CLOSED / FROZEN.**

## 1. Authority and scope

This document is the focused authority for the OCR-UX Explicit OCR Activation v0
product and application contract.

Core invariant: **NO SILENT OCR.**

Repository-wide architectural boundaries remain authoritative in:
- `ARCHITECTURE.md`
- `docs/architecture/f1-parsed-artifact-lifecycle.md` (F1 Parsed Artifact Lifecycle)
- `docs/architecture/rag1-project-retrieval.md` (RAG-1 Project Retrieval)
- `docs/architecture/s0-secure-credential-storage.md` (S0 Secure Credential Storage)
- `docs/product/ui-finalization-ia-freeze.md` (UI Finalization)

OCR-UX v0 activates the pre-existing, verified F1 OCR ParsedArtifact capability
in production composition and exposes it through an explicit, safe, user-confirmed
Presentation flow.

OCR-UX v0 is NOT:
- a new OCR parser or provider implementation;
- an automatic or background OCR service;
- an image (PNG/JPG) OCR activation (deferred);
- a Question Import / QuestionDraft / Review pipeline;
- a schema migration or new database table;
- an MCP or Agent tool expansion.

---

## 2. Deterministic-first parse flow

When a user initiates parsing for a LibraryFile in File Detail ("解析内容"):

1. **Auto Route**: The Application calls:
   ```dart
   ensureParsedArtifact(
     fileId: fileId,
     options: ParsedArtifactParseOptions(
       routeSelection: ParsedArtifactRouteSelection.auto,
     ),
   );
   ```
2. **Deterministic Only**: The `auto` route selection is strictly deterministic:
   - PDF -> `pdf_text`
   - DOCX -> `docx_text`
   - TXT -> `txt`
   - Markdown -> `markdown`
   - `auto` NEVER triggers OCR, network requests, or provider egress.
3. **Success / Cache Hit**: If text extraction succeeds (or existing valid artifact is cached),
   the artifact becomes `available` with safe metadata (parser route, revision).

---

## 3. Scanned-PDF detection and confirmation

For a PDF file:

1. If deterministic `pdf_text` parsing yields `ParsedArtifactLifecycleFailure.sourceUnavailable`
   (e.g. no extractable text stream), the Application maps the result to `ocrRecommended`.
2. Presentation displays:
   > "未检测到可提取文本，可能是扫描版 PDF。"
   (Must not assert "这一定是扫描版 PDF".)
3. Presentation displays an explicit Confirmation Dialog before any OCR call:
   - **Title**: 未检测到可提取文本
   - **Body**:
     > 这个 PDF 可能是扫描版。
     > 是否使用 OCR 识别文件内容？
     >
     > 继续后，文件内容会发送到当前配置的 OCR 服务。
     > OCR 只用于生成可检索的文件内容，不会自动生成或修改题目。
   - **Actions**: 取消 (Cancel) / 使用 OCR (Use OCR)

---

## 4. Confirmation and cancellation invariants

1. **Cancel**:
   - Zero OCR client calls;
   - Zero network egress;
   - Zero artifact mutations;
   - File metadata remains intact and viewable.
2. **Confirm**:
   - Application calls:
     ```dart
     ensureParsedArtifact(
       fileId: fileId,
       options: ParsedArtifactParseOptions(
         routeSelection: ParsedArtifactRouteSelection.ocrPdf,
       ),
     );
     ```
   - On success, artifact is published via F1 lifecycle CAS and becomes `available`.
   - Presentation updates status to "内容已通过 OCR 解析".

---

## 5. Scope boundaries and deferred capabilities

1. **Scanned PDF Only**: OCR-UX v0 only activates scanned-PDF OCR in the UI.
   Image (PNG/JPG/JPEG) OCR activation remains deferred.
2. **No Silent Egress**: OCR MUST NOT be triggered automatically upon:
   - file ingestion / upload;
   - opening File Library or File Detail;
   - application startup or background tasks;
   - Assistant conversation or RAG query failures.
3. **Question OCR Isolation**: OCR-UX interacts only with `ParsedArtifact` and `SourceDocument`.
   It does not touch `OcrImportService`, regionizer, candidate assembler, or Question Drafts.
4. **RAG Integration**: Published OCR `ParsedArtifact` becomes the source truth for existing
   RAG lexical retrieval. No secondary cache or schema is added.

---

## 6. Production composition and application seam

1. **Composition (`main.dart`)**:
   `ParsedArtifactLifecycleService` wires `ParsedArtifactGenerationRouter`:
   - `deterministicGeneration`: `DeterministicParsedArtifactGenerationAdapter`
   - `ocrGeneration`: `OcrParsedArtifactGenerationAdapter` with `AiEngineRepository.getActiveOcrEngine`
2. **Application Seam (`U1WorkspaceFacade`)**:
   - Exposes safe DTOs (`LibraryFileArtifactState`, `LibraryFileArtifactStatus`).
   - Maps `ParsedArtifactLifecycleException` to safe user-facing outcomes.
   - Never leaks storage keys, absolute paths, raw JSON, API keys, or provider bodies to UI.

---

## 7. Storage and schema

- Current runtime schema remains **v22**.
- Zero SQLite schema migrations or new tables.
