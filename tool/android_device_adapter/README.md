# Android device transport foundation

The [approved capability contract](../../docs/product/agent-refactor/android-device-access-v0.md)
owns the target. This is the source-only foundation, not a usable connection or
business release. Normal execution exits 78 before configuration/credentials or
network access. Only `--self-test` runs, using memory fixtures. There is no CLI
flag, environment variable or normal App path enabling runtime admission.

The desktop source contains bounded framing, pinned TLS 1.3, strict handshake
validation, two original stdio pumps and dedicated current-user DPAPI storage.
It does not reference a Shiroha database or implement tool business behavior.
Android counterparts remain unregistered and reject protected acquisition.

Offline verification:

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

Future business/P15 evidence composition and first-pairing UI require the next
authorized task; real credential/network tests require explicit runtime scope.
