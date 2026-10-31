# Android fixed-device library adapter

The [approved capability contract](../../docs/product/agent-refactor/android-device-access-v0.md)
owns the target and the narrower delivery in section 12. Only the explicitly
selected `.androidread` Debug installation and dedicated desktop record are
admitted. Missing/unsupported arguments exit 78 before credential or network
access. `--self-test` uses memory fixtures; `--native-proof` validates the same
Native primitives without activating business.

The desktop source contains bounded framing, pinned TLS 1.3, strict handshake
validation, two original stdio pumps and dedicated current-user DPAPI storage.
It does not reference a Shiroha database or implement tool business behavior.
Ordinary Android artifacts reject protected acquisition. The admitted App uses
original P15/P0, association CAS, finite Enable and current authorization. Its
seven schemas are unchanged. The phone dispatches question READ plus
`propose_generated_questions` and `get_question_proposal` under its current
authorization. File modes additionally require explicit local fileContent and
the original File scope; they use the same phone F1/retrieval owners.
The historical `.androidread` package and `android_device_read` directory names
are retained; do not reinstall, re-pair or migrate credentials to rename them.

## Independent Link candidate

[`tool/link`](../link/README.md) compiles the original adapter with a standalone
Dart AOT connection owner. Fixed `--link-proof`/`--link-business` entries require
the adjacent Link's native desktop-parent/creation admission, strict installation
configuration and claimed-slot fence before protected record/key acquisition.
They request the explicit Profile 3 target composition; original direct entries
still default to Profile 2. Device/installation/Profile are checked against the
claim before CNG import and again through the authenticated TLS/READY channel.
Neither tool arguments nor environment variables supply pairing credentials.

Updated legacy acquisition checks every handoff fence phase and refuses released
slots. `--handoff-binding` is restricted to the original App/Explorer parent
chain and returns only the original protected record's non-secret binding to
that App. It does not release database ownership or provide a model API.
The original adapter emits a bounded resource receipt only after real close,
TLS shutdown and original key retirement; Link must still join process/streams.
This is candidate infrastructure, not a completed native/phone/normal-client
qualification. The legacy focused workflow below retains its prior limits.

## Selected development workflow

Publish a self-contained executable for the selected Windows host:

```powershell
dotnet publish tool/android_device_adapter/AndroidDeviceAdapter.csproj --configuration Release --runtime win-x64 --self-contained true -p:RuntimeFrameworkVersion=10.0.7 -p:PublishSingleFile=true -p:PublishTrimmed=false --output build/android_device_read/adapter
```

Runtime pack downloads require their own network scope. This does not install
trust roots or migrate Windows Shiroha credentials. The bounded native validation
below initially provisions this task's dedicated `device.dpapi`; after successful
pairing its protected record binds the actual installation/Profile/revision.
The native probe refuses that paired record instead of overwriting it.

1. On the phone, open External Agent settings and the first pairing window.
   Run `AndroidDeviceAdapter --pair <repository>/build/android_device_read <selected-private-ipv4> --current-user-cng-import`.
   Compare the complete actual client fingerprint on both local displays and
   confirm on the phone. Pairing settles and leaves access OFF.
2. For each daily access period, explicitly enable access on the phone.
   Wait for PREPARING / the desktop-helper prompt, then run
   `AndroidDeviceAdapter --enable-proof <repository>/build/android_device_read --current-user-cng-import`.
   The original P15/P0 proof and both original connection owners settle before
   the phone reports enabled. Early business attempts refuse without occupying
   the later proof; proof without this preparation cannot enable access.
3. Only now start/restart the normal Codex MCP server using the published
   executable, with arguments `--business <repository>/build/android_device_read --current-user-cng-import`.
   Keep the server name `shiroha_vnext` and its seven existing definitions.
   The adapter performs fresh pinned TLS/HELLO/current access/READY before MCP.
   Phone keys remain in Android Keystore; this executable never opens a question DB.

All three commands require the same selected record and explicit CNG runtime
scope. The default does not silently import a persisted key. The phone grants a
30-minute access period from the local action, never from helper completion or
reconnect. Content can reach the normal Codex model service, as the phone states.

For Codex desktop **26.1023.51421 (22530)** with CLI **0.165.0-alpha.1.2**, the
demonstrated recovery action is **complete desktop exit/reopen, then return to
the same task**. Its global settings list omitted the project-local MCP entry;
the actual adapter process and normal tool calls confirmed loading. Do not treat
that list or cached tools as connection evidence. Automatic recovery is not
claimed. Following focus-only loss, return the phone to the foreground, retain
the same remaining period, reopen Codex and create/read a fresh Context. After
background, lock, network change, expiry or switch-off, repeat step 2 first.
The adapter never restarts itself, polls for Enable or replays tool input.
Project-sourced entries can also appear in the MCP list with disabled editing
controls: the inspected client marks project origins read-only, while the
enabled value remains the one in `.codex/config.toml`. Its Restart button appears
only after a settings-page MCP mutation; it is not a standing per-connection
reconnect control. An absent button or grey enabled switch does not imply that
the phone's saved Grant was revoked. Recovery still requires the demonstrated
client action and a successful real query.

