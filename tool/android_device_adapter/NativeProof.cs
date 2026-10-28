using System.Diagnostics;
using System.ComponentModel;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Authentication;
using System.Text.Json;
using System.Text;

namespace Shiroha.AndroidDevice;

/// <summary>Bounded local validation, using the production key/TLS primitives.
/// No business stream, P15 evidence, SQLite, model calls or reconnect loop.</summary>
internal sealed class NativeProof(string adb, string serial, IPAddress address, string directory,
    bool existingNativeIdentity, bool useCurrentUserCng)
{
    private const string Package = "com.example.shiroha_quiz.androidread";
    private readonly Stopwatch elapsed = Stopwatch.StartNew();
    private bool ended;
    private string stage = "configuration";
    private void RequireAdmission()
    {
        if (ended || elapsed.Elapsed >= TimeSpan.FromMinutes(2) || !OperatingSystem.IsWindows() ||
            !DeviceTarget.PrivateV4(address)) throw new LinkFailure("runtime_not_authorized");
    }

    internal static async Task<int> Run(string adb, string serial, string host, string directory,
        bool existingNativeIdentity = false, bool useCurrentUserCng = false)
    {
        NativeProof? proof = null;
        try
        {
            if (!IPAddress.TryParse(host, out var address) || !DeviceTarget.PrivateV4(address) ||
                string.IsNullOrWhiteSpace(serial)) throw new LinkFailure("invalid_target");
            DirectoryInfo? root = new(AppContext.BaseDirectory);
            while (root != null && !File.Exists(Path.Combine(root.FullName, "pubspec.yaml"))) root = root.Parent;
            if (root == null || !string.Equals(Path.GetFullPath(directory),
                    Path.Combine(root.FullName, "build", "android_device_read"), StringComparison.OrdinalIgnoreCase))
                throw new LinkFailure("invalid_target");
            proof = new NativeProof(Path.GetFullPath(adb), serial, address, Path.GetFullPath(directory), existingNativeIdentity, useCurrentUserCng);
            try { await proof.Execute(); }
            finally { proof.ended = true; }
            return 0;
        }
        catch (LinkFailure error) { Console.Error.WriteLine($"native_proof:{proof?.stage ?? "configuration"}:{error.Code}"); return 78; }
        catch (Exception error)
        {
            Console.Error.WriteLine(JsonSerializer.Serialize(new { nativeProof = "failed", stage = proof?.stage ?? "configuration",
                category = Category(error), code = error.HResult }));
            return 78;
        }
    }

    private async Task Execute()
    {
        RequireAdmission();
        stage = "device_state";
        var state = await Adb("get-state");
        if (state.Exit != 0 || state.Text.Trim() != "device") throw new LinkFailure("device_unavailable");
        bool existing = File.Exists(Path.Combine(directory, "device.dpapi"));
        byte[] key;
        string? expectedDevice = null, expectedPin = null, expectedInstallation = null;
        if (existing)
        {
            byte[] clear = ProtectedDeviceStore.Read(directory, RequireAdmission);
            try
            {
                using var stored = LinkFrames.StrictObject(clear);
                var record = stored.RootElement;
                if (record.GetProperty("purpose").GetString() != "native-proof-only")
                    throw new LinkFailure("credential_store_corrupt");
                key = Convert.FromBase64String(record.GetProperty("clientPfx").GetString()!);
                expectedDevice = record.GetProperty("deviceId").GetString();
                expectedPin = record.GetProperty("certificateDigest").GetString();
                expectedInstallation = record.GetProperty("installationId").GetString();
            }
            finally { CryptographicOperations.ZeroMemory(clear); }
        }
        else { stage = "client_identity"; key = ProtectedDeviceStore.CreateClientIdentity(RequireAdmission); }

        try
        {
            Identity positive;
            string pin;
            using (var clientOwner = LoadClient(key))
            {
                var client = clientOwner.Certificate;
                pin = Convert.ToHexStringLower(SHA256.HashData(client.RawData));
                positive = await One("correct", client, pin, !existing && !existingNativeIdentity, false,
                    expectedDevice, expectedPin, expectedInstallation);
                await One("wrong-server-pin", client, pin, false, true,
                    positive.DeviceId, positive.Pin, positive.Installation);
                using (var signing = client.GetECDsaPrivateKey() ?? throw new LinkFailure("credential_rejected"))
                using (var wrongClient = ProtectedDeviceStore.CreateClientLeaf(signing, true))
                {
                    // A different, correctly signed leaf is a different credential
                    // even when it uses the SAME one owned signing container.
                    await One("wrong-client", wrongClient, pin, false, false,
                        positive.DeviceId, positive.Pin, positive.Installation);
                }
                await One("cancel-before-accept", client, pin, false, false,
                    positive.DeviceId, positive.Pin, positive.Installation);
                await One("cancel-during-handshake", client, pin, false, false,
                    positive.DeviceId, positive.Pin, positive.Installation);
            }
            if (!existing)
            {
                stage = "desktop_persistence";
                byte[] clear = JsonSerializer.SerializeToUtf8Bytes(new
                {
                    purpose = "native-proof-only", clientPfx = Convert.ToBase64String(key),
                    deviceId = positive.DeviceId, certificateDigest = positive.Pin,
                    installationId = positive.Installation,
                });
                try { ProtectedDeviceStore.Create(directory, clear, RequireAdmission); }
                finally { CryptographicOperations.ZeroMemory(clear); }
            }
            Console.WriteLine($"PASS: native TLS proof; correct=accepted; wrong-server-pin=rejected; wrong-client=rejected; foreground-cancellation=settled; non-exportable=true; installation-stable=true; all-original-connections-settled=true; current-user-cng-retirement={(useCurrentUserCng ? "verified" : "not-used")}; business=closed");
        }
        finally { CryptographicOperations.ZeroMemory(key); }
    }

    private sealed record Identity(string DeviceId, string Pin, string Installation);
    private sealed class ClientLease(X509Certificate2 certificate, IDisposable owner) : IDisposable
    {
        internal X509Certificate2 Certificate { get; } = certificate;
        public void Dispose() => owner.Dispose();
    }
    private ClientLease LoadClient(byte[] pfx)
    {
        RequireAdmission();
        if (useCurrentUserCng)
        {
            var owner = WindowsTlsClientIdentity.Import(pfx, directory, RequireAdmission);
            return new ClientLease(owner.Certificate, owner);
        }
        var certificate = X509CertificateLoader.LoadPkcs12(pfx, null, X509KeyStorageFlags.EphemeralKeySet);
        return new ClientLease(certificate, certificate);
    }
    private static string Category(Exception error) => error switch
    {
        SocketException socket => $"socket_{socket.SocketErrorCode}",
        Win32Exception native => $"win32_{native.NativeErrorCode:X8}",
        AuthenticationException => "tls_authentication",
        IOException => "io",
        JsonException => "protocol",
        OperationCanceledException => "cancelled",
        CryptographicException => "crypto",
        _ => "unavailable",
    };

    private async Task<Identity> One(string scenario, X509Certificate2 client, string expectedClient,
        bool initialize, bool wrongServerPin, string? expectedDevice, string? expectedPin, string? expectedInstallation)
    {
        RequireAdmission();
        stage = "native_launch";
        string operation = Guid.NewGuid().ToString("D");
        // Public bootstrap arguments are kept in this local process, never tool output.
        var launch = await Adb("shell", "am", "start", "-W", "--user", "0", "-n",
            $"{Package}/com.example.shiroha_quiz.external.DeviceNativeProofActivity",
            "--es", "operation", operation, "--es", "address", address.ToString(),
            "--es", "clientPin", expectedClient, "--ez", "initialize", initialize ? "true" : "false");
        if (launch.Exit != 0 || launch.Text.Contains("Error", StringComparison.Ordinal))
            throw new LinkFailure("native_entry_unavailable");
        stage = "native_bootstrap";
        using var bootstrap = await Report(operation, "bootstrap");
        var value = bootstrap.RootElement;
        string device = value.GetProperty("deviceId").GetString()!;
        string phonePin = value.GetProperty("certificateDigest").GetString()!;
        string installation = value.GetProperty("installationId").GetString()!;
        if (expectedDevice != null && (device != expectedDevice || phonePin != expectedPin || installation != expectedInstallation))
            throw new LinkFailure("device_mismatch");
        var target = new DeviceTarget(device, wrongServerPin ? new string('0', 64) : phonePin,
            Guid.Empty.ToString("D"), address, value.GetProperty("port").GetInt32());
        bool handshake = false;
        string? handshakeFailure = null;
        string tlsStage = "connect";
        var errorCodes = new List<string>();
        stage = "tls_client";
        DeviceTransport.PinnedConnection? connection = null;
        using var raw = scenario == "cancel-during-handshake" ? new TcpClient(AddressFamily.InterNetwork) : null;
        try
        {
            if (scenario.StartsWith("cancel-", StringComparison.Ordinal))
            {
                if (raw != null)
                {
                    using var tcpLimit = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                    await raw.ConnectAsync(address, target.Port, tcpLimit.Token);
                }
                var home = await Adb("shell", "am", "start", "-W", "--user", "0",
                    "-a", "android.intent.action.MAIN", "-c", "android.intent.category.HOME");
                if (home.Exit != 0) throw new LinkFailure("native_cancellation_unavailable");
                tlsStage = "foreground_withdrawn";
            }
            else
            {
                connection = await DeviceTransport.OpenPinned(target, client, default, RequireAdmission, value => tlsStage = value);
                handshake = true;
            }
        }
        catch (Exception error) when (error is AuthenticationException or IOException or SocketException ||
            error is LinkFailure { Code: "credential_rejected" })
        {
            handshakeFailure = Category(error);
            for (Exception? cause = error; cause != null && errorCodes.Count < 6; cause = cause.InnerException)
                errorCodes.Add($"{Category(cause)}:{cause.HResult:X8}");
        }
        finally { connection?.Dispose(); }
        stage = "native_result";
        using var report = await Report(operation, "result");
        var outcome = report.RootElement;
        bool accepted = outcome.GetProperty("result").GetString() == "accepted";
        bool settled = outcome.GetProperty("settled").GetBoolean();
        bool nonExportable = outcome.GetProperty("nonExportable").GetBoolean();
        bool stable = outcome.GetProperty("installationStable").GetBoolean();
        int keySelections = outcome.GetProperty("keyManagerSelections").GetInt32();
        bool peerAttempted = outcome.GetProperty("peerPolicyAttempted").GetBoolean();
        bool peerPinMatched = outcome.GetProperty("peerPinMatched").GetBoolean();
        bool peerAccepted = outcome.GetProperty("peerPolicyAccepted").GetBoolean();
        int acceptedSockets = outcome.GetProperty("acceptedSockets").GetInt32();
        string? nativeResult = outcome.GetProperty("result").GetString();
        Console.WriteLine(JsonSerializer.Serialize(new { scenario, handshake, handshakeFailure, tlsStage, errorCodes,
            nativeResult, settled, nonExportable,
            installationStable = stable, keyManagerSelections = keySelections,
            nativeFailureKinds = outcome.GetProperty("failureKinds").GetString(),
            nativePeerPolicyAccepted = peerAccepted, nativePeerPolicyAttempted = peerAttempted,
            nativePeerPinMatched = peerPinMatched, acceptedSockets,
            nativeObservationCurrent = outcome.GetProperty("observationCurrent").GetBoolean() }));
        if (!settled) throw new LinkFailure("settlement_unknown");
        var finish = await Adb("shell", "am", "force-stop", "--user", "0", Package);
        // All native socket/worker results were settled BEFORE this owned-process stop.
        if (finish.Exit != 0) throw new LinkFailure("settlement_unknown");
        ValidateObservedOutcome(scenario, handshake, tlsStage, outcome);
        return new Identity(device, phonePin, installation);
    }

    internal static void ValidateObservedOutcome(string scenario, bool handshake, string tlsStage, JsonElement outcome)
    {
        bool common = outcome.GetProperty("settled").GetBoolean() && outcome.GetProperty("nonExportable").GetBoolean();
        string? native = outcome.GetProperty("result").GetString();
        bool foreground = outcome.GetProperty("observationCurrent").GetBoolean();
        bool peerAttempted = outcome.GetProperty("peerPolicyAttempted").GetBoolean();
        bool peerMatched = outcome.GetProperty("peerPinMatched").GetBoolean();
        bool peerAccepted = outcome.GetProperty("peerPolicyAccepted").GetBoolean();
        int sockets = outcome.GetProperty("acceptedSockets").GetInt32();
        int selections = outcome.GetProperty("keyManagerSelections").GetInt32();
        bool expected = scenario switch
        {
            "correct" => handshake && tlsStage == "peer_certificate_valid" && native == "accepted" &&
                foreground && sockets == 1 && selections > 0 && peerAttempted && peerMatched && peerAccepted &&
                outcome.GetProperty("installationStable").GetBoolean(),
            // Schannel can perform the local pin callback after the remote TLS
            // stack has authenticated its client. Each endpoint owns its decision.
            "wrong-server-pin" => !handshake && tlsStage == "peer_certificate_rejected" && foreground &&
                native is "accepted" or "credential_rejected",
            "wrong-client" => native == "credential_rejected" && foreground && sockets == 1 &&
                peerAttempted && !peerMatched && !peerAccepted,
            "cancel-before-accept" => !handshake && tlsStage == "foreground_withdrawn" && !foreground &&
                sockets == 0 && selections == 0 && !peerAttempted && native == "foreground_required",
            "cancel-during-handshake" => !handshake && tlsStage == "foreground_withdrawn" && !foreground &&
                sockets == 1 && selections == 0 && !peerAttempted && native is "foreground_required" or "credential_rejected",
            _ => false,
        };
        if (!common || !expected) throw new LinkFailure("native_proof_failed");
    }

    private async Task<JsonDocument> Report(string operation, string kind)
    {
        var wait = Stopwatch.StartNew();
        while (wait.Elapsed < TimeSpan.FromSeconds(8))
        {
            RequireAdmission();
            var result = await Adb("shell", "-T", "run-as", Package, "cat", $"cache/native-proof-v1/{operation}.{kind}.json");
            var parsed = ParseReport(result.Exit, result.Text, operation);
            if (parsed != null) return parsed;
            if (kind == "bootstrap")
            {
                var failure = await Adb("shell", "-T", "run-as", Package, "cat", $"cache/native-proof-v1/{operation}.result.json");
                using var failed = ParseReport(failure.Exit, failure.Text, operation);
                if (failed != null)
                {
                    string? code = failed.RootElement.GetProperty("result").GetString();
                    Console.WriteLine(JsonSerializer.Serialize(new { nativeResult = code,
                        stage = failed.RootElement.GetProperty("stage").GetString(),
                        settled = failed.RootElement.GetProperty("settled").GetBoolean(),
                        tlsDigestAuthorized = failed.RootElement.GetProperty("tlsDigestAuthorized").GetBoolean() }));
                    throw new LinkFailure("native_preparation_failed");
                }
            }
            await Task.Delay(150);
        }
        throw new LinkFailure("native_result_unavailable");
    }

    internal static JsonDocument? ParseReport(int exitCode, string text, string operation)
    {
        // exec-out does not carry the remote exit status. Use shell v2 above:
        // a missing report is absence, never successful JSON or native evidence.
        if (exitCode != 0) return null;
        JsonDocument? parsed = null;
        try
        {
            parsed = LinkFrames.StrictObject(Encoding.UTF8.GetBytes(text));
            if (parsed.RootElement.GetProperty("operation").GetString() != operation)
                throw new LinkFailure("protocol_violation");
            return parsed;
        }
        catch
        {
            parsed?.Dispose();
            throw new LinkFailure("protocol_violation");
        }
    }

    private async Task<(int Exit, string Text)> Adb(params string[] arguments)
    {
        RequireAdmission();
        var start = new ProcessStartInfo(adb) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true };
        start.ArgumentList.Add("-s"); start.ArgumentList.Add(serial);
        foreach (string argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new LinkFailure("device_unavailable");
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(12));
        async Task<string> ReadBounded(StreamReader reader)
        {
            char[] buffer = new char[16384]; int count = 0;
            while (true)
            {
                int read = await reader.ReadAsync(buffer.AsMemory(count), limit.Token);
                if (read == 0) return new string(buffer, 0, count);
                count += read;
                if (count == buffer.Length) throw new LinkFailure("resource_limit");
            }
        }
        Task<string> output = ReadBounded(process.StandardOutput), errors = ReadBounded(process.StandardError);
        try
        {
            await process.WaitForExitAsync(limit.Token);
            await Task.WhenAll(output, errors);
            return (process.ExitCode, await output);
        }
        catch
        {
            if (!process.HasExited) process.Kill();
            await process.WaitForExitAsync();
            try { await Task.WhenAll(output, errors); } catch { }
            throw;
        }
    }
}
