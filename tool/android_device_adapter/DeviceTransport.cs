using System.Formats.Asn1;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace Shiroha.AndroidDevice;

internal sealed record DeviceTarget(string DeviceId, string CertificateDigest, string ProfileId,
    IPAddress Address, int Port)
{
    public override string ToString() => "DeviceTarget(REDACTED)";
    internal void Validate()
    {
        if (!HexDigest(DeviceId) || !HexDigest(CertificateDigest) || !Guid.TryParseExact(ProfileId, "D", out _) ||
            Port is < 1 or > 65535 || !PrivateV4(Address)) throw new LinkFailure("invalid_target");
    }
    internal static bool HexDigest(string value) => value.Length == 64 && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    internal static bool PrivateV4(IPAddress address)
    {
        byte[] b = address.GetAddressBytes();
        return b.Length == 4 && (b[0] == 10 || (b[0] == 172 && b[1] is >= 16 and <= 31) || (b[0] == 192 && b[1] == 168));
    }
}

internal static class DeviceCertificatePolicy
{
    internal static bool Check(X509Certificate2? certificate, DeviceTarget target, DateTime? observedUtc = null)
    {
        if (certificate is null) return false;
        try
        {
            target.Validate();
            if (!certificate.IssuerName.RawData.SequenceEqual(certificate.SubjectName.RawData)) return false;
            if (!CryptographicOperations.FixedTimeEquals(SHA256.HashData(certificate.RawData), Convert.FromHexString(target.CertificateDigest))) return false;
            DateTime now = observedUtc ?? DateTime.UtcNow;
            if (now < certificate.NotBefore.ToUniversalTime() || now >= certificate.NotAfter.ToUniversalTime()) return false;
            using ECDsa? key = certificate.GetECDsaPublicKey();
            if (key is null || key.ExportParameters(false).Curve.Oid.Value != "1.2.840.10045.3.1.7" ||
                !CryptographicOperations.FixedTimeEquals(SHA256.HashData(key.ExportSubjectPublicKeyInfo()), Convert.FromHexString(target.DeviceId))) return false;
            foreach (var extension in certificate.Extensions)
            {
                if (extension is X509BasicConstraintsExtension basic && basic.CertificateAuthority) return false;
                if (extension is X509KeyUsageExtension usage && !usage.KeyUsages.HasFlag(X509KeyUsageFlags.DigitalSignature)) return false;
                if (extension is X509EnhancedKeyUsageExtension eku && (eku.EnhancedKeyUsages.Count != 1 || eku.EnhancedKeyUsages[0].Value != "1.3.6.1.5.5.7.3.1")) return false;
                if (extension.Critical && extension is not (X509BasicConstraintsExtension or X509KeyUsageExtension or X509EnhancedKeyUsageExtension)) return false;
            }
            var reader = new AsnReader(certificate.RawData, AsnEncodingRules.DER);
            var sequence = reader.ReadSequence(); reader.ThrowIfNotEmpty();
            ReadOnlyMemory<byte> tbs = sequence.ReadEncodedValue();
            var algorithm = sequence.ReadSequence();
            if (algorithm.ReadObjectIdentifier() != "1.2.840.10045.4.3.2") return false;
            algorithm.ThrowIfNotEmpty();
            byte[] signature = sequence.ReadBitString(out int unused); sequence.ThrowIfNotEmpty();
            return unused == 0 && key.VerifyData(tbs.Span, signature, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence);
        }
        catch { return false; }
    }
}

/// <summary>One connection; failure ends stdio. No alternate target or write replay.</summary>
internal static class DeviceTransport
{
    internal sealed class PinnedConnection(TcpClient tcp, SslStream tls) : IDisposable
    {
        internal TcpClient Tcp { get; } = tcp;
        internal SslStream Tls { get; } = tls;
        public void Dispose()
        {
            bool clean = true;
            try { Tls.Dispose(); } catch { clean = false; }
            try { Tcp.Dispose(); } catch { clean = false; }
            if (!clean) throw new LinkFailure("settlement_unknown");
        }
    }

