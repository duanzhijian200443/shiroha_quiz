#if DEBUG
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;

namespace Shiroha.AndroidDevice;

/// <summary>Explicit local-only resource regression. No saved credentials, phone,
/// native admission bypass in production, pairing, or Application authority.</summary>
internal static class PreauthNativeFixture
{
    internal static async Task<int> Run(string directory, string scenario, string run, string resource)
    {
        if (!OperatingSystem.IsWindows()) return 79;
        // Confine this test-only entry to fresh fixture directories in this checkout.
        DirectoryInfo? repository = new(AppContext.BaseDirectory);
        while (repository != null && !File.Exists(Path.Combine(repository.FullName, "pubspec.yaml"))) repository = repository.Parent;
        if (repository == null || !Path.GetFullPath(directory).StartsWith(
            Path.Combine(repository.FullName, "build", "link-preauth-native") + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
            scenario is not ("not-acquired" or "tcp-failure" or "tls-deadline" or "pending" or "publish-interrupted" or "tls-close-failed" or "cng-delete-failed" or "socket-close-failed")) return 79;
        LinkAdapterContext.Token(run); LinkAdapterContext.Token(resource);
        var targetBinding = JsonSerializer.SerializeToElement(new {
            deviceIdentity = new string('a', 64), installationIdentity = "installation", profileReference = "profile"
        });
        void Emit(object value) => Console.Error.WriteLine("SHIROHA_LINK_EVENT " + JsonSerializer.Serialize(value));
        Emit(new { type = "owner", runId = run, resourceId = resource, processId = Environment.ProcessId,
            processStarted = Process.GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc().ToString(), slotRef = "phone" });
        // The original supervisor must observe creation identity before even the
        // no-resource child exits. This is fixture synchronization, never clean evidence.
        await Console.OpenStandardInput().CopyToAsync(Stream.Null);
        var resources = new PreauthResources();
        string phase = "fixture";
        try
        {
            if (scenario != "not-acquired")
            {
                phase = "endpoint";
                var local = NetworkInterface.GetAllNetworkInterfaces()
                    .SelectMany(n => n.GetIPProperties().UnicastAddresses)
                    .Select(a => a.Address).FirstOrDefault(DeviceTarget.PrivateV4)
                    ?? throw new LinkFailure("invalid_target");
                // The endpoint is bound on this computer; never a device address.
                var listener = new TcpListener(local, 0);
                listener.Start();
                int port = ((IPEndPoint)listener.LocalEndpoint).Port;
                Task? peer = null;
                if (scenario == "tcp-failure") listener.Stop();
                else peer = Task.Run(async () => {
                    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
                    using var socket = await listener.AcceptTcpClientAsync(timeout.Token);
                    var buffer = new byte[4096];
                    while (await socket.GetStream().ReadAsync(buffer, timeout.Token) != 0) { }
                });
                phase = "certificate";
                byte[] pfx = ProtectedDeviceStore.CreateClientIdentity(() => { });
                try
                {
                    phase = "client-key";
                    using var identity = WindowsTlsClientIdentity.Import(pfx, directory, () => { }, () => { }, resources,
                        scenario == "cng-delete-failed" ? key => { key.Delete(); throw new CryptographicException(); } : null);
                    phase = "tls";
                    var target = new DeviceTarget(new string('a', 64), new string('b', 64), "00000000-0000-4000-8000-000000000001", local, port);
                    using var deadline = new CancellationTokenSource(TimeSpan.FromMilliseconds(350));
                    try
                    {
                        if (scenario == "tls-close-failed") {
                            using var socket = new TcpClient();
                            resources.SocketStarted = true;
                            try {
                                await socket.ConnectAsync(local, port, deadline.Token);
                                using var tls = await DeviceTransport.AuthenticatePinned(new FailedDispose(socket.GetStream()), target,
                                    identity.Certificate, deadline.Token, () => { }, preauth: resources);
                            } finally { socket.Dispose(); resources.SocketClosed = true; }
                        } else {
                            using var connection = await DeviceTransport.OpenPinned(target, identity.Certificate, deadline.Token, () => { }, preauth: resources,
                                createTcp: scenario == "socket-close-failed" ? () => new FailedSocket() : null);
                        }
                        throw new LinkFailure("fixture_unexpected_success");
                    }
                    catch (SocketException) when (scenario == "tcp-failure") { }
                    catch (OperationCanceledException) { }
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(pfx);
                    listener.Stop();
                    if (peer != null) await peer;
                }
                if (scenario == "tcp-failure" && resources.TlsStarted || scenario != "tcp-failure" && !resources.TlsStarted) throw new LinkFailure("fixture_wrong_boundary");
                if (resources.Classification != "released" || File.Exists(Path.Combine(directory, "native-client-key.pending")))
                    throw new LinkFailure("settlement_unknown");
            }
            if (scenario == "pending") { File.WriteAllText(Path.Combine(directory, "native-client-key.pending"), "fixture-pending"); return 79; }
            var receipt = resources.Receipt("operation", "connector", "phone", run, resource,
                scenario == "not-acquired" ? "protected-configuration" : "tls", targetBinding);
            if (scenario == "publish-interrupted")
                File.WriteAllText(Path.Combine(directory, $"link-preauth-{resource}.json.pending"), "{");
            LinkAdapterContext.PublishPreauthReceipt(directory, resource, JsonSerializer.SerializeToUtf8Bytes(receipt));
            Emit(new { type = "preauth-failure-settled", runId = run, resourceId = resource, version = 1 });
            return 80;
        }
        catch (Exception error) {
            File.WriteAllText(Path.Combine(directory, "fixture-result.json"), JsonSerializer.Serialize(new {
                phase, category = error is LinkFailure link ? link.Code : error.GetType().Name,
                resources.KeyStarted, resources.KeyRetired, resources.SocketStarted, resources.SocketClosed,
                resources.TlsStarted, resources.TlsClosed, resources.TlsEstablished, resources.PeerObserved, resources.CleanupFailed,
            }));
            return 79;
        }
    }
    private sealed class FailedSocket() : TcpClient(AddressFamily.InterNetwork)
    {
        protected override void Dispose(bool disposing) { base.Dispose(disposing); throw new IOException("fixture-socket-close-failed"); }
    }
    private sealed class FailedDispose(Stream inner) : Stream
    {
        public override bool CanRead => inner.CanRead;
        public override bool CanWrite => inner.CanWrite;
        public override bool CanSeek => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() => inner.Flush();
        public override Task FlushAsync(CancellationToken token) => inner.FlushAsync(token);
        public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default) => inner.ReadAsync(buffer, token);
        public override void Write(byte[] buffer, int offset, int count) => inner.Write(buffer, offset, count);
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken token = default) => inner.WriteAsync(buffer, token);
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        protected override void Dispose(bool disposing) { if (disposing) inner.Dispose(); throw new IOException("fixture-close-failed"); }
    }

}

#endif
