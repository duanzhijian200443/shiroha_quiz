# Android Streamable HTTP MCP v1 — Focused Canonical Contract

Status: **Canonical Android Streamable HTTP MCP target contract; Increment H1 (core foundation + 9-tool READ server) implemented without switching default UI entrypoints; H2 (non-USB setup UI + default Android composition) and H3 (STAGE + local Review) remain separate increments.**

This contract defines the formal **Android Streamable HTTP MCP** mainline that supersedes the earlier local Link/Adapter (`SHAD`) route as the primary Android integration direction, while preserving existing Application authorization (`P0`/`P1`/`P3`–`P8`), SQLite **v36**, B0 **v2**, S0 `engine.*`, and MCP v0 (6-tool stdio) invariants.

Historical provenance:
- Two isolated PoCs (`scratch/http-mcp-poc-20261125-2dd184f3/` and `scratch/android-http-261125-c902/`) proved standard Streamable HTTP with unmodified official Codex over HTTPS on physical Android 16 (TB335FC), including background continuation, manual/expiry/Wi-Fi withdrawal, and pre-send `OUTPUT_WITHHELD`.
- Legacy local `SHAD` / independent `Shiroha Link` contracts (`android-device-access-v0.md` and `unified-access-and-content-exchange-v1.md` local Link sections) are marked **FROZEN historical baselines**, not deleted or claimed retired, until replacement milestones complete acceptance.

---

## 1. Architecture and Layer Ownership

```text
External MCP Client (Codex primary; WorkBuddy/Qoder experimental)
    |  HTTPS (TLS 1.3, private RFC 1918 IPv4, Authorization: Bearer shq_...)
    v
Android App (`lib/mcp/android_http_mcp_server.dart`, pinned `mcp_dart: 2.4.0`)
    |-- Profile 3 exact 9 READ tools (H1; STAGE deferred to H3)
    |-- Ephemeral in-memory legacy HTTP sessions (2025-06-18 / 2025-11-25)
    |-- Stateless HTTP dispatch (2026-07-28)
    |-- Pre-send `OUTPUT_WITHHELD` revalidation
    v
Shared Application Owners (P0/P4/P5/P6/P7/P8/P10/P15)
    |-- `ExternalTrustCore`, `ExternalRuntimeAdmission`, `ExternalAuthorizationManagement`
    |-- `LocalHostDispatchCore`, `ExternalCapabilityGateway`, `ExternalReadContextService`
    |-- `AndroidForegroundAccess` (pure-question READ extended durations + opt-in `continueWhileLocked`)
    v
Data / Android Native Foundation (No business SQLite or Grant authority)
    |-- `ExternalCertificateDer` (single X.509 DER builder/inspector; dynamic private IPv4 SAN + SKI/AKI)
    |-- `AndroidAssociationStore` (`maxActiveAssociations = 16`, up to 64 records with tombstones)
    |-- `AndroidHttpTokenCodec` / `AndroidHttpClientCredentials` (domain-separated SHA-256 + constant-time match)
    |-- `DeviceHttpTlsStore.kt` (AndroidKeyStore CA key + AES-256-GCM sealed leaf PKCS#8 under `noBackupFilesDir`)
    |-- `DeviceReadService.kt` (non-exported `connectedDevice` foreground service, `START_NOT_STICKY`, `stopWithTask="true"`)
```

Hard boundaries:
- The Android App remains the sole SQLite and formal-write owner.
- Zero new `pubspec.yaml` dependencies; SQLite stays **v36**; B0 stays **v2**; S0 `engine.*` is untouched; MCP v0 (`study_mcp_server.dart`) remains exactly 6 read-only stdio tools.
- `package:mcp_dart` stays confined to `lib/mcp/**`.
- Construction and normal App startup perform **no** automatic credential hydration, foreground-service launch, or network listener startup.

---

## 2. Hybrid TLS Termination and Honest Security Boundaries

Android Streamable HTTP uses **Hybrid TLS**:

1. **Local Installation Root CA (`AndroidKeyStore`)**:
   - EC P-256 signing key stored under alias `shiroha.external.android.http.v1.ca` (`PURPOSE_SIGN`, `DIGEST_SHA256`).
   - The Root CA private key is **non-exportable** from `AndroidKeyStore`.
   - Hardware backing varies by device (`strongbox`, `tee`, `software`, `hardware_legacy`, `hardware_unknown`); `DeviceHttpTlsStore` queries `KeyInfo` and reports the device's actual security level honestly rather than making a blanket TEE/StrongBox claim.
   - X.509 v3 Root CA (`CA:TRUE, pathlen:0`, critical `keyCertSign`, 20-byte RFC 7093 SHA-256 `SKI`) TBS construction, assembly, and strict structural inspection reuse `ExternalCertificateDer`; no second X.509 certificate framework is created in Kotlin.

