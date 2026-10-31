using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;

namespace Shiroha.AndroidDevice;

/// <summary>Local pairing/enable helper and one normal business adapter process.</summary>
internal static class DeviceClient
{
    internal static string? RecoveryReport(string stage, string? failure = null)
    {
        if (stage is not ("configuration" or "protected-configuration" or "client-key" or
            "tls" or "hello" or "offer" or "proof" or "settlement" or "settled")) return null;
        if (failure != null && failure is not ("runtime_not_authorized" or "invalid_target" or
            "pairing_required" or "credential_store_corrupt" or "credential_store_unavailable" or
            "credential_commit_unknown" or "credential_rejected" or "device_mismatch" or
            "stale_revision" or "protocol_violation" or "settlement_unknown" or "socket" or
            "tls" or "eof" or "deadline" or "io" or "invalid_configuration" or
            "peer_lost" or "resource_limit")) return null;
        return $"SHIROHA_ANDROID_RECOVERY|{(failure == null ? "S" : "P")}|{stage}" +
            (failure == null ? "" : $"|{failure}");
    }

    internal static string? BusinessReport(string stage, string failure) =>
        (stage is "upload" or "download" or "heartbeat" or "connection") &&
        RecoveryReport("tls", failure) != null
            ? $"SHIROHA_ANDROID_LINK|P|{stage}|{failure}" : null;

    private static void ReportBusinessFailure(string stage, Exception error)
    {
        string code = error is LinkFailure link ? link.Code :
            error is OperationCanceledException ? "deadline" :
            error is EndOfStreamException ? "eof" :
            error is IOException ? "io" : "invalid_configuration";
        var line = BusinessReport(stage, code) ?? BusinessReport(stage, "invalid_configuration");
        try { Console.Error.WriteLine(line); } catch { /* Observation only. */ }
    }

