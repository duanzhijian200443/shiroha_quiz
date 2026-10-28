using System.Buffers.Binary;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography.X509Certificates;

namespace Shiroha.AndroidDevice;

internal static class SyntheticTests
{
    private static void Check(bool condition) { if (!condition) throw new Exception("fixture_failed"); }
    private static void Reject(Action action)
    {
        try { action(); } catch (LinkFailure) { return; }
        throw new Exception("expected_rejection");
    }
    internal static int Run()
    {
        // No socket, native key, credential file, process, model or App operations.
        byte[] header = new byte[12]; "SHAD"u8.CopyTo(header); header[4] = 1; header[5] = 1;
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(8), 2);
        Check(LinkFrames.Length(header, false) == 2);
        header[4] = 2; Reject(() => LinkFrames.Length(header, false)); header[4] = 1;
        header[6] = 1; Reject(() => LinkFrames.Length(header, false)); header[6] = 0;
        BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(8), uint.MaxValue); Reject(() => LinkFrames.Length(header, false));
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(8), 0); Reject(() => LinkFrames.Length(header, false));
        using var memory = new MemoryStream();
        LinkFrames.Write(memory, 2, "{}"u8.ToArray(), false, default).GetAwaiter().GetResult(); memory.Position = 0;
        var frame = LinkFrames.Read(memory, false, default).GetAwaiter().GetResult(); Check(frame.Kind == 2 && frame.Body.SequenceEqual("{}"u8.ToArray()));
        Reject(() => LinkFrames.StrictObject("{\"x\":1,\"x\":2}"u8.ToArray()));
        Reject(() => LinkFrames.StrictObject("{\"x\":{\"a\":1,\"a\":2}}"u8.ToArray()));
        Reject(() => LinkFrames.StrictObject("[]"u8.ToArray()));
        Check(DeviceTarget.PrivateV4(IPAddress.Parse("192.168.1.2")));
        Check(!DeviceTarget.PrivateV4(IPAddress.Loopback));
        Check(!DeviceTarget.PrivateV4(IPAddress.Parse("8.8.8.8")));
        Check(!DeviceTarget.PrivateV4(IPAddress.IPv6Loopback));
        Check(!DeviceCertificatePolicy.Check(null, new DeviceTarget("bad", "bad", "bad", IPAddress.Any, 0)));
        Reject(DeviceTransport.RequireRuntime);
        Reject(() => ProtectedDeviceStore.Read("must-not-be-accessed"));
        Reject(() => ProtectedDeviceStore.Create("must-not-be-created", Encoding.UTF8.GetBytes("{}")));
        Reject(() => ProtectedDeviceStore.CreateClientIdentity());
        using var fixtures = typeof(SyntheticTests).Assembly.GetManifestResourceStream("AndroidDeviceAdapter.fixtures.public-certificates.json")!;
        using var vectors = JsonDocument.Parse(fixtures);
        var v = vectors.RootElement;
        string Value(string key) => v.GetProperty(key).GetString()!;
        using var server = X509CertificateLoader.LoadCertificate(Convert.FromHexString(Value("server")));
        var target = new DeviceTarget(Value("deviceId"), Value("serverDigest"), "10000000-0000-4000-8000-000000000001", IPAddress.Parse("192.168.1.2"), 12345);
        DateTime now = new(2026, 10, 28, 0, 0, 0, DateTimeKind.Utc);
        Check(DeviceCertificatePolicy.Check(server, target, now));
        Check(!DeviceCertificatePolicy.Check(server, target with { CertificateDigest = new string('0', 64) }, now));
        Check(!DeviceCertificatePolicy.Check(server, target with { DeviceId = new string('0', 64) }, now));
        Check(!DeviceCertificatePolicy.Check(server, target, now.AddYears(3)));
        using var wrongRole = X509CertificateLoader.LoadCertificate(Convert.FromHexString(Value("client")));
        Check(!DeviceCertificatePolicy.Check(wrongRole, target with { CertificateDigest = Value("clientDigest") }, now));
        using var expired = X509CertificateLoader.LoadCertificate(Convert.FromHexString(Value("expired")));
        Check(!DeviceCertificatePolicy.Check(expired, target with { CertificateDigest = Value("expiredDigest") }, now));
        Console.WriteLine("PASS: 24 synthetic Android adapter checks; runtime remains disabled");
        return 0;
    }
}