2. **Dynamic IP-Bound Server Leaf (Software P-256 + AES-256-GCM At-Rest Protection)**:
   - Software EC P-256 leaf key pair generated in Kotlin; PKCS#8 DER private key is sealed at rest via `DeviceCredentials.seal(..., "http-leaf-key")` (AES-256-GCM backed by `AndroidKeyStore`) under `noBackupFilesDir/shiroha-external-v1/http/` (covered by `@xml/external_backup_rules` and `@xml/external_data_extraction_rules`).
   - Signed exclusively by the `AndroidKeyStore` Root CA key (`SHA256withECDSA`) over `ExternalCertificateDer.buildTbs` output with `CA:FALSE`, critical `digitalSignature`, `EKU=serverAuth`, critical private RFC 1918 IPv4 SAN (`10/8`, `172.16/12`, `192.168/16`), `SKI`, `AKI` matching CA `SKI`, and 90-day validity.
   - At HTTPS listen time, Dart loads an isolated `SecurityContext(withTrustedRoots: false)` (`minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3`, `allowLegacyUnsafeRenegotiation = false`) via `useCertificateChainBytes` / `usePrivateKeyBytes` bound exclusively to the verified private IPv4 address (never `0.0.0.0`, wildcard, cellular, or VPN).
   - **Memory zeroing disclaimer**: local `ByteArray` / `Uint8List` buffers are overwritten on a best-effort basis after handoff, **without claiming complete zeroing** of JVM, Dart GC, or BoringSSL runtime memory copies.

---

## 3. Multi-Client Identity, Bearer Token Custody, and Revocation

1. **Relationship between Token, Profile, Enable, Grant, Scope, and Context**:
   - **Client Profile** (`external_client_profiles`, `adapter='android-http'`, `protocol='streamable-http'`): durable non-secret identity in SQLite v36.
   - **Bearer Token**: 256-bit CSPRNG credential formatted as `shq_<43 unpadded base64url>` (47 ASCII chars), shown once at issuance (`AndroidIssuedClientToken.toString()` is always `REDACTED`).
   - **Protected Association**: `AndroidAssociationStore.forHttp` (`maxActiveAssociations = 16`, `maxRecords = 64` including monotonic revocation tombstones; legacy single-client callers retain default `maxActiveAssociations = 1`) stores only the domain-separated lowercase hex digest `SHA-256("shiroha-http-bearer-v1:" || token)` via `StreamingSha256`. Plaintext tokens never enter SQLite, backups, logs, or association storage.
   - **Constant-Time Verification**: `AndroidHttpTokenCodec.constantTimeDigestEquals` compares every active association record's digest without short-circuiting on slot index.
   - **Default Grant**: newly issued HTTP Profiles default strictly to `READ` + `questionContent` only. `studyStatistics` and `fileContent` are off by default; `STAGE` is excluded in H1 and deferred to H3.
   - **Finite Runtime Enable**: temporary local user activation in memory; stopping Enable, expiring, restarting the App, or switching Wi-Fi/IP invalidates active runtime `ExternalSession`s and `contextRef`s **without** revoking durable Bearer Tokens or SQLite Profiles. Re-enabling admits the same Tokens cleanly.

2. **Isolated Single-Client Revocation, Fail-Closed Error Policy, and Re-Issuance**:
   - Revoking Profile A immediately revokes only A's `ExternalPrincipal`, drops only A's HTTP sessions and READ `contextRef`s, commits A's tombstone in `AndroidAssociationStore`, and revokes A's SQLite Profile—sibling Clients B/C remain uninterrupted.
   - **Fail-Closed Durable Revoke Failure**: if durable revocation (`AndroidAssociationStore.revoke` or `ExternalAuthorizationManagement.revokeProfile`) fails, the server **immediately withdraws the entire active Enable window** before propagating the error, rather than introducing a complex cross-store recovery framework.
   - **Token Re-Issuance**: strictly defined as "revoke old Profile preserving tombstone + create a new Profile & mint a new Token"; no silent in-place credential overwrite.

---

## 4. MCP Protocol, Tool Surface, and Ephemeral Sessions

1. **Tool Surface (H1)**:
   - Exposes **Profile 3's exact 9 READ tools** (`VnextMcpServer(readOnlyToolsOnly: true)`):
     `open_context`, `list_question_banks`, `get_study_overview`, `get_due_review_summary`, `get_weak_questions`, `search_questions`, `get_question_detail`, `retrieve_file_content`, `get_file_passage`.
   - `propose_generated_questions` and `get_question_proposal` are omitted from `tools/list` and refused by the HTTP port until H3.
   - `studyStatistics` and `fileContent` remain independently gated by Application Grants; unauthorized calls fail closed with safe Profile 3 envelopes (`{profileVersion: 3, data: null, error: ..., source: {kind: "android", deviceRef}}`).