    internal static bool IsRecordDirectory(string directory)
    {
        try
        {
            DirectoryInfo? root = new(AppContext.BaseDirectory);
            while (root != null && !File.Exists(Path.Combine(root.FullName, "pubspec.yaml"))) root = root.Parent;
            return root != null && Path.GetFullPath(directory).Equals(
                Path.Combine(root.FullName, "build", "android_device_read"), StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    internal static async Task<int> Run(string mode, string directory, string? address, int profileVersion = 2, LinkAdapterContext? link = null)
    {
        byte[] clear = [], pfx = [], replacement = [];
        using var stop = new CancellationTokenSource();
        bool ended = false;
        string stage = "configuration";
        void Report(string? failure = null)
        {
            if (mode == "enable-proof" && RecoveryReport(stage, failure) is { } line)
            {
                try { Console.Error.WriteLine(line); }
                catch { /* Diagnostics cannot interrupt original cleanup. */ }
            }
        }
        void Enter(string value) { stage = value; Report(); }
        void Admission()
        {
            link?.RequireCurrent();
            if (ended || !OperatingSystem.IsWindows() || stop.IsCancellationRequested)
                throw new LinkFailure("runtime_not_authorized");
        }
        try
        {
            Report();
            if (link == null && !IsRecordDirectory(directory))
                throw new LinkFailure("invalid_target");
            Enter("protected-configuration");
            clear = ProtectedDeviceStore.Read(directory, Admission, link == null ? null : link.RequireSlot);
            using var document = LinkFrames.StrictObject(clear);
            var record = document.RootElement;
            string purpose = record.GetProperty("purpose").GetString()!;
            if (mode != "pairing" && purpose != "android-read") throw new LinkFailure("pairing_required");
            if (mode == "pairing" && purpose is not ("native-proof-only" or "android-read")) throw new LinkFailure("credential_store_corrupt");
            string device = record.GetProperty("deviceId").GetString()!, pin = record.GetProperty("certificateDigest").GetString()!;
            string installation = record.GetProperty("installationId").GetString()!;
            string profile = purpose == "android-read" ? record.GetProperty("profileId").GetString()! : "00000000-0000-4000-8000-000000000001";
            var target = new DeviceTarget(device, pin, profile,
                IPAddress.Parse(address ?? record.GetProperty("address").GetString()!), 46443);
            target.Validate();
            link?.RequireTarget(target, installation);
            pfx = Convert.FromBase64String(record.GetProperty("clientPfx").GetString()!);
            if (mode != "business") stop.CancelAfter(TimeSpan.FromSeconds(120));
            Enter("client-key");
            using (var identity = WindowsTlsClientIdentity.Import(pfx, directory, Admission, link == null ? null : link.RequireSlot))
            {
                if (mode == "business")
                {
                    using var input = new WindowsStdioInput();
                    await DeviceTransport.Forward(target, identity.Certificate, input, Console.OpenStandardOutput(), stop.Token,
                        Admission, profileVersion, ReportBusinessFailure, installation, link == null ? null : () => link.Ready(target, installation));
                }
                else
                {
                using var establishment = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                establishment.CancelAfter(TimeSpan.FromSeconds(5));
                Enter("tls");
                using var connection = await DeviceTransport.OpenPinned(target, identity.Certificate, establishment.Token, Admission);
                Enter("hello");
                string clientNonce = Nonce();
                await LinkFrames.Write(connection.Tls, 1, JsonSerializer.SerializeToUtf8Bytes(new {
                    type = "hello", purpose = mode, expectedDeviceId = device,
                    expectedProfileId = mode == "pairing" ? null : profile, clientNonce, linkVersions = new[] { 1 }
                }), false, establishment.Token);
                Enter("offer");
                var offerFrame = await LinkFrames.Read(connection.Tls, true, establishment.Token);
                using var offerDocument = LinkFrames.StrictObject(offerFrame.Body);
                var offer = offerDocument.RootElement;
                Fields(offer, ["type", "purpose", "deviceId", "installationId", "profileId", "runtimeId", "connectionId", "clientNonce", "serverNonce", "clientCertificateDigest", "serverCertificateDigest", "associationRevision"]);
                string actualClient = Convert.ToHexStringLower(SHA256.HashData(identity.Certificate.RawData));
                if (offerFrame.Kind != 1 || Text(offer, "type") != "offer" || Text(offer, "purpose") != mode ||
                    Text(offer, "deviceId") != device || Text(offer, "installationId") != installation ||
                    Text(offer, "serverCertificateDigest") != pin || Text(offer, "clientCertificateDigest") != actualClient ||
                    Text(offer, "clientNonce") != clientNonce ||
                    !Guid.TryParseExact(Text(offer, "profileId"), "D", out _) ||
                    !Guid.TryParseExact(Text(offer, "runtimeId"), "D", out _) ||
                    !Guid.TryParseExact(Text(offer, "connectionId"), "D", out _) ||
                    !IsNonce(Text(offer, "serverNonce")) ||
                    (mode != "pairing" && Text(offer, "profileId") != profile)) throw new LinkFailure("device_mismatch");
                string connectionId = Text(offer, "connectionId"), serverNonce = Text(offer, "serverNonce");
                profile = Text(offer, "profileId");
                Console.WriteLine(JsonSerializer.Serialize(new { stage = "verified-offer", deviceId = device,
                    certificateDigest = pin, clientCertificateDigest = actualClient, installationId = installation, profileId = profile,
                    action = mode == "pairing" ? "Compare the full client fingerprint and confirm on the phone" : "Waiting for original P15 confirmation and settlement" }));
                Enter("proof");
                var proofFrame = await LinkFrames.Read(connection.Tls, true, stop.Token);
                using var proofDocument = LinkFrames.StrictObject(proofFrame.Body);
                var proof = proofDocument.RootElement;
                Fields(proof, ["type", "connectionId", "clientNonce", "serverNonce", "profileId", "associationRevision", "settlementNonce"]);
                if (proofFrame.Kind != 1 || Text(proof, "type") != "proof-complete" || Text(proof, "connectionId") != connectionId ||
                    Text(proof, "clientNonce") != clientNonce || Text(proof, "serverNonce") != serverNonce ||
                    Text(proof, "profileId") != profile || proof.GetProperty("associationRevision").GetInt32() < 1)
                    throw new LinkFailure("protocol_violation");
                string settlementNonce = Text(proof, "settlementNonce");
                if (!IsNonce(settlementNonce)) throw new LinkFailure("protocol_violation");
                if (mode == "enable-proof" && proof.GetProperty("associationRevision").GetInt32() != record.GetProperty("associationRevision").GetInt32())
                    throw new LinkFailure("stale_revision");
                Enter("settlement");
                using var closing = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                closing.CancelAfter(TimeSpan.FromSeconds(5));
                await LinkFrames.Write(connection.Tls, 1, JsonSerializer.SerializeToUtf8Bytes(new { type = "closing", connectionId, clientNonce, serverNonce, settlementNonce }), false, closing.Token);
                await connection.Tls.ShutdownAsync().WaitAsync(closing.Token);
                byte[] one = new byte[1];
                if (await connection.Tls.ReadAsync(one, closing.Token) != 0) throw new LinkFailure("settlement_unknown");
                if (mode == "pairing") replacement = JsonSerializer.SerializeToUtf8Bytes(new {
                    purpose = "android-read", clientPfx = Convert.ToBase64String(pfx), deviceId = device, certificateDigest = pin,
                    installationId = installation, profileId = profile, associationRevision = proof.GetProperty("associationRevision").GetInt32(),
                    address = target.Address.ToString(), port = target.Port,
                });
                }
            }
            // CNG retirement and original TLS close precede persistent replacement.
            if (replacement.Length != 0) ProtectedDeviceStore.Replace(directory, clear, replacement, Admission);
            Enter("settled");
            link?.Settled(mode, target, installation);
            if (mode != "business") Console.WriteLine($"android_{mode}_settled; restart-business-adapter-only-after-phone-enabled");
            return 0;
        }
        catch (LinkFailure error) {
            if (mode == "business") ReportBusinessFailure("connection", error);
            Report(error.Code); Console.Error.WriteLine($"android_device:{stage}:{error.Code}"); return error.Code == "settlement_unknown" ? 79 : 78;
        }
        catch (Exception error) {
            if (mode == "business") ReportBusinessFailure("connection", error);
            string category = error is System.Net.Sockets.SocketException ? "socket" :
                error is System.Security.Authentication.AuthenticationException ? "tls" : error is EndOfStreamException ? "eof" :
                error is OperationCanceledException ? "deadline" : error is IOException ? "io" : "invalid_configuration";
            Report(category);
            Console.Error.WriteLine(JsonSerializer.Serialize(new {
            androidDevice = "unavailable", stage, category,
            code = error.HResult })); return 78; }
        finally
        {
            ended = true;
            CryptographicOperations.ZeroMemory(clear); CryptographicOperations.ZeroMemory(pfx); CryptographicOperations.ZeroMemory(replacement);
        }
    }
    internal static string Nonce() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    internal static bool IsNonce(string value)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(value, "^[A-Za-z0-9_-]{43}$")) return false;
        try
        {
            byte[] bytes = Convert.FromBase64String(value.Replace('-', '+').Replace('_', '/') + "=");
            return bytes.Length == 32 && Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') == value;
        }
        catch { return false; }
    }
    internal static string Text(JsonElement value, string key) => value.GetProperty(key).GetString() ?? throw new LinkFailure("protocol_violation");
    internal static void Fields(JsonElement value, string[] fields)
    {
        if (value.EnumerateObject().Count() != fields.Length || fields.Any(f => !value.TryGetProperty(f, out _))) throw new LinkFailure("protocol_violation");
    }
}
