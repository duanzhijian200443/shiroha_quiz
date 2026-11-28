# Android Streamable HTTP MCP v1 — Focused Canonical Contract

Status: **Canonical Android Streamable HTTP MCP contract. H3 connects Profile 3 generation and proposal status to the default Android App. H3 physical-device acceptance is tracked separately from source delivery.**

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
    |-- Profile 3 exact 11 tools (READ, STAGE and proposal lifecycle)
    |-- Ephemeral in-memory legacy HTTP sessions (2025-06-18 / 2025-11-25)
    |-- Stateless HTTP dispatch (2026-07-28)
    |-- Pre-send `OUTPUT_WITHHELD` revalidation
    v
Shared Application Owners (P0/P4/P5/P6/P7/P8/P10/P15)
    |-- `ExternalTrustCore`, `ExternalRuntimeAdmission`, `ExternalAuthorizationManagement`
    |-- `LocalHostDispatchCore`, `ExternalCapabilityGateway`, `ExternalReadContextService`
    |-- `FirstPartyStageApproval`, `ExternalGeneratedStageService`, existing local Review
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
- The regular Android build uses the HTTP composition on Android 10 (API 29) and above. The explicit legacy Android READ Debug build retains its own native admission. HTTP uses its own protected association file and the regular App's existing Profile, Grant, P0 and READ owners.

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
   - Native reserves the replacement key in memory. It verifies that the signed certificate matches the prepared key, installation CA, IP and expiry, then atomically publishes the certificate, sealed key and metadata together. An interrupted preparation preserves the previously published leaf. Valid older split files remain readable when the bundle is absent, with the same key and certificate checks. A corrupt bundle fails closed.
   - Dart rounds the generation time down to a UTC second before building the certificate. Native expiry metadata uses that same timestamp. An address change issues a new leaf under the same installation CA.
   - At HTTPS listen time, Dart wraps Native PKCS#8 DER in PEM for its key loader and loads an isolated `SecurityContext(withTrustedRoots: false)` (`minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3`, `allowLegacyUnsafeRenegotiation = false`) via `useCertificateChainBytes` / `usePrivateKeyBytes` bound exclusively to the verified private IPv4 address (never `0.0.0.0`, wildcard, cellular, or VPN).
   - **Memory zeroing disclaimer**: local `ByteArray` / `Uint8List` buffers are overwritten on a best-effort basis after handoff, **without claiming complete zeroing** of JVM, Dart GC, or BoringSSL runtime memory copies.

---

## 3. Multi-Client Identity, Bearer Token Custody, and Revocation

1. **Relationship between Token, Profile, Enable, Grant, Scope, and Context**:
   - **Client Profile** (`external_client_profiles`, `adapter='android-http'`, `protocol='streamable-http'`): durable non-secret identity in SQLite v36.
   - **Bearer Token**: 256-bit CSPRNG credential formatted as `shq_<43 unpadded base64url>` (47 ASCII chars), shown once at issuance (`AndroidIssuedClientToken.toString()` is always `REDACTED`).
   - **Protected Association**: `AndroidAssociationStore.forHttp` (`maxActiveAssociations = 16`, `maxRecords = 64` including monotonic revocation tombstones) stores the domain-separated lowercase hex digest `SHA-256("shiroha-http-bearer-v1:" || token)` via `StreamingSha256`. Native seals the HTTP association file with a separate purpose from the legacy association file. Plaintext tokens never enter SQLite, backups, logs, or association storage.
   - **Constant-Time Verification**: `AndroidHttpTokenCodec.constantTimeDigestEquals` compares every active association record's digest without short-circuiting on slot index.
   - **Default Grant**: newly issued HTTP Profiles default strictly to `READ` + `questionContent`. `studyStatistics`, `fileContent`, `STAGE` and `proposalMetadata` require local authorization.
   - **Generation Grant**: enabling generation adds `STAGE` and `proposalMetadata` to that Profile's revisioned Grant. The user selects one or more banks or explicitly selects all content. The first enablement defaults to `review`, which publishes pending drafts. A separate explicit choice saves `direct` for new batches under the [shared saved-policy contract](external-agent-boundary.md#14-simplified-first-party-access-and-v35-saved-generation-policy).
   - **Runtime Enable**: explicit local user activation in memory. P0 binds each enabled Principal to the original Android lifecycle window before admitting Sessions. Withdrawal invalidates preparations synchronously. Stopping Enable, expiring, restarting the App, or switching Wi-Fi/IP invalidates active runtime `ExternalSession`s and `contextRef`s **without** revoking durable Bearer Tokens or SQLite Profiles. Re-enabling admits the same Tokens cleanly.

