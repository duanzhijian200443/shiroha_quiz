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
            "tls" or "hello" or "offer" or "proof" or "settlement" or "settlement-receipt" or "settled")) return null;
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
        bool refresh = mode == "enable-proof" && address != null;
        Action? credentialSlot = link == null ? null : refresh ? link.RequireAddressRefresh : link.RequireSlot;
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
            if (refresh && link == null) throw new LinkFailure("runtime_not_authorized");
            Enter("protected-configuration");
            clear = ProtectedDeviceStore.Read(directory, Admission, credentialSlot);
            using var document = LinkFrames.StrictObject(clear);
            var record = document.RootElement;
            string purpose = record.GetProperty("purpose").GetString()!;
            if (mode != "pairing" && purpose != "android-read") throw new LinkFailure("pairing_required");
            if (mode == "pairing" && purpose is not ("native-proof-only" or "android-read" or "link-pairing")) throw new LinkFailure("credential_store_corrupt");
            if (purpose == "link-pairing" && link?.Initializing != true) throw new LinkFailure("runtime_not_authorized");
            if (refresh) DeviceAddressRefresh.RequirePairedRecord(record);
            string device = record.GetProperty("deviceId").GetString()!, pin = record.GetProperty("certificateDigest").GetString()!;
            string? installation = record.GetProperty("installationId").GetString();
            string profile = purpose == "android-read" ? record.GetProperty("profileId").GetString()! : "00000000-0000-4000-8000-000000000001";
            var target = new DeviceTarget(device, pin, profile,
                IPAddress.Parse(address ?? record.GetProperty("address").GetString()!), 46443);
            target.Validate();
            if (installation != null) link?.RequireTarget(target, installation);
            pfx = Convert.FromBase64String(record.GetProperty("clientPfx").GetString()!);
            if (mode != "business") stop.CancelAfter(TimeSpan.FromSeconds(120));
            Enter("client-key");
            using (var identity = WindowsTlsClientIdentity.Import(pfx, directory, Admission, credentialSlot))
            {
                if (mode == "business")
                {
                    using var input = new WindowsStdioInput();
                    await DeviceTransport.Forward(target, identity.Certificate, input, Console.OpenStandardOutput(), stop.Token,
                        Admission, profileVersion, ReportBusinessFailure, installation, link == null ? null : () => link.Ready(target, installation!));
                }
                else
                {
                using var establishment = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                establishment.CancelAfter(TimeSpan.FromSeconds(5));
                Enter("tls");
                using var connection = await DeviceTransport.OpenPinned(target, identity.Certificate, establishment.Token, Admission);
                var binding = await DeviceProof.Exchange(connection.Tls, identity.Certificate, target, record, mode,
                    establishment.Token, stop.Token, Enter, link?.Registering == true ?
                        digest => RegistrationCustody.ObserveFingerprint(directory, link.Operation, link.Run, link.Resource, digest) : null);
                profile = binding.Profile; installation = binding.Installation;
                target = target with { ProfileId = profile };
                if (mode == "pairing") replacement = JsonSerializer.SerializeToUtf8Bytes(new {
                    purpose = "android-read", clientPfx = Convert.ToBase64String(pfx), deviceId = device, certificateDigest = pin,
                    installationId = installation, profileId = profile, associationRevision = binding.Revision,
                    address = target.Address.ToString(), port = target.Port,
                });
                else if (refresh) replacement = DeviceAddressRefresh.Replacement(record, target.Address);
                }
            }
            // CNG retirement and original TLS close precede persistent replacement.
            // For refresh, finish all fallible receipt publication before the
            // address commit. The receipt attests TLS/key resources only; Link
            // still requires original successful exit and all stream joins.
            if (refresh) {
                Enter("settlement-receipt");
                link!.Settled(mode, target, installation!);
            }
            if (replacement.Length != 0) {
                Enter("protected-configuration");
                if (refresh) ProtectedDeviceStore.ReplaceAddress(directory, clear, replacement, Admission, credentialSlot!);
                else ProtectedDeviceStore.Replace(directory, clear, replacement, Admission, credentialSlot);
            }
            if (link != null && !refresh)
            {
                Enter("settlement-receipt");
                link.Settled(mode, target, installation!);
            }
            Enter("settled");
            if (mode != "business") {
                try { Console.WriteLine($"android_{mode}_settled; restart-business-adapter-only-after-phone-enabled"); }
                catch when (refresh) { /* Commit succeeded; output is not authority. */ }
            }
            return 0;
        }
        catch (LinkFailure error) {
            if (mode == "business") ReportBusinessFailure("connection", error);
            Report(error.Code); Console.Error.WriteLine($"android_device:{stage}:{error.Code}"); return error.Code == "settlement_unknown" ? 79 : 78;
        }
        catch (Exception error) {
            if (mode == "business") ReportBusinessFailure("connection", error);
            bool receiptAccessDenied = stage == "settlement-receipt" && error is UnauthorizedAccessException;
            string category = error is System.Net.Sockets.SocketException ? "socket" :
                error is System.Security.Authentication.AuthenticationException ? "tls" : error is EndOfStreamException ? "eof" :
                error is OperationCanceledException ? "deadline" : error is IOException || receiptAccessDenied ? "io" : "invalid_configuration";
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
