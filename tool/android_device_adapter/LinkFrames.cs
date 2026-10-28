using System.Buffers.Binary;
using System.Text;
using System.Text.Json;

namespace Shiroha.AndroidDevice;

internal static class LinkFrames
{
    internal const int RequestMax = 6324224, ResponseMax = 524288, ControlMax = 16384;
    private static readonly UTF8Encoding Utf8 = new(false, true);

    internal static int Length(ReadOnlySpan<byte> header, bool response)
    {
        if (header.Length != 12 || !header[..4].SequenceEqual("SHAD"u8) || header[4] != 1 ||
            header[6] != 0 || header[7] != 0 || header[5] is not (1 or 2))
            throw new LinkFailure("protocol_violation");
        uint length = BinaryPrimitives.ReadUInt32BigEndian(header[8..]);
        int limit = header[5] == 1 ? ControlMax : response ? ResponseMax : RequestMax;
        if (length == 0 || length > limit) throw new LinkFailure("resource_limit");
        return (int)length;
    }

    internal static async Task<(byte Kind, byte[] Body)> Read(Stream input, bool response, CancellationToken token)
    {
        byte[] header = new byte[12];
        // Idle has no partial-header deadline. Fragmentation never renews it.
        await input.ReadExactlyAsync(header.AsMemory(0, 1), token);
        using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(token))
        {
            long started = System.Diagnostics.Stopwatch.GetTimestamp();
            deadline.CancelAfter(TimeSpan.FromSeconds(2));
            await input.ReadExactlyAsync(header.AsMemory(1), deadline.Token);
            if (System.Diagnostics.Stopwatch.GetElapsedTime(started) >= TimeSpan.FromSeconds(2)) throw new LinkFailure("deadline_exceeded");
        }
        byte[] body = new byte[Length(header, response)];
        using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(token))
        {
            long started = System.Diagnostics.Stopwatch.GetTimestamp();
            deadline.CancelAfter(TimeSpan.FromSeconds(10));
            await input.ReadExactlyAsync(body, deadline.Token);
            if (System.Diagnostics.Stopwatch.GetElapsedTime(started) >= TimeSpan.FromSeconds(10)) throw new LinkFailure("deadline_exceeded");
        }
        _ = Utf8.GetCharCount(body);
        return (header[5], body);
    }

    internal static async Task Write(Stream output, byte kind, byte[] body, bool response, CancellationToken token)
    {
        byte[] header = new byte[12];
        "SHAD"u8.CopyTo(header);
        header[4] = 1; header[5] = kind;
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(8), body.Length);
        _ = Length(header, response);
        _ = Utf8.GetCharCount(body);
        await output.WriteAsync(header, token);
        await output.WriteAsync(body, token);
        await output.FlushAsync(token);
    }

    internal static JsonDocument StrictObject(byte[] bytes)
    {
        var reader = new Utf8JsonReader(bytes, new JsonReaderOptions { MaxDepth = 32 });
        var keys = new Stack<HashSet<string>>();
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.StartObject) keys.Push([]);
            else if (reader.TokenType == JsonTokenType.EndObject) keys.Pop();
            else if (reader.TokenType == JsonTokenType.PropertyName && !keys.Peek().Add(reader.GetString()!))
                throw new LinkFailure("protocol_violation");
        }
        var doc = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 32 });
        if (doc.RootElement.ValueKind != JsonValueKind.Object) { doc.Dispose(); throw new LinkFailure("protocol_violation"); }
        return doc;
    }

    internal static async Task<byte[]?> ReadStdioLine(Stream input, CancellationToken token)
    {
        // No ReadLineAsync: a hostile peer must not allocate an unbounded line.
        using var line = new MemoryStream();
        byte[] one = new byte[1];
        while (await input.ReadAsync(one, token) != 0)
        {
            if (one[0] == '\n')
            {
                byte[] bytes = line.ToArray();
                using var json = StrictObject(bytes);
                return bytes;
            }
            if (line.Length == RequestMax) throw new LinkFailure("resource_limit");
            line.WriteByte(one[0]);
        }
        if (line.Length != 0) throw new LinkFailure("protocol_violation");
        return null;
    }
}