2. **Issuance, Isolated Revocation and Re-Issuance**
   - Issuance reserves a protected-store slot and checks P0 capacity before creating the SQLite Profile and Grant. Previously recorded digests, including those in tombstones, are ineligible for new issuance. Issuance completes P0 pairing after committing the association and delivers the Token only after both owners acknowledge the same Profile. A failed issuance withdraws the unpublished Profile and reconciles only its exact association. If creation was acknowledged by SQLite but the owning composition was withdrawn before the reference was returned, or if cleanup is uncertain, the first-party caller receives the original Profile ID for recovery.
   - Portable B0 restore scrubs SQLite Profiles while the installation's protected associations remain. Enable skips confirmed missing Profiles. Issuance retires those associations under current first-party management and the B0 mutation lease, freeing their active slots while preserving each digest and the durable record limit. A failed lookup fails closed. Raw rollback keeps associations for Profiles present in the authoritative SQLite database.
   - Revoking Profile A immediately revokes A's P0 Principal and drops its HTTP sessions and READ references. Once the association and SQLite Profile revocations settle, A's P0 slot is available for reuse and its existing sessions remain revoked. Enable preparation skips a Profile withdrawn during its registration or binding and can still enable other current Profiles. In-flight Bearer authentication revalidates the exact matched association across the Profile lookup, so a successful sibling commit leaves it current. An observed store failure invalidates all snapshots.
   - **Fail-Closed Durable Revoke Failure**: if durable revocation (`AndroidAssociationStore.revoke` or `ExternalAuthorizationManagement.revokeProfile`) fails, the server **immediately withdraws the entire active Enable window** before propagating the error, rather than introducing a complex cross-store recovery framework.
   - **Token Re-Issuance** first checks capacity for the replacement. It can reuse the old Profile's active slot and requires space for one additional durable record. Once capacity is confirmed, it revokes the old Profile, preserves its tombstone, and creates a new Profile and Token. Without an explicit replacement policy, re-issuance requires an active Grant and uses its exact revision for the old Profile's revocation. A missing, revoked, or changed Grant rejects implicit re-issuance.

---

## 4. MCP Protocol, Tool Surface, and Ephemeral Sessions