The exercised set is the dedicated HONOR 70 / Android 14 API 34 installation,
real Wi-Fi, and Windows 11 / self-contained .NET 10.0.7. Native signing/TLS,
pairing, daily Enable, normal-model question READ and manual post-focus READ
recovery have separate evidence. Normal-Codex pending publication/original-key
reopen, local approval with typed READ, rejection/direct terminal queries and
local practice with external access off have now been exercised. The selected
new direct batch's original successful response was withheld in full, its owner
settled cleanly, and a later normal-Codex query recovered committedCount 1 by the
original key after fresh Enable. Local bank content/counts and a learning record
surviving normal phone reopen provide separate phone evidence. New file evidence
adds normal-Codex selection, current TXT retrieval/continuation and two uncited
questions with original-key committed counts and matching phone/READ content.
The finite seven-tool loop is exercised on this installation; full Android v0
and other devices/artifacts remain outside this delivery.

For the exercised interactive CLI, keep the client alive until phone access is
off and the original adapter has exited with its temporary-key marker removed,
then exit Codex. The bundled CLI used `--no-daemon` because its interactive daemon
packaging was unavailable. A `codex exec` auto-exit left an unsettled temporary
import during acceptance; a later proof refused as designed. Unknown cleanup
requires separately authorized exact-key recovery, never marker deletion alone,
re-pairing or replacing the persistent record. Automatic/abrupt-exit cleanup is
not claimed. This changes no transport or credential protocol.

## Phone generation policy and original-key recovery

For file reading, enable `允许读取资料正文` only after checking its scope on the
phone. This preserves the current generation mode, permissions and scopes;
all-content covers this installation's current and future File Library files.
An exact policy without File scopes cannot be widened by this switch. Policy
changes close and settle old access; repeat the original Enable/proof flow.
An existing same-scope file grant needs no new consent. Upgrade, settings open
and ordinary reconnect never add file permission.

