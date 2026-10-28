# Android fixed-device question READ adapter

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
seven schemas are unchanged, but only `open_generation_context`,
`search_questions` and `get_question_detail` dispatch. STAGE, proposal lookup and
both file tools return `unavailable` before business dispatch.

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
2. For each daily access period, explicitly enable question READ on the phone.
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
30-minute READ period from the local action, never from helper completion or
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

The exercised set is the dedicated HONOR 70 / Android 14 API 34 installation,
real Wi-Fi, and Windows 11 / self-contained .NET 10.0.7. Native signing/TLS,
pairing, daily Enable, normal-model question READ and manual post-focus READ
recovery have separate evidence. Android v0 generation/file/write-loss recovery
and other devices/artifacts remain outside this delivery.

## Offline verification

```powershell
dotnet build tool/android_device_adapter/AndroidDeviceAdapter.csproj --configuration Debug
dotnet run --project tool/android_device_adapter/AndroidDeviceAdapter.csproj --no-build -- --self-test
flutter test --concurrency=1 test/application/external/android_foreground_access_test.dart test/data/external/android_association_store_test.dart test/data/external/android_native_backend_test.dart
```

`Check-Offline.ps1` additionally compiles all Native source against a real Android
platform jar and Flutter embedding jar, then runs only the pure JVM framing/gate
fixture. Pass the existing Java executable, Kotlin 2.2.20 compiler dependency
classpath, Kotlin stdlib, Android jar and Flutter embedding jar explicitly. It
writes classes only under `build/android_device_foundation/`; it installs no
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
KeyManager/TLS endpoint, and the original .NET TLS/pin policy. There is no ADB
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
