# RAG-1 Local Lexical Retrieval Contract

Status: **Canonical RAG-1 v0 contract. RAG-1 is COMPLETE.**

## 1. Scope and authority

RAG-1 provides local, offline, deterministic lexical retrieval behind existing
File, Project, Conversation, and Built-in Agent concepts. It is not a separate
knowledge-base product domain. The only content authority is the current,
verified F1 `SourceDocument` obtained through the Application lifecycle seam:

```text
LibraryFile -> current ParsedArtifact -> verified SourceDocument
            -> deterministic chunks -> SQLite derived cache / FTS5
            -> Application RetrievalService -> Built-in Agent tool
```

RAG never reads managed original paths, sidecar paths, provider payloads,
Question Store rows, P6/P7 candidates, or legacy `questions_fts` as retrieval
authority. `RawFallbackNode` payloads, binary images, Base64, image paths,
credentials, provider configuration, and raw diagnostics are never indexed,
returned, or logged.

## 2. Deterministic projection and identity

`rag1.chunk.v1` projects `SourcePart` order, content kind, page/block locator,
nearest heading, part/window ordinal, and safe `SourceRef` provenance.
Paragraphs, headings, formulas, answer-like content, bounded table row groups,
and explicit image alternative text are supported. Unsupported parts and raw
fallback nodes are excluded with a typed per-file issue.

Oversized content uses at most 1200 Unicode scalars with 200-scalar overlap,
preferring newline, whitespace, then a deterministic hard cut. Windows never
cross a `SourcePart` boundary. Chunk identity binds version, file/artifact
generation, source, locator/ordinals, and normalized content digest. Reparse
therefore changes identity even when text is unchanged; rebuilding the same
generation is stable.

## 3. Schema v21 and cache lifecycle

Runtime schema v21 additively introduces:

- `retrieval_index_builds` for the exact file/artifact/revision/payload digest,
  chunker version, lexical projection version, count, and digest;
- `retrieval_index_heads` for the currently visible build per file;
- `retrieval_chunks` for safe content and provenance;
- `retrieval_chunks_fts`, an FTS5 external-content index.

The three `retrieval_chunks` triggers are the sole FTS synchronization
authority. Application/repository code never writes the FTS table directly.
Build creation, chunk insertion, head replacement, and old-build cleanup are
transactional. A failed build never falls back to an older generation.
Deletion cascades derived rows only and never changes authoritative content.

Queries capture the ordered distinct scope and current artifact tuples,
ensure exact builds, validate current tuples again, then execute inside a
SQLite read transaction that joins both the visible retrieval head and current
`parsed_artifacts` row. A generation change before the read snapshot is
`sourceChanged`; an already-valid read snapshot may complete.

## 4. Scope, lexical query, ranking, and DTOs

Supported scopes are explicit `files(fileIds)`, `project(projectId)`, and
`conversationAttachments(conversationId)`. Whole-library retrieval is
deferred. Project and Conversation membership are captured once and never
implicitly expand to banks, historical attachments, nearby/same-name files, or
the complete File Library.

Lexical v1 indexes separate weighted heading and body projections. Tokens are
deterministic word terms plus CJK bigrams. Application code creates a quoted
MATCH expression using word OR groups and CJK-bigram AND groups; raw user FTS
grammar is never accepted. Ranking is BM25 best first with stable file,
ordinal, and chunk identity tie breaks. `lexicalScore = -rawBm25`,
`score = lexicalScore`, and `embeddingScore = null`.

Application DTOs expose only safe file/artifact/source/chunk identities,
content/kind, scores, locators, nearest heading, and safe provenance/display
labels. They never expose absolute paths, storage keys, SQLite rowids, sidecar
paths, raw fallback data, provider DTOs, or internal diagnostics. Query, token,
file, limit, hit-byte, and result-byte bounds are implementation parameters.

## 5. Agent egress permission

Local retrieval does not authorize provider egress. Attachments, Project
membership, prior access, a model request, or a previous-turn approval do not
grant content access.

The visible per-turn approval creates an in-memory `RetrievalEgressGrant`
bound to turn request, Conversation, source User Message, provider profile, and
approved file-id snapshot. The separate Built-in Agent-only
`retrieve_file_content` tool is exposed only for that active grant. The
dispatcher validates the grant even when invoked directly and revalidates
effective current scope immediately before serialization to the provider.
New messages, manual retry, provider change, completion, failure, cancellation,
and process restart invalidate or do not reuse the grant. No grant is
persisted.

The A0 exactly-six study catalog and MCP `mcp.study.v0` exactly-six read-only
surface remain unchanged; MCP retrieval is deferred to MCP v1.

## 6. Explicit deferrals

RAG-1 excludes embeddings, vector databases, hybrid/reranked search, query
rewrite, GraphRAG, Agent memory, Web crawling/RAG, whole-library retrieval,
Question Store or answer-candidate indexing, MCP retrieval, RAG-specific UI,
automatic Question/Answer mutation, persistent privacy policy, and S0/B0
redesign. P7 remains NOT STARTED; RAG-2 and RAG-3 remain DEFERRED.
