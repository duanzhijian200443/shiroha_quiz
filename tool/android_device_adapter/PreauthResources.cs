using System.Diagnostics;
using System.Text.Json;

namespace Shiroha.AndroidDevice;

/// <summary>Facts recorded only by original resource acquisition/disposal sites.
/// A TLS session, partial import, or any failed cleanup can never qualify.</summary>
internal sealed class PreauthResources
{
    internal bool KeyStarted, KeyRetired, SocketStarted, SocketClosed;
    internal bool TlsStarted, TlsClosed, TlsEstablished, PeerObserved, CleanupFailed;
    internal string? Classification => CleanupFailed || TlsEstablished || PeerObserved ||
        KeyStarted && !KeyRetired || SocketStarted && !SocketClosed || TlsStarted && !TlsClosed
        ? null : !KeyStarted && !SocketStarted && !TlsStarted ? "not-acquired" : "released";
    internal object Receipt(string operation, string owner, string slot, string run, string resource, string stage, JsonElement target)
    {
        if (Classification == null || stage is not ("configuration" or "protected-configuration" or "client-key" or "tls"))
            throw new LinkFailure("settlement_unknown");
        return new {
            formatVersion = 1, kind = "preauth-failure", operationId = operation, owner, ownerGeneration = operation,
            slotRef = slot, runId = run, resourceId = resource, receiptRef = resource,
            processId = Environment.ProcessId, processStarted = Process.GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc().ToString(),
            mode = "enable-proof", stage, resources = Classification,
            tlsEstablished = false, peerObserved = false, socketClosed = true, tlsClosed = true, keyRetired = true, pendingClear = true, target
        };
    }
}