    // A compiled local owner supplies acquisition admission. This produces no
    // Application evidence or READY, and the ordinary entry remains closed.
    internal static async Task<PinnedConnection> OpenPinned(DeviceTarget target,
        X509Certificate2 client, CancellationToken stop, Action requireAdmission, Action<string>? observe = null)
    {
        requireAdmission();
        target.Validate();
        var tcp = new TcpClient(AddressFamily.InterNetwork);
        SslStream? tls = null;
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop);
            deadline.CancelAfter(TimeSpan.FromSeconds(5));
            await tcp.ConnectAsync(target.Address, target.Port, deadline.Token);
            observe?.Invoke("tcp_connected");
            requireAdmission();
            tls = new SslStream(tcp.GetStream(), false, (_, cert, _, _) =>
            {
                bool accepted = cert is X509Certificate2 parsed && DeviceCertificatePolicy.Check(parsed, target);
                observe?.Invoke(accepted ? "peer_certificate_valid" : "peer_certificate_rejected");
                return accepted;
            });
            await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
            {
                TargetHost = "shiroha-android-device",
                EnabledSslProtocols = SslProtocols.Tls13,
                AllowRenegotiation = false,
                AllowTlsResume = false,
                ClientCertificates = new X509CertificateCollection { client },
            }, deadline.Token);
            requireAdmission();
            if (!tls.IsMutuallyAuthenticated || tls.SslProtocol != SslProtocols.Tls13)
                throw new LinkFailure("credential_rejected");
            return new PinnedConnection(tcp, tls);
        }
        catch
        {
            bool clean = true;
            try { tls?.Dispose(); } catch { clean = false; }
            try { tcp.Dispose(); } catch { clean = false; }
            if (!clean) throw new LinkFailure("settlement_unknown");
            throw;
        }
    }

    internal static async Task Forward(DeviceTarget target, X509Certificate2 client, Stream input, Stream output, CancellationToken stop, Action? admission = null, int profileVersion = 2, Action<string, Exception>? observeFailure = null)
    {
        Action requireAdmission = admission ?? RequireRuntime;
        requireAdmission();
        target.Validate();
        if (profileVersion is not (2 or 3)) throw new LinkFailure("unsupported_profile");
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(stop);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        deadline.CancelAfter(TimeSpan.FromSeconds(5));
        using var connection = await OpenPinned(target, client, deadline.Token, requireAdmission);
        var tcp = connection.Tcp;
        var tls = connection.Tls;
        byte[] nonce = RandomNumberGenerator.GetBytes(32);
        string encodedNonce = Convert.ToBase64String(nonce).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var helloFields = new Dictionary<string, object?> { ["type"] = "hello", ["purpose"] = "business",
            ["expectedDeviceId"] = target.DeviceId, ["expectedProfileId"] = target.ProfileId,
            ["clientNonce"] = encodedNonce, ["linkVersions"] = new[] { 1 } };
        if (profileVersion == 3) helloFields["profileVersion"] = 3;
        byte[] hello = JsonSerializer.SerializeToUtf8Bytes(helloFields);
        await LinkFrames.Write(tls, 1, hello, false, deadline.Token);
        var ready = await LinkFrames.Read(tls, true, deadline.Token);
        if (ready.Kind != 1) throw new LinkFailure("protocol_violation");
        string connectionId;
        using (var doc = LinkFrames.StrictObject(ready.Body))
        {
            var root = doc.RootElement;
            string[] fields = ["type", "linkVersion", "deviceId", "profileId", "runtimeId", "connectionId", "clientNonce", "serverNonce"];
            if (profileVersion == 3) fields = [.. fields, "profileVersion"];
            if (root.EnumerateObject().Count() != fields.Length || fields.Any(f => !root.TryGetProperty(f, out _)) ||
                root.GetProperty("type").GetString() != "ready" || root.GetProperty("linkVersion").GetInt32() != 1 ||
                (profileVersion == 3 && root.GetProperty("profileVersion").GetInt32() != 3) ||
                root.GetProperty("deviceId").GetString() != target.DeviceId || root.GetProperty("profileId").GetString() != target.ProfileId ||
                root.GetProperty("clientNonce").GetString() != encodedNonce ||
                !Guid.TryParseExact(root.GetProperty("runtimeId").GetString(), "D", out _) ||
                !Guid.TryParseExact(root.GetProperty("connectionId").GetString(), "D", out _) ||
                !DeviceClient.IsNonce(root.GetProperty("serverNonce").GetString() ?? ""))
                throw new LinkFailure("device_mismatch");
            connectionId = root.GetProperty("connectionId").GetString()!;
        }
        using var writer = new LinkWriter(tls, lifetime.Token);
        long lastPeer = System.Diagnostics.Stopwatch.GetTimestamp();
        string? pendingPing = null;
        object heartbeatLock = new();
        string? closingNonce = null;
        var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task Upload()
        {
            while (await LinkFrames.ReadStdioLine(input, lifetime.Token) is { } line)
                await writer.Write(2, line);
            if (profileVersion == 3)
            {
                closingNonce = DeviceClient.Nonce();
                await writer.Write(1, JsonSerializer.SerializeToUtf8Bytes(new { type = "closing", connectionId, nonce = closingNonce }));
                await closed.Task.WaitAsync(TimeSpan.FromSeconds(45), lifetime.Token);
            }
        }
        async Task Download()
        {
            while (true)
            {
                var frame = await LinkFrames.Read(tls, true, lifetime.Token);
                using var doc = LinkFrames.StrictObject(frame.Body);
                if (frame.Kind == 1)
                {
                    var control = doc.RootElement;
                    DeviceClient.Fields(control, ["type", "connectionId", "nonce"]);
                    string controlType = DeviceClient.Text(control, "type"), heartbeatNonce = DeviceClient.Text(control, "nonce");
                    if (DeviceClient.Text(control, "connectionId") != connectionId ||
                        !DeviceClient.IsNonce(heartbeatNonce)) throw new LinkFailure("protocol_violation");
                    if (controlType == "closed" && profileVersion == 3 && closingNonce != null && heartbeatNonce == closingNonce)
                    {
                        using var closing = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                        closing.CancelAfter(TimeSpan.FromSeconds(5));
                        await tls.ShutdownAsync().WaitAsync(closing.Token);
                        byte[] end = new byte[1];
                        if (await tls.ReadAsync(end, closing.Token) != 0)
                            throw new LinkFailure("settlement_unknown");
                        closed.TrySetResult();
                        return;
                    }
                    if (controlType == "ping")
                        await writer.Write(1, JsonSerializer.SerializeToUtf8Bytes(new { type = "pong", connectionId, nonce = heartbeatNonce }));
                    else if (controlType == "pong")
                    {
                        lock (heartbeatLock)
                        {
                            if (pendingPing == null || pendingPing != heartbeatNonce) throw new LinkFailure("protocol_violation");
                            pendingPing = null;
                        }
                    }
                    else throw new LinkFailure("protocol_violation");
                    Interlocked.Exchange(ref lastPeer, System.Diagnostics.Stopwatch.GetTimestamp());
                    continue;
                }
                if (frame.Kind != 2 || !doc.RootElement.TryGetProperty("jsonrpc", out var version) || version.GetString() != "2.0")
                    throw new LinkFailure("protocol_violation");
                Interlocked.Exchange(ref lastPeer, System.Diagnostics.Stopwatch.GetTimestamp());
                using var write = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                write.CancelAfter(TimeSpan.FromSeconds(5));
                await output.WriteAsync(frame.Body, write.Token);
                await output.WriteAsync(new byte[] { 10 }, write.Token);
                await output.FlushAsync(write.Token);
            }
        }
        async Task Heartbeat()
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(15));
            while (await timer.WaitForNextTickAsync(lifetime.Token))
            {
                requireAdmission();
                if (System.Diagnostics.Stopwatch.GetElapsedTime(Interlocked.Read(ref lastPeer)) >= TimeSpan.FromSeconds(45))
                    throw new LinkFailure("peer_lost");
                string? nonce = null;
                lock (heartbeatLock) { if (pendingPing == null && !writer.Busy) nonce = pendingPing = DeviceClient.Nonce(); }
                if (nonce != null) await writer.Write(1, JsonSerializer.SerializeToUtf8Bytes(new { type = "ping", connectionId, nonce }));
            }
        }
        Task upload = Upload(), download = Download(), heartbeat = Heartbeat();
        string endedStage = "connection";
        try
        {
            var completed = await Task.WhenAny(upload, download, heartbeat);
            endedStage = completed == upload ? "upload" : completed == download ? "download" : "heartbeat";
            await completed;
            if (profileVersion == 3 && !closed.Task.IsCompletedSuccessfully)
                throw new LinkFailure("settlement_unknown");
        }
        catch (Exception error) when (profileVersion == 3)
        {
            try { observeFailure?.Invoke(endedStage, error); } catch { /* Observation only. */ }
            throw new LinkFailure("settlement_unknown");
        }
        finally
        {
            lifetime.Cancel(); tcp.Close();
            // Observe both original pumps. Never launch a replacement from here.
            try { await Task.WhenAll(upload, download, heartbeat); } catch { }
        }
    }

    private sealed class LinkWriter(Stream output, CancellationToken stop) : IDisposable
    {
        private readonly SemaphoreSlim serial = new(1, 1);
        private int queued;
        internal bool Busy => Volatile.Read(ref queued) != 0;
        internal async Task Write(byte kind, byte[] body)
        {
            if (Interlocked.Increment(ref queued) > 2)
            { Interlocked.Decrement(ref queued); throw new LinkFailure("resource_limit"); }
            bool acquired = false;
            try
            {
                await serial.WaitAsync(stop); acquired = true;
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop);
                deadline.CancelAfter(TimeSpan.FromSeconds(5));
                await LinkFrames.Write(output, kind, body, false, deadline.Token);
            }
            finally { if (acquired) serial.Release(); Interlocked.Decrement(ref queued); }
        }
        public void Dispose() => serial.Dispose();
    }

    internal static void RequireRuntime() => throw new LinkFailure("runtime_not_authorized");
}
