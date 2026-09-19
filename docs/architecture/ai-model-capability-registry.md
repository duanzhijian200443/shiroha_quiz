# AI Model Capability Registry — Curated Queue Evidence Manifest

Status: **Canonical evidence manifest for the curated capability queue**.

This document is the auditable evidence trail for every entry in
`ShirohaCapabilityRegistry` (`lib/domain/ai_config/shiroha_capability_registry.dart`,
definitions in `curated_model_definition.dart`). The queue is code metadata
only: it decides known capabilities, never catalog presence, never model
origin, and never persists to SQLite. Entries without official evidence stay
absent and resolve to `unknown`.

Maintenance rule: future model updates touch only this manifest plus the
exact queue — never the architecture. Every capability must be backed by an
official source; model-name inheritance, third-party blogs, and single API
calls are not evidence. `reasoning`, `toolCalling`, and `embedding` stay
unannotated unless a dedicated evidence package covers them.

Category semantics:

- `text` — text-only input/output. Writes `imageInput` / `ocr` as
  `unsupported` per the official classification.
- `vision` — image understanding through the chat path. (Currently empty for
  Zhipu: every current VLM also accepts video, which classifies it as
  `multimodal`.)
- `multimodal` — text + image input, text output; official material may add
  video/file inputs that Shiroha does not model. Same binding capabilities as
  `vision`; `ocr` stays `unsupported`.
- `ocr` — dedicated OCR / document-parsing transport (not the chat path).
  Writes `ocr` + `textOutput` as `supported`, `textInput` / `imageInput` as
  `unsupported` because the普通 VLM chat path is not the supported usage.

## Zhipu (AiProviderKind.zhipu)

Evidence date: **2026-09-19** (all rows).

| Canonical Model ID | Category | Capabilities (Shiroha) | Official Source |
|---|---|---|---|
| glm-5.3 | text | textInput=supported, textOutput=supported, imageInput=unsupported, ocr=unsupported | <https://docs.bigmodel.cn/cn/guide/models/text/glm-5.3.md> |
| glm-5.2 | text | textInput=supported, textOutput=supported, imageInput=unsupported, ocr=unsupported | <https://docs.bigmodel.cn/cn/guide/start/model-overview> |
| glm-5.1 | text | 同 glm-5.2 | 同上 |
| glm-5 | text | 同 glm-5.2 | 同上 |
| glm-5-turbo | text | 同 glm-5.2 | 同上 |
| glm-4.7 | text | 同 glm-5.2 | 同上 |
| glm-4.7-flashx | text | 同 glm-5.2 | 同上 |
| glm-4.7-flash | text | 同 glm-5.2 | 同上 |
| glm-4.6 | text | 同 glm-5.2 | 同上 |
| glm-4.5-air | text | 同 glm-5.2 | 同上 |
| glm-4.5-airx | text | 同 glm-5.2 | 同上 |
| glm-4.5-flash | text | 同 glm-5.2 | 同上 |
| glm-5.3-flash | multimodal | textInput=supported, imageInput=supported, textOutput=supported, ocr=unsupported | <https://docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash.md> |
| glm-5.3-flashx | multimodal | 同 glm-5.3-flash | 同上 |
| glm-5v-turbo | multimodal | 同 glm-5.3-flash | <https://docs.bigmodel.cn/cn/guide/models/vlm/glm-5v-turbo.md> |
| glm-4.6v | multimodal | 同 glm-5.3-flash | <https://docs.bigmodel.cn/cn/guide/models/vlm/glm-4.6v.md> |
| glm-4.6v-flashx | multimodal | 同 glm-5.3-flash | 同 glm-4.6v |
| glm-4.6v-flash | multimodal | 同 glm-5.3-flash | 同 glm-4.6v |
| glm-4.1v-thinking-flashx | multimodal | 同 glm-5.3-flash | <https://docs.bigmodel.cn/cn/guide/models/vlm/glm-4.1v-thinking.md> |
| glm-4.1v-thinking-flash | multimodal | 同 glm-5.3-flash | 同 glm-4.1v-thinking |
| glm-ocr | ocr | ocr=supported, textOutput=supported, textInput=unsupported, imageInput=unsupported | <https://docs.bigmodel.cn/cn/guide/models/vlm/glm-ocr.md> |

Notes:

- `glm-5.3` is text-only per its model page (“目前仅支持处理文本模态信息”).
- `glm-ocr` is served through the dedicated `/api/paas/v4/layout_parsing`
  endpoint and is additionally owned by Shiroha's production OCR transport
  contract (`ZhipuOcrClient`); it is materialized `curated` independent of
  `/models`.
- `glm-4.5` has no frozen evidence in this manifest (only `glm-4.5-air` /
  `glm-4.5-airx` / `glm-4.5-flash` exist as exact entries) and therefore
  stays `unknown` / 能力未标注.
- `glm-4v-flash` is intentionally not entered (legacy free tier).

## DeepSeek (AiProviderKind.deepseek)

Evidence date: **2026-09-19** (all rows).

| Canonical Model ID | Category | Capabilities (Shiroha) | Official Source |
|---|---|---|---|
| deepseek-v4-flash | text | textInput=supported, textOutput=supported, reasoning=supported, toolCalling=supported; other capabilities unknown | <https://api-docs.deepseek.com/> |
| deepseek-flash | text | textInput=supported, textOutput=supported; other capabilities unknown | <https://api-docs.deepseek.com/> |

Notes:

- DeepSeek entries predate this manifest (PR #159 Package 2) and keep their
  frozen semantics: vision stays `unknown`, not `unsupported`.
- The Agent transport allowlist (`deepseek_responses`) is independent of this
  queue and is not expanded by it.