2. **Protocol Compatibility and Bounded Ephemeral Sessions**:
   - Supports both **stateless `2026-07-28`** (`sessionIdGenerator: () => null`) and **legacy `2025-06-18` / `2025-11-25`** (`mcp-session-id`) simultaneously via pinned `mcp_dart: 2.4.0`.
   - Legacy `mcp-session-id` entries exist **strictly as bounded in-memory protocol state**:
     - Global cap: **8** active sessions; per-Profile cap: **4** (`429 Too Many Requests` when exceeded).
     - Idle expiration: **15 minutes** (lazily swept on requests and periodically every 30s; expired or post-restart session IDs return `404 Not Found`).
     - Cross-Profile session hijacking returns `403 Forbidden` before tool execution.
     - Explicit `DELETE /mcp` removes the session cleanly.
     - **No persistent leases, no `LinkStateStore`, and no `DIRTY` state.**
   - Valid Application `contextRef` / `questionRef` handles survive across stateless HTTP requests and legacy session refreshes within the same `(Profile, enableEpoch)` and are invalidated on Profile revocation, Enable withdrawal, expiry, restart, or B0 restore.

3. **HTTP Framing & Pre-Send Release Gate**:
   - Endpoint path strictly `/mcp` (other paths `404`); foreign `Origin` headers rejected `403`; `GET /mcp` returns `405` (`Allow: POST, DELETE`); body cap **64 KiB** (`413`) with 4-second read timeout.
   - Before every tool result leaves the HTTP port, admission is revalidated; if Enable was withdrawn, expired, or the Profile was revoked while the query ran, the result is discarded, `OUTPUT_WITHHELD` is emitted, and only safe `unavailable` is returned.

---

## 5. Foreground Service, Extended Durations, and Lock-Screen Continuation

- `DeviceReadService` is declared in `android/app/src/main/AndroidManifest.xml` as a **non-exported** (`android:exported="false"`) `connectedDevice` foreground service with `START_NOT_STICKY` and `android:stopWithTask="true"`.
- Extended durations (`5m`, `15m`, `30m`, `1h`, `2h`, `4h`, `8h`, `untilAppStops`) and optional per-Enable lock-screen continuation (`continueWhileLocked`) are eligible **only** when `androidBackgroundQuestionRead(policy)` holds (pure `READ` + `questionContent` + bank scopes; never widens `STAGE`, `fileContent`, or `studyStatistics`).
- Under `continueWhileLocked: true`:
  - Clients already authenticated while the device was unlocked during the current Enable window (`allowsAuthenticatedUse == true`) may continue READ calls after screen lock.
  - Brand-new clients attempting first authentication while locked (`acceptsNew == false`) are refused (`403 Forbidden`).
  - Losing the foreground-service notification (`backgroundRead == false`) or switching networks withdraws the Enable window immediately.

---

## 6. Client Compatibility Matrix and Configuration Policy

| Client | Round-1 Status | Evidence / Configuration Notes |
|---|---|---|
| **Codex** (`codex-cli` / App Server) | **Supported (Primary)** | Verified end-to-end over HTTPS with `CODEX_CA_CERTIFICATE` and `bearer_token_env_var` on Windows & Android 16 PoCs (`2025-06-18`). |
| **WorkBuddy** | **Experimental / Partial** | Bundled CLI engine verified over local HTTP (`2025-11-25`, ToolSearch/DeferExecuteTool); desktop settings UI & custom CA trust still unverified. |
| **Qoder** | **Experimental / Handshake-Only** | Bundled worker verified `initialize`/`initialized`/`ping` (`2025-11-25`); `tools/list`, `tools/call`, login-state runtime, and custom CA trust still unverified. |

Configuration policy (H2):
- User delivery of CA certificate + Bearer Token + URL snippet must work **without USB** (LAN QR/copy/export), while normal ADB development and log observation remain permitted during development/verification.
- **Tailscale** is explicitly **deferred** (not a baseline dependency).
- **`NO_PROXY`** is documented as **on-demand** when a local HTTP proxy intercepts private RFC 1918 LAN addresses.

---

## 7. Phased Rollout (H1 → H2 → H3)

| Increment | Scope | Activation / Status |
|---|---|---|
| **H1 (Current)** | Canonical contract & legacy `FROZEN` markers; `ExternalCertificateDer` IPv4 SAN/SKI/AKI; `DeviceReadService` + `DeviceHttpTlsStore`; `AndroidAssociationStore.forHttp` + `AndroidHttpTokenCodec` / `AndroidHttpClientCredentials`; `AndroidForegroundAccess` extended durations & `continueWhileLocked`; `AndroidHttpMcpServer` (Profile 3 exact 9 READ tools). | Core implemented & tested offline; default `lib/main.dart` / `MainActivity.kt` UI entrypoints **unchanged**. |
| **H2** | First-party Android HTTP setup/control UI (non-USB CA & Token delivery, client list/revoke/reissue, Enable toggle), default Android composition switch, and physical-device Codex HTTPS verification. | Planned (separate PR). |
| **H3** | Enable Profile 3 STAGE (`propose_generated_questions` + `get_question_proposal`) over Android HTTP with existing first-party local Review / saved generation policy and original-key reconciliation. | Planned (separate PR). |