In normal Codex, list targets/create a parent Context, then use
one tool call at a time, waiting for its response. Use
`open_generation_context(contextRef, pageSize?, cursor?)` to list file choices.
Continue even an empty page when nextCursor is present. Select returned fileRefs
into a separate File Context; selectionOrdinal is page-local, not file identity.
Use `retrieve_file_content` for lexical hits and `get_file_passage` with the
returned passageRef/cursor for continuous reading. Compare the approved sample
in the phone's File Library view; do not add names/IDs/paths to the response.
Report hasMore, startsAtDocumentBeginning and unsupportedExcluded accurately.
Partial hits/pages do not mean the whole document was read. Current verified
ParsedArtifact is the only source; no OCR, parser or Provider is triggered.
Existing derived-index construction may write cache, so this is not zero writes.
Generate only from actual returned content. PassageRefs are not evidenceKeys;
without existing recognized GeneratedEvidence, retain explicit uncited items.
Then use the unchanged STAGE/original submissionKey query and local review/direct
policy below. Do not replay an uncertain submission or redo prior loss experiments.
The unchanged Submission v1 item and uncited format is defined in
[the generation contract](../../docs/product/agent-refactor/generated-question-proposals.md#candidate-submission)
and summarized by the Android server instructions. `evidenceKeys: []` expresses
uncited; there is no extra `uncited` field.

Old READ grants stay READ until the phone user explicitly enables generation and
Proposal queries. The first generation choice is review; the independent direct
switch applies only to later new batches. Each policy change closes old access,
preserves the current target scope, and uses original Grant revision CAS. Complete
the original Enable/proof sequence again after saving. Leaving settings does not
block saved review/direct; legacy confirm still needs its bounded local view.

Keep each submissionKey. A publication acknowledgement is not final-save status;
query `get_question_proposal` to obtain pending_review, committed or rejected and
safe counts. After response loss, reconnect the same device/Profile and query the
original key without repeating STAGE. Normal restart queries and a proven
commit-without-response experiment are distinct evidence. Existing drafts never
commit from toggling direct or reconnecting. Use the phone's existing draft inbox
for local Review and its existing practice entry after access is off.

## Controlled response loss and offline verification

The optional `controlled_response_loss.py` is an explicit local validation
wrapper, never a phone feature or model tool argument. It launches only the
selected existing business adapter/record. An operator supplies one test
submissionKey outside MCP; after receiving that key's successful original
STAGED/NOT_REPORTED response, the wrapper withholds the entire response from
Codex, closes the child's stdin normally and waits for that original adapter.
It never kills an owner, retries a write, reads a database or logs content/keys.
Fixed safe observations are appended under `build/android_generation_validation`.
The observation proves publication-response withholding, not final lifecycle;
only a subsequent same-Profile original-key query establishes saved status.
An adapter close failure/pending settlement is retained as such.

For an authorized task connection only, temporarily configure the same
`shiroha_vnext` project MCP entry to run Python with:

```text
tool/android_device_adapter/controlled_response_loss.py --run-selected-android-validation --submission-key <selected-new-test-key> --evidence-name <task-label>
```

After the controlled loss, use the demonstrated explicit client restart and
query the original key. Restore the entry's original business-adapter command
after the experiment. Never use this wrapper for ordinary users or treat a
timeout/disconnect without a matched withheld acknowledgement as loss evidence.
Its subprocess/selector regression opens no credential or network:

```powershell
python -m unittest discover -s tool/android_device_adapter -p test_controlled_response_loss.py -v
```

```powershell
dotnet build tool/android_device_adapter/AndroidDeviceAdapter.csproj --configuration Debug
dotnet run --project tool/android_device_adapter/AndroidDeviceAdapter.csproj --no-build -- --self-test
flutter test --concurrency=1 test/application/external/android_foreground_access_test.dart test/data/external/android_association_store_test.dart test/data/external/android_native_backend_test.dart
```

`Check-Offline.ps1` additionally compiles all Native source against a real Android
platform jar and Flutter embedding jar, then runs the pure JVM framing/gate
fixture and the Debug Activity's original close owner, including late endpoint
acquisition and sticky settlement failure. Pass the existing Java executable,
Kotlin 2.2.20 compiler dependency classpath, Kotlin stdlib, Android jar and
Flutter embedding jar explicitly. It writes classes only under
`build/android_device_foundation/`; it installs no
dependency, starts no App/emulator, opens no socket and reads no credential.
An App Gradle compile is a separate packaging check. Kotlin/JVM success is not
Android framework runtime or Keystore/TLS integration proof.

Real credential/network tests require explicit runtime scope; native validation
alone does not authorize a business consumer.

## Bounded native validation

Build the task installation with Gradle `:app:assembleDebug`,
`-PandroidReadValidation=true` and `-Ptarget-platform=android-arm64`. This adds the
`.androidread` package suffix, the gated normal App READ root, and a separate
native validation Activity protected by the shell's DUMP permission. Ordinary
Debug/Release admission stays closed. Install only into a selected device/user; preserve any
pre-existing App and never clear data or replace credentials automatically.

The local command is:

```text
AndroidDeviceAdapter --native-proof <adb-executable> <selected-device-serial> <selected-private-ipv4> <repository>/build/android_device_read
```

It uses one foreground native Activity, the original Android Keystore key and
KeyManager/TLS endpoint, and the original .NET TLS/pin policy. Activity callbacks
withdraw admission immediately and request the original close on an off-main
worker; the proof worker joins it before
publishing clean settlement or allowing replacement. Late endpoints retain the
same owner, and an actual close failure remains terminal. There is no ADB
port forwarding: TLS uses the selected LAN address. The default first invocation
requests Missing-only native initialization. `--existing-native-identity`
explicitly reuses this task's retained identity without key creation or repair.
An incompatible retained key fails closed and requires separately approved
recovery. In particular, TLS requires Keystore authorization for the provider's
precomputed digest (`DIGEST_NONE`) as well as SHA-256 leaf self-signing.

The client key is software-generated and any saved proof-only object is protected
by current-user DPAPI at the selected task directory's `device.dpapi`; that object
cannot authorize business. Public local bootstrap records are scoped to the
original operation in the selected installation's private `cache/native-proof-v1`
directory. The helper reads them using ADB shell v2 with the actual remote exit
status; an absent/error response is never parsed as success evidence. It prints
only safe categories, stages and counts, never certificates, private keys or
bootstrap records. The independent Android Keystore keys and encrypted
installation object stay in their original native owners.

`--current-user-cng-import` is a separate, explicit option for
Windows Schannel client-key interoperability. It requires authorization for a
new temporary current-user CNG container, managed by the Microsoft Software Key
Storage Provider, in addition to the dedicated DPAPI object. It never enumerates
or opens old Windows Shiroha credentials and does not enroll a certificate into
the system trust store. The owner rejects PFX-supplied key/provider names, retains
its new object through TLS close, deletes the original CNG handle and checks
absence before success. The task directory's `native-client-key.pending` marker
retains a fixed local cleanup record, not key material or business content;
unknown retirement blocks replacement and requires explicit recovery. No
automatic fallback from ephemeral import exists. This option's presence and
compilation do not establish a supported runtime combination.

The positive case requires both endpoint results, non-exportability, actual
KeyManager use, installation continuity and original close. Wrong-server-pin and
wrong-client cases must refuse. A handshake attempt or an offline PASS does not
establish support; all required native, foreground, P15, normal Codex READ and
recovery evidence remains distinct. The native probe supplies no business READ
or STAGE; only the separately enabled normal App consumer supplies question READ.
