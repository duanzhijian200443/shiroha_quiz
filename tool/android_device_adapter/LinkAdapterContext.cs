using System.Runtime.InteropServices;
using System.Text.Json;
using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;

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
    [DllImport("shiroha_link_native.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int shiroha_link_process_current(uint process, ulong started);
    private readonly ulong parent;
    private readonly JsonElement pairingInput;
    internal string Operation { get; }
    internal bool Initializing { get; }
    internal bool Registering { get; }
    internal bool Inspecting { get; }
    internal string Directory { get; }
    internal string Owner { get; }
    internal string Slot { get; }
    internal string Run { get; }
    internal string Resource { get; }
    internal bool Authenticated { get; private set; }
    private bool closed;

    internal LinkAdapterContext(string run, string resource, bool initializing = false, bool registering = false, bool inspecting = false)
    {
        Token(run); Token(resource); Initializing = initializing || registering; Registering = registering; Inspecting = inspecting;
        if (!OperatingSystem.IsWindows() || shiroha_relay_open(2, out parent) != 0 || parent == 0)
            throw new LinkFailure("runtime_not_authorized");
        try
        {
            using var file = new FileStream(Path.Combine(AppContext.BaseDirectory, registering ? "pairing-registration.json" : "link-installation.json"),
                FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length is < 1 or > 16384) throw new LinkFailure("invalid_target");
            byte[] bytes = new byte[(int)file.Length]; file.ReadExactly(bytes);
            using var document = LinkFrames.StrictObject(bytes);
            var value = document.RootElement;
            DeviceClient.Fields(value, registering ? ["version", "slotDirectory", "slotRef", "registrarInstanceId", "registrationOperationId", "registrationGeneration", "runId", "resourceId", "adapterExecutable", "pairingInput"] : ["version", "stateDirectory", "slotDirectory", "slotRef", "connectorInstanceId", "operationId", "adapterExecutable", "pairingInput"]);
            if (value.GetProperty("version").GetInt32() != (registering ? 1 : 2)) throw new LinkFailure("invalid_target");
            Directory = Absolute(DeviceClient.Text(value, "slotDirectory"));
            var executable = Absolute(DeviceClient.Text(value, "adapterExecutable"));
            if (!executable.Equals(Environment.ProcessPath, StringComparison.OrdinalIgnoreCase)) throw new LinkFailure("invalid_target");
            Owner = Token(DeviceClient.Text(value, registering ? "registrarInstanceId" : "connectorInstanceId"));
            Operation = Token(DeviceClient.Text(value, registering ? "registrationOperationId" : "operationId"));
            if (registering && (DeviceClient.Text(value, "runId") != run || DeviceClient.Text(value, "resourceId") != resource)) throw new LinkFailure("owner_conflict");
            pairingInput = value.GetProperty("pairingInput").Clone();
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
    internal void RequireSlot() => SlotFence.RequireOwner(Directory, Owner, Slot, Operation, Resource, Initializing, registering: Registering, inspecting: Inspecting);
    internal void RequireTarget(DeviceTarget target, string installation) =>
        SlotFence.RequireOwner(Directory, Owner, Slot, Operation, Resource, Initializing, target, installation, Registering, Inspecting);
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
        if (Registering) {
            ProtectedDeviceStore.Inspect(Directory, RequireCurrent, RequireSlot, (paired, digest) => {
                var binding = RegistrationCustody.CredentialBinding(paired);
                var receipt = JsonSerializer.SerializeToElement(new { formatVersion = 2, operationId = Operation, receiptRef = Resource, runId = Run, resourceId = Resource,
                    processId = Environment.ProcessId, processStarted = Process.GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc().ToString(), slotRef = Slot, owner = Owner, mode,
                    target = new { deviceIdentity = target.DeviceId, installationIdentity = installation, profileReference = target.ProfileId }, targetClose = true, tlsShutdown = true, keyRetired = true });
                RegistrationCustody.Produce(Directory, ReadRecord("slot-ownership.json"), receipt, binding.Revision, binding.ClientDigest, digest);
            });
            EmitInitialized(target, installation);
            return;
        }
        // Original owner receipt, distinct from business result and delivery.
        using var guard = new FileStream(Path.Combine(Directory, "adapter.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        RequireSlot();
        if (File.Exists(Path.Combine(Directory, "native-client-key.pending"))) throw new LinkFailure("settlement_unknown");
        byte[] receipt = JsonSerializer.SerializeToUtf8Bytes(new { formatVersion = 2, operationId = Operation, receiptRef = Resource, runId = Run, resourceId = Resource,
            processId = Environment.ProcessId, processStarted = Process.GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc().ToString(),
            slotRef = Slot, owner = Owner, mode, target = new { deviceIdentity = target.DeviceId,
                installationIdentity = installation, profileReference = target.ProfileId },
            targetClose = true, tlsShutdown = true, keyRetired = true });
        PublishSettlementReceipt(Directory, receipt);
        if (Initializing)
        {
            WriteOrigin(JsonSerializer.SerializeToElement(new { formatVersion = 1, slotRef = Slot,
                origin = "independent_adapter_pairing", operationId = Operation,
                target = new { deviceIdentity = target.DeviceId, installationIdentity = installation, profileReference = target.ProfileId },
                credentialSlotRef = "device.dpapi", resourceGeneration = Resource, settlementRef = Resource }));
            EmitInitialized(target, installation);
        }
        Emit(new { type = "settled", runId = Run, resourceId = Resource, mode, targetClose = true, tlsShutdown = true, keyRetired = true });
    }

    internal static void PublishSettlementReceipt(string directory, ReadOnlySpan<byte> receipt)
    {
        string pending = Path.Combine(directory, "link-settlement.pending");
        string destination = Path.Combine(directory, "link-settlement.json");
        using (var file = new FileStream(pending, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            file.Write(receipt);
            file.Flush(true);
        }
        // Both names are in the owned slot. Use a same-volume rename without
        // ReplaceFile's destination metadata merge or a pre-delete window.
        File.Move(pending, destination, overwrite: true);
    }

    private JsonElement ReadRecord(string name)
    {
        using var file = new FileStream(Path.Combine(Directory, name), FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length is < 1 or > 32768) throw new LinkFailure("recovery_required");
        byte[] bytes = new byte[(int)file.Length]; file.ReadExactly(bytes);
        using var parsed = LinkFrames.StrictObject(bytes);
        return parsed.RootElement.Clone();
    }
    private void WriteOrigin(JsonElement origin)
    {
        string pending = Path.Combine(Directory, "adapter-origin.pending");
        string destination = Path.Combine(Directory, "adapter-origin.json");
        if (File.Exists(destination))
        {
            if (ReadRecord("adapter-origin.json").GetRawText() != origin.GetRawText()) throw new LinkFailure("owner_conflict");
            return;
        }
        if (File.Exists(pending)) throw new LinkFailure("recovery_required");
        using (var file = new FileStream(pending, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        { file.Write(JsonSerializer.SerializeToUtf8Bytes(origin)); file.Flush(true); }
        File.Move(pending, destination, false);
    }
    private void EmitInitialized(DeviceTarget target, string installation) => Emit(new {
        type = "initialization-complete", runId = Run, resourceId = Resource,
        target = new { deviceIdentity = target.DeviceId, installationIdentity = installation, profileReference = target.ProfileId }
    });
    internal bool PrepareOrInspectPairing()
    {
        if (!Initializing) throw new LinkFailure("runtime_not_authorized");
        RequireCurrent(); RequireSlot();
        foreach (string name in new[] { "native-client-key.pending", "device.pending", "link-settlement.pending", "adapter-origin.pending" })
            if (File.Exists(Path.Combine(Directory, name))) throw new LinkFailure("recovery_required");
        if (File.Exists(Path.Combine(Directory, "device.dpapi")))
        {
            if (Registering) throw new LinkFailure("registration_incomplete");
            byte[] clear = ProtectedDeviceStore.Read(Directory, RequireCurrent, RequireSlot);
            try
            {
                using var doc = LinkFrames.StrictObject(clear);
                var paired = doc.RootElement;
                if (DeviceClient.Text(paired, "purpose") != "android-read") throw new LinkFailure("initialization_incomplete");
                var target = new DeviceTarget(DeviceClient.Text(paired, "deviceId"), DeviceClient.Text(paired, "certificateDigest"),
                    DeviceClient.Text(paired, "profileId"), IPAddress.Parse(DeviceClient.Text(paired, "address")), paired.GetProperty("port").GetInt32());
                target.Validate();
                string installation = DeviceClient.Text(paired, "installationId");
                using var guard = new FileStream(Path.Combine(Directory, "adapter.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                RequireSlot();
                var receipt = ReadRecord("link-settlement.json");
                ValidateInitialReceipt(receipt, Slot, target, installation);
                var originalProcess = receipt.GetProperty("processId").GetUInt32();
                if (!ulong.TryParse(DeviceClient.Text(receipt, "processStarted"), out var started) ||
                    shiroha_link_process_current(originalProcess, started) != 0) throw new LinkFailure("recovery_required");
                if (!File.Exists(Path.Combine(Directory, "adapter-origin.json")))
                {
                    var attempt = ReadRecord("adapter-pairing-attempt.json");
                    if (DeviceClient.Text(attempt, "operationId") != Operation ||
                        DeviceClient.Text(receipt, "operationId") != Operation ||
                        DeviceClient.Text(attempt, "runId") != DeviceClient.Text(receipt, "runId") ||
                        DeviceClient.Text(attempt, "resourceId") != DeviceClient.Text(receipt, "resourceId"))
                        throw new LinkFailure("legacy_status_unknown");
                    WriteOrigin(JsonSerializer.SerializeToElement(new { formatVersion = 1, slotRef = Slot,
                        origin = "independent_adapter_pairing", operationId = Operation, target = receipt.GetProperty("target"),
                        credentialSlotRef = "device.dpapi", resourceGeneration = DeviceClient.Text(receipt, "resourceId"),
                        settlementRef = DeviceClient.Text(receipt, "receiptRef") }));
                }
                var origin = ReadRecord("adapter-origin.json");
                DeviceClient.Fields(origin, ["formatVersion", "slotRef", "origin", "operationId", "target", "credentialSlotRef", "resourceGeneration", "settlementRef"]);
                if (origin.GetProperty("formatVersion").GetInt32() != 1 || DeviceClient.Text(origin, "slotRef") != Slot ||
                    DeviceClient.Text(origin, "origin") != "independent_adapter_pairing" || DeviceClient.Text(origin, "credentialSlotRef") != "device.dpapi" ||
                    DeviceClient.Text(origin, "operationId") != DeviceClient.Text(receipt, "operationId") ||
                    DeviceClient.Text(origin, "resourceGeneration") != DeviceClient.Text(receipt, "resourceId") ||
                    DeviceClient.Text(origin, "settlementRef") != DeviceClient.Text(receipt, "receiptRef") ||
                    origin.GetProperty("target").GetRawText() != receipt.GetProperty("target").GetRawText()) throw new LinkFailure("legacy_status_unknown");
                EmitInitialized(target, installation);
                return true;
            }
            finally { CryptographicOperations.ZeroMemory(clear); }
        }
        // No historical record is created by an installer assertion. This record
        // is written by the original adapter before its first credential exists.
        DeviceClient.Fields(pairingInput, ["address", "deviceId", "certificateDigest"]);
        var hint = new DeviceTarget(DeviceClient.Text(pairingInput, "deviceId"), DeviceClient.Text(pairingInput, "certificateDigest"),
            "00000000-0000-4000-8000-000000000001", IPAddress.Parse(DeviceClient.Text(pairingInput, "address")), 46443);
        hint.Validate();
        using (var attempt = new FileStream(Path.Combine(Directory, "adapter-pairing-attempt.json"), FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            attempt.Write(JsonSerializer.SerializeToUtf8Bytes(new { formatVersion = 1, operationId = Operation, runId = Run, resourceId = Resource }));
            attempt.Flush(true);
        }
        byte[] key = ProtectedDeviceStore.CreateClientIdentity(RequireCurrent);
        byte[] configuration = [];
        try
        {
            configuration = JsonSerializer.SerializeToUtf8Bytes(new { purpose = "link-pairing", clientPfx = Convert.ToBase64String(key),
                deviceId = hint.DeviceId, certificateDigest = hint.CertificateDigest, installationId = (string?)null,
                address = hint.Address.ToString(), port = hint.Port });
            ProtectedDeviceStore.Create(Directory, configuration, RequireCurrent, RequireSlot);
        }
        finally { CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(configuration); }
        return false;
    }
    internal void InspectRegistration()
    {
        if (!Inspecting) throw new LinkFailure("runtime_not_authorized");
        ProtectedDeviceStore.Inspect(Directory, RequireCurrent, RequireSlot, (paired, digest) => {
            var custody = ReadRecord("slot-ownership.json");
            RegistrationCustody.Verify(Directory, custody, paired, digest);
            var receipt = ReadRecord("registration-receipt.json");
            var target = new DeviceTarget(DeviceClient.Text(paired, "deviceId"), DeviceClient.Text(paired, "certificateDigest"),
                DeviceClient.Text(paired, "profileId"), IPAddress.Parse(DeviceClient.Text(paired, "address")), paired.GetProperty("port").GetInt32());
            target.Validate();
            string installation = DeviceClient.Text(paired, "installationId");
            ValidateInitialReceipt(receipt, Slot, target, installation);
            if (!ulong.TryParse(DeviceClient.Text(receipt, "processStarted"), out var started) ||
                shiroha_link_process_current(receipt.GetProperty("processId").GetUInt32(), started) != 0) throw new LinkFailure("recovery_required");
            EmitInitialized(target, installation);
        });
    }
    internal static void ValidateInitialReceipt(JsonElement receipt, string slot, DeviceTarget target, string installation)
    {
        DeviceClient.Fields(receipt, ["formatVersion", "operationId", "receiptRef", "runId", "resourceId", "processId", "processStarted", "slotRef", "owner", "mode", "target", "targetClose", "tlsShutdown", "keyRetired"]);
        if (receipt.GetProperty("formatVersion").GetInt32() != 2 || DeviceClient.Text(receipt, "slotRef") != slot ||
            DeviceClient.Text(receipt, "mode") != "pairing" || !receipt.GetProperty("targetClose").GetBoolean() ||
            !receipt.GetProperty("tlsShutdown").GetBoolean() || !receipt.GetProperty("keyRetired").GetBoolean()) throw new LinkFailure("recovery_required");
        var binding = receipt.GetProperty("target");
        DeviceClient.Fields(binding, ["deviceIdentity", "installationIdentity", "profileReference"]);
        if (DeviceClient.Text(binding, "deviceIdentity") != target.DeviceId || DeviceClient.Text(binding, "installationIdentity") != installation ||
            DeviceClient.Text(binding, "profileReference") != target.ProfileId) throw new LinkFailure("device_mismatch");
        foreach (var name in new[] { "operationId", "receiptRef", "runId", "resourceId", "owner", "processStarted" }) Token(DeviceClient.Text(receipt, name));
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
    internal static void RequireLegacy(string directory)
    {
        foreach (var name in new[] { "host-handoff.json", "host-handoff.pending", "slot-ownership.json", "slot-ownership.pending" })
            if (File.Exists(Path.Combine(directory, name))) throw new LinkFailure("handoff_required");
    }
    internal static void RequireOwner(string directory, string owner, string slot, string operation, string resource,
        bool initializing, DeviceTarget? target = null, string? installation = null, bool registering = false, bool inspecting = false)
    {
        foreach (var name in new[] { "host-handoff.json", "host-handoff.pending", "slot-ownership.pending" })
            if (File.Exists(Path.Combine(directory, name))) throw new LinkFailure("legacy_status_unknown");
        using var file = new FileStream(Path.Combine(directory, "slot-ownership.json"), FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length is < 1 or > 32768) throw new LinkFailure("recovery_required");
        byte[] bytes = new byte[(int)file.Length]; file.ReadExactly(bytes);
        using var doc = LinkFrames.StrictObject(bytes);
        RequireOwnerRecord(doc.RootElement, owner, slot, operation, resource, initializing, target, installation, registering, inspecting);
    }
    internal static void RequireOwnerRecord(JsonElement value, string owner, string slot, string operation, string resource,
        bool initializing, DeviceTarget? target = null, string? installation = null, bool registering = false, bool inspecting = false)
    {
        if (value.GetProperty("formatVersion").GetInt32() == 2) {
            RegistrationCustody.RequireOwner(value, owner, slot, operation, resource, registering, inspecting, initializing, target, installation);
            return;
        }
        if (registering || inspecting) throw new LinkFailure("owner_conflict");
        DeviceClient.Fields(value, ["formatVersion", "slotRef", "operationId", "initializationSource", "ownershipState", "ownerKind", "ownerInstanceId", "ownerGeneration",
            "verifiedInstallationBinding", "adapterCredentialSlotRef", "resourceGeneration", "lastSettlementRef", "lastSettlementState", "revision"]);
        if (value.GetProperty("formatVersion").GetInt32() != 1 || DeviceClient.Text(value, "ownerKind") != "independent_link" ||
            DeviceClient.Text(value, "ownerInstanceId") != owner || DeviceClient.Text(value, "slotRef") != slot || DeviceClient.Text(value, "operationId") != operation ||
            DeviceClient.Text(value, "ownershipState") != (initializing ? "UNCLAIMED" : "LINK_OWNED")) throw new LinkFailure("owner_conflict");
        if (!initializing && (value.GetProperty("ownerGeneration").ValueKind != JsonValueKind.String ||
            DeviceClient.Text(value, "ownerGeneration") != operation || DeviceClient.Text(value, "resourceGeneration") != resource ||
            DeviceClient.Text(value, "adapterCredentialSlotRef") != "device.dpapi"))
            throw new LinkFailure("owner_conflict");
        var binding = value.GetProperty("verifiedInstallationBinding");
        if (binding.ValueKind == JsonValueKind.Null)
        {
            if (!initializing) throw new LinkFailure("device_mismatch");
            return;
        }
        DeviceClient.Fields(binding, ["deviceIdentity", "installationIdentity", "profileReference"]);
        if (target != null && (DeviceClient.Text(binding, "deviceIdentity") != target.DeviceId ||
            DeviceClient.Text(binding, "installationIdentity") != installation || DeviceClient.Text(binding, "profileReference") != target.ProfileId))
            throw new LinkFailure("device_mismatch");
    }
}
