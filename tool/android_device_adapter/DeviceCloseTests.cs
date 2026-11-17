using System.Text.Json;
using System.Threading.Channels;

namespace Shiroha.AndroidDevice;

internal static class DeviceCloseTests
{
    internal static async Task Run()
    {
        foreach (string scenario in new[] { "normal", "notice", "duplicate", "nonce", "eof", "shutdown", "business", "heartbeat", "invalid-pong", "pending-pong" })
        {
            using var input = new TestStream();
            using var tls = new TestStream();
            using var output = new MemoryStream();
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(scenario == "pending-pong" ? 20 : 3));
            int notices = 0;
            bool shutdown = false, failed = false;
            string peerPing = DeviceClient.Nonce();
            string? finalNonce = null;
            bool pongWritten = false;
            tls.Flushed = async bytes =>
            {
                using var encoded = new MemoryStream(bytes);
                var frame = await LinkFrames.Read(encoded, false, deadline.Token);
                using var value = LinkFrames.StrictObject(frame.Body);
                string type = DeviceClient.Text(value.RootElement, "type");
                string nonce = DeviceClient.Text(value.RootElement, "nonce");
                if (type == "ping" && scenario == "pending-pong")
                {
                    await tls.Feed(1, new { type = "closing", connectionId = "original", nonce = DeviceClient.Nonce() });
                    await tls.Feed(1, new { type = "pong", connectionId = "original", nonce });
                    return;
                }
                if (type == "closing") finalNonce = nonce;
                else if (type == "pong" && nonce == peerPing) pongWritten = true;
                else throw new Exception("unexpected_control");
                if (finalNonce != null && (scenario != "heartbeat" || pongWritten))
                    await tls.Feed(1, new { type = "closed", connectionId = "original",
                        nonce = scenario == "nonce" ? DeviceClient.Nonce() : finalNonce });
            };
            if (scenario == "normal") input.End();
            else if (scenario != "pending-pong")
            {
                await tls.Feed(1, new { type = "closing", connectionId = "original", nonce = DeviceClient.Nonce() });
                if (scenario == "duplicate")
                    await tls.Feed(1, new { type = "closing", connectionId = "original", nonce = DeviceClient.Nonce() });
                if (scenario == "business")
                    await tls.Feed(2, new { jsonrpc = "2.0", id = 1, result = new { } });
                if (scenario == "heartbeat")
                    await tls.Feed(1, new { type = "ping", connectionId = "original", nonce = peerPing });
                if (scenario == "invalid-pong")
                    await tls.Feed(1, new { type = "pong", connectionId = "original", nonce = DeviceClient.Nonce() });
            }
            try
            {
                await DeviceTransport.Pump(input, output, tls, "original", 3, deadline.Token,
                    () => { }, () =>
                    {
                        shutdown = true;
                        if (scenario == "shutdown") throw new IOException("synthetic_shutdown");
                        if (scenario == "eof") tls.Bytes(new byte[] { 1 });
                        tls.End();
                        return Task.CompletedTask;
                    }, () => { input.End(); tls.End(); },
                    () => { notices++; input.End(); });
            }
            catch (LinkFailure) { failed = true; }
            bool shouldPass = scenario is "normal" or "notice" or "heartbeat" or "pending-pong";
            if (failed == shouldPass || shouldPass && !shutdown || output.Length != 0 ||
                scenario == "notice" && notices != 1)
                throw new Exception("close_fixture_failed");
        }
        Console.WriteLine("PASS: 10 original-stream close cases");
    }

    // A single deterministic duplex byte stream. The production frame codec,
    // pumps, cancellation and close matching all run unchanged.
    private sealed class TestStream : Stream
    {
        private readonly Channel<byte[]> incoming = Channel.CreateUnbounded<byte[]>();
        private readonly MemoryStream written = new();
        private byte[] current = [];
        private int offset;
        internal Func<byte[], Task>? Flushed;
        internal void Bytes(byte[] bytes) => incoming.Writer.TryWrite(bytes);
        internal void End() => incoming.Writer.TryComplete();
        internal async Task Feed(byte kind, object value)
        {
            using var frame = new MemoryStream();
            await LinkFrames.Write(frame, kind, JsonSerializer.SerializeToUtf8Bytes(value), false, default);
            Bytes(frame.ToArray());
        }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        {
            while (offset == current.Length)
            {
                if (!await incoming.Reader.WaitToReadAsync(token)) return 0;
                if (!incoming.Reader.TryRead(out var next)) continue;
                current = next; offset = 0;
            }
            int count = Math.Min(buffer.Length, current.Length - offset);
            current.AsMemory(offset, count).CopyTo(buffer);
            offset += count;
            return count;
        }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> bytes, CancellationToken token = default) =>
            written.WriteAsync(bytes, token);
        public override async Task FlushAsync(CancellationToken token)
        {
            byte[] bytes = written.ToArray(); written.SetLength(0);
            if (Flushed != null) await Flushed(bytes);
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing) { End(); written.Dispose(); }
            base.Dispose(disposing);
        }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() => throw new NotSupportedException();
        public override int Read(byte[] bytes, int offset, int count) => throw new NotSupportedException();
        public override void Write(byte[] bytes, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long length) => throw new NotSupportedException();
    }
}
