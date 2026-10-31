using System.Runtime.InteropServices;
using System.Text.Json;
using System.Diagnostics;

namespace Shiroha.AndroidDevice;

/// <summary>Installation and parent provenance only; no business authority.</summary>
internal sealed class LinkAdapterContext : IDisposable
{
    [DllImport("shiroha_link_native.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int shiroha_relay_open(uint role, out ulong handle);
    [DllImport("shiroha_link_native.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int shiroha_relay_state(ulong handle);
    [DllImport("shiroha_link_native.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int shiroha_relay_close(ulong handle);
    private readonly ulong parent;
    internal string Directory { get; }
    internal string Owner { get; }
    internal string Slot { get; }
    internal string Run { get; }
    internal string Resource { get; }
    internal bool Authenticated { get; private set; }
    private bool closed;

    internal LinkAdapterContext(string run, string resource)
    {
        Token(run); Token(resource);
        if (!OperatingSystem.IsWindows() || shiroha_relay_open(2, out parent) != 0 || parent == 0)
            throw new LinkFailure("runtime_not_authorized");
        try
        {
            using var file = new FileStream(Path.Combine(AppContext.BaseDirectory, "link-installation.json"),
                FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length is < 1 or > 16384) throw new LinkFailure("invalid_target");
            byte[] bytes = new byte[(int)file.Length]; file.ReadExactly(bytes);
            using var document = LinkFrames.StrictObject(bytes);
            var value = document.RootElement;
            DeviceClient.Fields(value, ["version", "stateDirectory", "slotDirectory", "slotRef",
                "connectorInstanceId", "adapterExecutable", "windowsClientExecutable"]);
            if (value.GetProperty("version").GetInt32() != 1) throw new LinkFailure("invalid_target");
            Directory = Absolute(DeviceClient.Text(value, "slotDirectory"));
            var executable = Absolute(DeviceClient.Text(value, "adapterExecutable"));
            if (!executable.Equals(Environment.ProcessPath, StringComparison.OrdinalIgnoreCase)) throw new LinkFailure("invalid_target");
            Owner = Token(DeviceClient.Text(value, "connectorInstanceId"));
            Slot = Token(DeviceClient.Text(value, "slotRef")); Run = run; Resource = resource;
            RequireCurrent();
            Emit(new { type = "owner", runId = Run, resourceId = Resource, processId = Environment.ProcessId,
                processStarted = Process.GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc().ToString(), slotRef = Slot });
        }
        catch { Dispose(); throw; }
    }
    internal static string Token(string value) => System.Text.RegularExpressions.Regex.IsMatch(value,
        "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$") ? value : throw new LinkFailure("invalid_target");
    private static string Absolute(string value)
    {
        if (!Path.IsPathFullyQualified(value) || !Path.GetFullPath(value).Equals(value, StringComparison.OrdinalIgnoreCase))
            throw new LinkFailure("invalid_target");
        return value;
    }
    internal void RequireCurrent()
    {
        if (closed || shiroha_relay_state(parent) != 0) throw new LinkFailure("runtime_not_authorized");
    }
    internal void RequireSlot() => SlotFence.RequireClaim(Directory, Owner, Slot);
    internal void RequireTarget(DeviceTarget target, string installation) =>
        SlotFence.RequireClaim(Directory, Owner, Slot, target, installation);
    internal void Ready(DeviceTarget target, string installation)
    {
        RequireCurrent();
        if (Authenticated) throw new LinkFailure("protocol_violation");
        Authenticated = true;
        Emit(new { type = "authenticated", runId = Run, resourceId = Resource,
            deviceIdentity = target.DeviceId, installationIdentity = installation, profileReference = target.ProfileId });
    }
    internal void Settled(string mode, DeviceTarget target, string installation)
    {
        // Original owner receipt, distinct from business result and delivery.
        using var guard = new FileStream(Path.Combine(Directory, "adapter.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        RequireSlot();
        if (File.Exists(Path.Combine(Directory, "native-client-key.pending"))) throw new LinkFailure("settlement_unknown");
        byte[] receipt = JsonSerializer.SerializeToUtf8Bytes(new { formatVersion = 1, runId = Run, resourceId = Resource,
            processId = Environment.ProcessId, processStarted = Process.GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc().ToString(),
            slotRef = Slot, owner = Owner, mode, target = new { deviceIdentity = target.DeviceId,
                installationIdentity = installation, profileReference = target.ProfileId },
            targetClose = true, tlsShutdown = true, keyRetired = true });
        string pending = Path.Combine(Directory, "link-settlement.pending"), destination = Path.Combine(Directory, "link-settlement.json");
        using (var file = new FileStream(pending, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { file.Write(receipt); file.Flush(true); }
        if (File.Exists(destination)) File.Replace(pending, destination, null); else File.Move(pending, destination);
        Emit(new { type = "settled", runId = Run, resourceId = Resource, mode, targetClose = true, tlsShutdown = true, keyRetired = true });
    }
    private static void Emit(object value)
    {
        try { Console.Error.WriteLine("SHIROHA_LINK_EVENT " + JsonSerializer.Serialize(value)); }
        catch (IOException) { /* The durable receipt survives the original pipe. */ }
    }
    public void Dispose()
    {
        if (closed) return; closed = true;
        if (shiroha_relay_close(parent) != 0) throw new LinkFailure("settlement_unknown");
    }
}

internal static class SlotFence
{
    // Called INSIDE the original adapter.lock, immediately before credential/key
    // acquisition. All updated legacy entries reject every migration phase.
    internal static void RequireLegacy(string directory)
    {
        if (File.Exists(Path.Combine(directory, "host-handoff.json")) ||
            File.Exists(Path.Combine(directory, "host-handoff.pending"))) throw new LinkFailure("handoff_required");
    }
    internal static void RequireClaim(string directory, string owner, string slot,
        DeviceTarget? target = null, string? installation = null)
    {
        if (File.Exists(Path.Combine(directory, "host-handoff.pending"))) throw new LinkFailure("handoff_required");
        using var file = new FileStream(Path.Combine(directory, "host-handoff.json"), FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length is < 1 or > 32768) throw new LinkFailure("handoff_required");
        byte[] bytes = new byte[(int)file.Length]; file.ReadExactly(bytes);
        using var doc = LinkFrames.StrictObject(bytes);
        RequireClaimRecord(doc.RootElement, owner, slot, target, installation);
    }
    internal static void RequireClaimRecord(JsonElement value, string owner, string slot,
        DeviceTarget? target = null, string? installation = null)
    {
        DeviceClient.Fields(value, ["formatVersion", "handoffId", "handoffRevision", "slotRef", "target",
            "oldOwnerInstance", "oldSelectionGeneration", "oldStateRevision", "oldStateDigest",
            "releaseRecordRef", "newOwner", "newLinkStateRevision", "phase"]);
        if (value.GetProperty("formatVersion").GetInt32() != 1 || DeviceClient.Text(value, "phase") != "CLAIMED" ||
            DeviceClient.Text(value, "newOwner") != owner || DeviceClient.Text(value, "slotRef") != slot)
            throw new LinkFailure("handoff_required");
        var binding = value.GetProperty("target");
        DeviceClient.Fields(binding, ["deviceIdentity", "installationIdentity", "profileReference"]);
        if (target != null && (DeviceClient.Text(binding, "deviceIdentity") != target.DeviceId ||
            DeviceClient.Text(binding, "installationIdentity") != installation ||
            DeviceClient.Text(binding, "profileReference") != target.ProfileId))
            throw new LinkFailure("device_mismatch");
    }
}
