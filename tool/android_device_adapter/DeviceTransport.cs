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
    internal static async Task Forward(DeviceTarget target, X509Certificate2 client, Stream input, Stream output, CancellationToken stop)
    {
        RequireRuntime();
        target.Validate();
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(stop);
        using var tcp = new TcpClient(AddressFamily.InterNetwork);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        deadline.CancelAfter(TimeSpan.FromSeconds(5));
        await tcp.ConnectAsync(target.Address, target.Port, deadline.Token);
        using var tls = new SslStream(tcp.GetStream(), false, (_, cert, _, _) =>
            cert is X509Certificate2 parsed && DeviceCertificatePolicy.Check(parsed, target));
        await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = "shiroha-android-device", // Identity is pinned, never inferred from this name/IP.
            EnabledSslProtocols = SslProtocols.Tls13,
            AllowRenegotiation = false,
            ClientCertificates = new X509CertificateCollection { client },
        }, deadline.Token);
        if (!tls.IsMutuallyAuthenticated || tls.SslProtocol != SslProtocols.Tls13) throw new LinkFailure("credential_rejected");
        byte[] nonce = RandomNumberGenerator.GetBytes(32);
        string encodedNonce = Convert.ToBase64String(nonce).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        byte[] hello = JsonSerializer.SerializeToUtf8Bytes(new { type = "hello", purpose = "business", expectedDeviceId = target.DeviceId,
            expectedProfileId = target.ProfileId, clientNonce = encodedNonce, linkVersions = new[] { 1 } });
        await LinkFrames.Write(tls, 1, hello, false, deadline.Token);
        var ready = await LinkFrames.Read(tls, true, deadline.Token);
        if (ready.Kind != 1) throw new LinkFailure("protocol_violation");
        using (var doc = LinkFrames.StrictObject(ready.Body))
        {
            var root = doc.RootElement;
            string[] fields = ["type", "linkVersion", "deviceId", "profileId", "runtimeId", "connectionId", "clientNonce", "serverNonce"];
            if (root.EnumerateObject().Count() != fields.Length || fields.Any(f => !root.TryGetProperty(f, out _)) ||
                root.GetProperty("type").GetString() != "ready" || root.GetProperty("linkVersion").GetInt32() != 1 ||
                root.GetProperty("deviceId").GetString() != target.DeviceId || root.GetProperty("profileId").GetString() != target.ProfileId ||
                root.GetProperty("clientNonce").GetString() != encodedNonce ||
                !Guid.TryParseExact(root.GetProperty("runtimeId").GetString(), "D", out _) ||
                !Guid.TryParseExact(root.GetProperty("connectionId").GetString(), "D", out _) ||
                !System.Text.RegularExpressions.Regex.IsMatch(root.GetProperty("serverNonce").GetString() ?? "", "^[A-Za-z0-9_-]{43}$"))
                throw new LinkFailure("device_mismatch");
        }
        async Task Upload()
        {
            while (await LinkFrames.ReadStdioLine(input, lifetime.Token) is { } line)
                await LinkFrames.Write(tls, 2, line, false, lifetime.Token);
        }
        async Task Download()
        {
            while (true)
            {
                var frame = await LinkFrames.Read(tls, true, lifetime.Token);
                if (frame.Kind != 2) throw new LinkFailure("protocol_violation");
                using var doc = LinkFrames.StrictObject(frame.Body);
                using var write = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                write.CancelAfter(TimeSpan.FromSeconds(5));
                await output.WriteAsync(frame.Body, write.Token);
                await output.WriteAsync(new byte[] { 10 }, write.Token);
                await output.FlushAsync(write.Token);
            }
        }
        Task upload = Upload(), download = Download();
        try { await await Task.WhenAny(upload, download); }
        finally
        {
            lifetime.Cancel(); tcp.Close();
            // Observe both original pumps. Never launch a replacement from here.
            try { await Task.WhenAll(upload, download); } catch { }
        }
    }

    internal static void RequireRuntime() => throw new LinkFailure("runtime_not_authorized");
}
