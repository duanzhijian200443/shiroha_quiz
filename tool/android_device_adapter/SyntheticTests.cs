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
        const string operation = "10000000-0000-4000-8000-000000000001";
        Check(NativeProof.ParseReport(1, "cat: No such file or directory", operation) == null);
        Reject(() => NativeProof.ParseReport(0, "cat: No such file or directory", operation));
        Reject(() => NativeProof.ParseReport(0, "{\"operation\":\"different\"}", operation));
        using var proofReport = NativeProof.ParseReport(0, "{\"operation\":\"" + operation + "\"}", operation);
        Check(proofReport != null);
        Reject(() => WindowsTlsClientIdentity.Import([1], "must-not-be-accessed", DeviceTransport.RequireRuntime));
        var nativeAccepted = JsonSerializer.SerializeToElement(new
        {
            result = "accepted", settled = true, nonExportable = true, observationCurrent = true,
            peerPolicyAttempted = true, peerPinMatched = true, peerPolicyAccepted = true,
            acceptedSockets = 1, keyManagerSelections = 1, installationStable = true,
        });
        NativeProof.ValidateObservedOutcome("wrong-server-pin", false, "peer_certificate_rejected", nativeAccepted);
        Check(true);
        Reject(() => NativeProof.ValidateObservedOutcome("wrong-server-pin", true, "peer_certificate_valid", nativeAccepted));
        Reject(() => NativeProof.ValidateObservedOutcome("wrong-server-pin", false, "tcp_connected", nativeAccepted));
        Reject(() => NativeProof.ValidateObservedOutcome("wrong-client", true, "peer_certificate_valid", nativeAccepted));
        CheckFrameDeadlines().GetAwaiter().GetResult();
        Check(DeviceClient.IsNonce(DeviceClient.Nonce()));
        Check(!DeviceClient.IsNonce(new string('A', 42) + "B"));
        Console.WriteLine("PASS: 38 synthetic Android adapter checks; no business or credential acquisition in this test");
        return 0;
    }

    private static async Task CheckFrameDeadlines()
    {
        using var bytes = new MemoryStream();
        await LinkFrames.Write(bytes, 1, "{}"u8.ToArray(), false, default);
        // Idle before the first byte may exceed two seconds without expiry.
        using var idle = new FragmentStream(bytes.ToArray(), [2200, 0, 0], [1, 11, 2]);
        Check((await LinkFrames.Read(idle, false, default)).Kind == 1);
        using var partial = new FragmentStream(bytes.ToArray(), [0, 1100, 1100], [1, 1, 10]);
        try { await LinkFrames.Read(partial, false, default); throw new Exception("partial_header_renewed"); }
        catch (OperationCanceledException) { Check(true); }
        using var body = new FragmentStream(bytes.ToArray(), [0, 0, 1100], [1, 11, 2]);
        using var stop = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));
        try { await LinkFrames.Read(body, false, stop.Token); throw new Exception("body_ignored_cancellation"); }
        catch (OperationCanceledException) { Check(true); }
    }
    private sealed class FragmentStream(byte[] bytes, int[] delays, int[] counts) : Stream
    {
        private int step, offset;
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        {
            if (offset == bytes.Length) return 0;
            await Task.Delay(delays[step], token);
            int count = Math.Min(buffer.Length, counts[step++]);
            bytes.AsMemory(offset, count).CopyTo(buffer); offset += count; return count;
        }
        public override bool CanRead => true;
        public override bool CanWrite => false;
        public override bool CanSeek => false;
        public override long Length => bytes.Length;
        public override long Position { get => offset; set => throw new NotSupportedException(); }
        public override void Flush() => throw new NotSupportedException();
        public override int Read(byte[] b, int o, int c) => throw new NotSupportedException();
        public override void Write(byte[] b, int o, int c) => throw new NotSupportedException();
        public override long Seek(long o, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long length) => throw new NotSupportedException();
    }
}