1. **Tool Surface**:
   - Exposes **Profile 3's exact 11 tools**. The original nine READ tools are
     `open_context`, `list_question_banks`, `get_study_overview`, `get_due_review_summary`, `get_weak_questions`, `search_questions`, `get_question_detail`, `retrieve_file_content`, `get_file_passage`.
   - `propose_generated_questions` consumes Submission v1 under the current saved generation policy for the App-resolved bank. It returns the existing `STAGED` / `NOT_REPORTED` acknowledgement. The HTTP request retains first-party approval until the original business operation and response stream have settled. The App keeps existing references for the same Profile and Enable window across individual POSTs.
   - `get_question_proposal` queries lifecycle and counts by the original `submissionKey`. It requires current READ, proposal metadata consent and both original and current target scope for the authenticated Profile. After a lost response, the client queries by the original key without replaying the write. The existing [Proposal contract](generated-question-proposals.md#12-external-proposal-lifecycle-metadata-query) governs lookup, publication, review and formal writes.
   - `studyStatistics` and `fileContent` remain independently gated by Application Grants; unauthorized calls fail closed with safe Profile 3 envelopes (`{profileVersion: 3, data: null, error: ..., source: {kind: "android", deviceRef}}`).

2. **Protocol Compatibility and Bounded Ephemeral Sessions**:
   - Supports both **stateless `2026-07-28`** (`sessionIdGenerator: () => null`) and **legacy `2025-06-18` / `2025-11-25`** (`mcp-session-id`) simultaneously via pinned `mcp_dart: 2.4.0`.
   - Legacy `mcp-session-id` entries exist **strictly as bounded in-memory protocol state**:
     - Global cap is **8** and per-Profile cap is **4**, counting active sessions and in-flight initialization reservations. Excess initialization returns HTTP 429. Failure, close and Profile revocation release the applicable reservations.
     - Idle expiration: **15 minutes** (lazily swept on requests and periodically every 30s; expired or post-restart session IDs return `404 Not Found`).
     - Cross-Profile session hijacking returns `403 Forbidden` before tool execution.
     - The server removes a session when the SDK closes its transport after accepting DELETE. A rejected DELETE preserves the current session.
     - **No persistent leases, no `LinkStateStore`, and no `DIRTY` state.**
   - Valid Application `contextRef` / `questionRef` handles survive across stateless HTTP requests and legacy session refreshes within the same `(Profile, enableEpoch)` and are invalidated on Profile revocation, Enable withdrawal, expiry, restart, or B0 restore.

3. **HTTP Framing & Pre-Send Release Gate**:
   - Endpoint path strictly `/mcp` (other paths `404`), with foreign `Origin` headers rejected `403`. `GET /mcp` returns `405` (`Allow: POST, DELETE`). The ordinary body cap is **64 KiB** (`413`) with the existing 4-second read timeout. An eligible foreground STAGE Profile can submit a single proposal call up to **1 MiB + 64 KiB** for submission and JSON-RPC framing. Up to four expanded bodies may be admitted concurrently. The shared Profile 3 decoder enforces its original submission and content limits.
   - Before releasing a tool result, the HTTP port revalidates the current Enable, Session, Grant revision and window eligibility. Withdrawal, expiry, Profile revocation or a Grant change withholds the result, emits OUTPUT_WITHHELD, and returns the safe unavailable envelope.

---

## 5. Foreground Service, Extended Durations, and Lock-Screen Continuation

- `DeviceReadService` is declared in `android/app/src/main/AndroidManifest.xml` as a **non-exported** (`android:exported="false"`) `connectedDevice` foreground service with `START_NOT_STICKY` and `android:stopWithTask="true"`.
- Foreground-only mode offers 5, 15 and 30 minutes. The App waits for the original background service's promotion, visible notification and activation before admitting clients and displaying the current URL. HTTP admission and pre-send release refresh trusted Android observations.
- Leaving the authorization panel cancels a pending Enable, including its initial Android status read. After the endpoint is ready, navigation leaves the current Enable window active under its selected lifecycle policy.
- The opted-in background window admits only Profiles whose current Grant is pure question READ (READ + questionContent + bank scopes). Application checks that policy at admission and final release, including while the App is visible in that window. File, statistics and STAGE Grants use the foreground-only finite window within its P0 ceiling.
- Pure-question READ can choose 5m, 15m, 30m, 1h, 2h, 4h, 8h or untilAppStops. P0, HTTP admission, and the foreground-service lifetime use the same original Android window. A finite window uses its monotonic deadline. UntilAppStops has no synthetic time ceiling and ends with the original owner, explicit withdrawal or loss of the required observation.
- Under `continueWhileLocked: true`:
  - The HTTP server accepts a locked continuation only for the same Application Session recorded while unlocked in the current Enable window.
  - Brand-new clients attempting first authentication while locked (`acceptsNew == false`) are refused (`403 Forbidden`).
  - Losing the foreground-service notification or switching networks withdraws the Enable window immediately. Native serializes foreground-service start, stop and Activity disposal under the original channel owner, keeping custody of an already accepted start through its stop result.

---

## 6. Client Compatibility Matrix and Configuration Policy

| Client | Round-1 Status | Evidence / Configuration Notes |
|---|---|---|
| **Codex** (`codex-cli` / App Server) | **Supported (Primary)** | Verified end-to-end over HTTPS with `CODEX_CA_CERTIFICATE` and `bearer_token_env_var` on Windows & Android 16 PoCs (`2025-06-18`). |
| **WorkBuddy** | **Experimental / Partial** | Bundled CLI engine verified over local HTTP (`2025-11-25`, ToolSearch/DeferExecuteTool); desktop settings UI & custom CA trust still unverified. |
| **Qoder** | **Experimental / Handshake-Only** | Bundled worker verified `initialize`/`initialized`/`ping` (`2025-11-25`); `tools/list`, `tools/call`, login-state runtime, and custom CA trust still unverified. |

### Configure Codex on the same private Wi-Fi

1. Open **外部 Agent 授权** in the Android App. Add a client and transfer its one-time Token to the computer through a private channel. The client starts with question READ. Change its Grant and exact bank or file scopes in **授权范围**.
2. Export the public root CA PEM from the same panel and transfer it to the computer. The panel shows its SHA-256 fingerprint. Enable access in the App and copy the current `https://<private-ip>:17443/mcp` URL.
3. Copy the Codex template into `~/.codex/config.toml`. Set `CODEX_CA_CERTIFICATE` to the PEM path and `SHIROHA_ANDROID_MCP_TOKEN` to the issued Token in the environment that starts Codex. Restart Codex with that environment. Set `NO_PROXY` for the device IP if a local proxy intercepts the LAN request. See [Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp#streamable-http-servers) and [custom CA bundles](https://learn.chatgpt.com/docs/auth#custom-ca-bundles).
4. For background question READ, turn on **后台运行** and allow the app notification. **锁屏后继续读取** keeps only this window's previously authenticated Sessions. After Wi-Fi recovery, explicitly enable access again and update the URL if the IP changed. The client can reuse its Token and CA.
5. For generation, turn on **允许提交生成题目**, select the target banks, and open a foreground access window. Open **审校生成题目** to review and save a draft. **允许直接写入题库** explicitly authorizes direct saving for new batches that pass the existing validation and transaction gates.

ADB is available for installation and logs during development. Tailscale is deferred.

---

## 7. Phased Rollout (H1 → H2 → H3)

| Increment | Scope | Activation / Status |
|---|---|---|
| **H1** | Hybrid TLS, protected multi-client credentials, foreground service and Profile 3's exact nine-tool READ server. | Core implemented and tested offline. |
| **H2** | First-party Android HTTP setup, default composition, and physical-device Codex HTTPS acceptance. | Setup and composition implemented. See delivery evidence for device acceptance. |
| **H3** | Enable Profile 3 STAGE (`propose_generated_questions` + `get_question_proposal`) over Android HTTP with existing first-party local Review / saved generation policy and original-key reconciliation. | Source implemented. Physical-device Codex HTTPS and local Review acceptance remain separately tracked. |
