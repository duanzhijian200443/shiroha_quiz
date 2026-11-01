using System.Text.Json;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace Shiroha.AndroidDevice;

/// <summary>Original trusted producer, not an installer assertion or signing service.</summary>
internal static class RegistrationCustody
{
    internal static void ObserveFingerprint(string directory, string operation, string run, string resource, string digest)
    {
        if (digest.Length != 64 || digest.Any(c => !"0123456789abcdef".Contains(c))) throw new LinkFailure("protocol_violation");
        Publish(directory, "registration-observation.json", JsonSerializer.SerializeToElement(new {
            formatVersion = 1, kind = "pairing-comparison-only", operationId = operation, runId = run, resourceId = resource,
            clientCertificateDigest = digest }));
    }
    internal static readonly string[] SourceFiles = ["registration-attempt.json", "registration-receipt.json", "registration-origin.json", "registration-joined.json"];
    internal static JsonElement Read(string directory, string name)
    {
        using var file = new FileStream(Path.Combine(directory, name), FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length is < 1 or > 32768) throw new LinkFailure("recovery_required");
        byte[] bytes = new byte[(int)file.Length]; file.ReadExactly(bytes);
        using var document = LinkFrames.StrictObject(bytes); return document.RootElement.Clone();
    }
    internal static string Digest(string directory, string name)
    {
        using var file = new FileStream(Path.Combine(directory, name), FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length is < 1 or > 65536) throw new LinkFailure("recovery_required");
        return Convert.ToHexStringLower(SHA256.HashData(file));
    }
    internal static void Publish(string directory, string name, JsonElement value)
    {
        string destination = Path.Combine(directory, name), pending = destination + ".pending";
        if (File.Exists(destination) || File.Exists(pending)) throw new LinkFailure("recovery_required");
        using (var file = new FileStream(pending, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        { file.Write(JsonSerializer.SerializeToUtf8Bytes(value)); file.Flush(true); }
        File.Move(pending, destination, false);
    }
    internal static void RequireRecord(JsonElement value)
    {
        DeviceClient.Fields(value, ["formatVersion", "slotRef", "operationId", "initializationSource", "ownershipState", "ownerKind", "ownerInstanceId", "ownerGeneration", "verifiedInstallationBinding", "adapterCredentialSlotRef", "resourceGeneration", "lastSettlementRef", "lastSettlementState", "revision", "registration", "sourceDigest", "adoption"]);
        if (value.GetProperty("formatVersion").GetInt32() != 2 || DeviceClient.Text(value, "initializationSource") != "registered_pairing" || value.GetProperty("revision").GetInt32() < 0) throw new LinkFailure("owner_conflict");
        var registration = value.GetProperty("registration");
        DeviceClient.Fields(registration, ["registrarInstanceId", "operationId", "generation", "runId", "resourceId"]);
        foreach (var property in registration.EnumerateObject()) LinkAdapterContext.Token(property.Value.GetString()!);
        string phase = DeviceClient.Text(value, "ownershipState");
        bool registrar = phase is "REGISTERING" or "SEALED";
        if (!registrar && phase is not ("ADOPT_PENDING" or "LINK_OWNED")) throw new LinkFailure("owner_conflict");
        if (DeviceClient.Text(value, "ownerKind") != (registrar ? "independent_registrar" : "independent_link")) throw new LinkFailure("owner_conflict");
        if (registrar)
        {
            if (DeviceClient.Text(value, "ownerInstanceId") != DeviceClient.Text(registration, "registrarInstanceId") ||
                DeviceClient.Text(value, "operationId") != DeviceClient.Text(registration, "operationId") ||
                DeviceClient.Text(value, "ownerGeneration") != DeviceClient.Text(registration, "generation") ||
                value.GetProperty("adoption").ValueKind != JsonValueKind.Null) throw new LinkFailure("owner_conflict");
        }
        else
        {
            var adoption = value.GetProperty("adoption");
            DeviceClient.Fields(adoption, ["connectorInstanceId", "operationId"]);
            if (DeviceClient.Text(adoption, "connectorInstanceId") != DeviceClient.Text(value, "ownerInstanceId") ||
                DeviceClient.Text(adoption, "operationId") != DeviceClient.Text(value, "operationId") ||
                DeviceClient.Text(value, "ownerGeneration") != DeviceClient.Text(value, "operationId")) throw new LinkFailure("owner_conflict");
        }
        if (phase == "REGISTERING")
        {
            if (value.GetProperty("sourceDigest").ValueKind != JsonValueKind.Null ||
                value.GetProperty("verifiedInstallationBinding").ValueKind != JsonValueKind.Null ||
                value.GetProperty("adapterCredentialSlotRef").ValueKind != JsonValueKind.Null ||
                value.GetProperty("lastSettlementRef").ValueKind != JsonValueKind.Null ||
                DeviceClient.Text(value, "lastSettlementState") != "UNKNOWN") throw new LinkFailure("owner_conflict");
        }
        else if (DeviceClient.Text(value, "adapterCredentialSlotRef") != "device.dpapi" ||
            value.GetProperty("verifiedInstallationBinding").ValueKind != JsonValueKind.Object ||
            DeviceClient.Text(value, "sourceDigest").Length != 64) throw new LinkFailure("owner_conflict");
        if (phase != "LINK_OWNED" && DeviceClient.Text(value, "resourceGeneration") != DeviceClient.Text(registration, "resourceId") ||
            phase is "SEALED" or "ADOPT_PENDING" && DeviceClient.Text(value, "lastSettlementState") != "CLEAN") throw new LinkFailure("owner_conflict");
    }
    internal static void RequireOwner(JsonElement value, string owner, string slot, string operation, string resource,
        bool registering, bool inspecting, bool initializing, DeviceTarget? target, string? installation)
    {
        RequireRecord(value);
        if (DeviceClient.Text(value, "slotRef") != slot) throw new LinkFailure("owner_conflict");
        string phase = DeviceClient.Text(value, "ownershipState");
        if (inspecting)
        { if (phase != "SEALED") throw new LinkFailure("owner_conflict"); }
        else if (registering)
        {
            var registration = value.GetProperty("registration");
            if (phase != "REGISTERING" || DeviceClient.Text(value, "ownerInstanceId") != owner ||
                DeviceClient.Text(value, "operationId") != operation || DeviceClient.Text(registration, "resourceId") != resource)
                throw new LinkFailure("owner_conflict");
        }
        else if (initializing || phase != "LINK_OWNED" || DeviceClient.Text(value, "ownerInstanceId") != owner ||
            DeviceClient.Text(value, "operationId") != operation || DeviceClient.Text(value, "resourceGeneration") != resource)
            throw new LinkFailure("owner_conflict");
        if (target != null)
        {
            var binding = value.GetProperty("verifiedInstallationBinding");
            if (binding.ValueKind == JsonValueKind.Null && registering) return;
            DeviceClient.Fields(binding, ["deviceIdentity", "installationIdentity", "profileReference"]);
            if (DeviceClient.Text(binding, "deviceIdentity") != target.DeviceId || DeviceClient.Text(binding, "installationIdentity") != installation ||
                DeviceClient.Text(binding, "profileReference") != target.ProfileId) throw new LinkFailure("device_mismatch");
        }
    }

    internal static (int Revision, string ClientDigest) CredentialBinding(JsonElement paired)
    {
        if (DeviceClient.Text(paired, "purpose") != "android-read" || paired.GetProperty("associationRevision").GetInt32() < 1) throw new LinkFailure("credential_store_corrupt");
        byte[] pfx = Convert.FromBase64String(DeviceClient.Text(paired, "clientPfx"));
        try {
            using var certificate = X509CertificateLoader.LoadPkcs12(pfx, null, X509KeyStorageFlags.EphemeralKeySet);
            if (!certificate.HasPrivateKey) throw new LinkFailure("credential_store_corrupt");
            return (paired.GetProperty("associationRevision").GetInt32(), Convert.ToHexStringLower(SHA256.HashData(certificate.RawData)));
        } finally { CryptographicOperations.ZeroMemory(pfx); }
    }

    internal static void Produce(string directory, JsonElement custody, JsonElement receipt, int associationRevision,
        string clientDigest, string credentialDigest)
    {
        RequireRecord(custody);
        var registration = custody.GetProperty("registration");
        if (DeviceClient.Text(custody, "ownershipState") != "REGISTERING" || associationRevision < 1 || clientDigest.Length != 64 || credentialDigest.Length != 64 ||
            DeviceClient.Text(receipt, "operationId") != DeviceClient.Text(registration, "operationId") ||
            DeviceClient.Text(receipt, "owner") != DeviceClient.Text(registration, "registrarInstanceId") ||
            DeviceClient.Text(receipt, "runId") != DeviceClient.Text(registration, "runId") ||
            DeviceClient.Text(receipt, "resourceId") != DeviceClient.Text(registration, "resourceId") ||
            DeviceClient.Text(receipt, "mode") != "pairing") throw new LinkFailure("owner_conflict");
        var attempt = Read(directory, "registration-attempt.json");
        DeviceClient.Fields(attempt, ["formatVersion", "slotRef", "registration"]);
        if (attempt.GetProperty("formatVersion").GetInt32() != 1 || DeviceClient.Text(attempt, "slotRef") != DeviceClient.Text(custody, "slotRef") ||
            attempt.GetProperty("registration").GetRawText() != registration.GetRawText()) throw new LinkFailure("owner_conflict");
        Publish(directory, "registration-receipt.json", receipt);
        Publish(directory, "registration-origin.json", JsonSerializer.SerializeToElement(new {
            formatVersion = 2, slotRef = DeviceClient.Text(custody, "slotRef"), origin = "independent_registrar_pairing", registration,
            target = receipt.GetProperty("target"), credentialSlotRef = "device.dpapi", credentialDigest, associationRevision,
            clientCertificateDigest = clientDigest, resourceGeneration = DeviceClient.Text(receipt, "resourceId"), settlementRef = DeviceClient.Text(receipt, "receiptRef") }));
    }

    internal static void RequireCredentialBinding(JsonElement origin, JsonElement paired, string credentialDigest)
    {
        var binding = CredentialBinding(paired);
        if (DeviceClient.Text(origin, "credentialDigest") != credentialDigest ||
            origin.GetProperty("associationRevision").GetInt32() != binding.Revision ||
            DeviceClient.Text(origin, "clientCertificateDigest") != binding.ClientDigest) throw new LinkFailure("credential_changed");
        var target = origin.GetProperty("target");
        if (DeviceClient.Text(target, "deviceIdentity") != DeviceClient.Text(paired, "deviceId") ||
            DeviceClient.Text(target, "installationIdentity") != DeviceClient.Text(paired, "installationId") ||
            DeviceClient.Text(target, "profileReference") != DeviceClient.Text(paired, "profileId")) throw new LinkFailure("device_mismatch");
    }

    /// Called under the original protected owner lock after DPAPI decryption.
    internal static void Verify(string directory, JsonElement custody, JsonElement paired, string credentialDigest)
    {
        RequireRecord(custody);
        foreach (string name in SourceFiles.Append("registration-source.json"))
            if (File.Exists(Path.Combine(directory, name + ".pending"))) throw new LinkFailure("recovery_required");
        var manifest = Read(directory, "registration-source.json");
        DeviceClient.Fields(manifest, ["formatVersion", "slotRef", "registration", "files"]);
        var files = manifest.GetProperty("files"); DeviceClient.Fields(files, SourceFiles);
        if (manifest.GetProperty("formatVersion").GetInt32() != 1 || DeviceClient.Text(manifest, "slotRef") != DeviceClient.Text(custody, "slotRef") ||
            manifest.GetProperty("registration").GetRawText() != custody.GetProperty("registration").GetRawText() ||
            Digest(directory, "registration-source.json") != DeviceClient.Text(custody, "sourceDigest")) throw new LinkFailure("source_changed");
        foreach (string name in SourceFiles) if (Digest(directory, name) != DeviceClient.Text(files, name)) throw new LinkFailure("source_changed");
        var origin = Read(directory, "registration-origin.json");
        DeviceClient.Fields(origin, ["formatVersion", "slotRef", "origin", "registration", "target", "credentialSlotRef", "credentialDigest", "associationRevision", "clientCertificateDigest", "resourceGeneration", "settlementRef"]);
        if (origin.GetProperty("formatVersion").GetInt32() != 2 || DeviceClient.Text(origin, "origin") != "independent_registrar_pairing" ||
            DeviceClient.Text(origin, "slotRef") != DeviceClient.Text(custody, "slotRef") ||
            origin.GetProperty("registration").GetRawText() != custody.GetProperty("registration").GetRawText() ||
            DeviceClient.Text(origin, "credentialSlotRef") != "device.dpapi" ||
            origin.GetProperty("target").GetRawText() != custody.GetProperty("verifiedInstallationBinding").GetRawText()) throw new LinkFailure("source_changed");
        RequireCredentialBinding(origin, paired, credentialDigest);
        var receipt = Read(directory, "registration-receipt.json");
        var registration = custody.GetProperty("registration");
        foreach (string field in new[] { "operationId", "runId", "resourceId" })
            if (DeviceClient.Text(receipt, field) != DeviceClient.Text(registration, field)) throw new LinkFailure("owner_conflict");
        if (DeviceClient.Text(receipt, "owner") != DeviceClient.Text(registration, "registrarInstanceId") ||
            DeviceClient.Text(receipt, "mode") != "pairing" || DeviceClient.Text(receipt, "receiptRef") != DeviceClient.Text(origin, "settlementRef")) throw new LinkFailure("owner_conflict");
        var join = Read(directory, "registration-joined.json");
        DeviceClient.Fields(join, ["formatVersion", "operationId", "slotRef", "ownerInstanceId", "runId", "resourceId", "processId", "processStarted", "adapterReceiptRef", "target", "processExitCode", "stdinClosed", "stdoutDrained", "stderrDrained"]);
        if (join.GetProperty("formatVersion").GetInt32() != 1 || join.GetProperty("processExitCode").GetInt32() != 0 ||
            !join.GetProperty("stdinClosed").GetBoolean() || !join.GetProperty("stdoutDrained").GetBoolean() || !join.GetProperty("stderrDrained").GetBoolean() ||
            DeviceClient.Text(join, "ownerInstanceId") != DeviceClient.Text(receipt, "owner") ||
            DeviceClient.Text(join, "adapterReceiptRef") != DeviceClient.Text(receipt, "receiptRef")) throw new LinkFailure("recovery_required");
        foreach (string field in new[] { "operationId", "slotRef", "runId", "resourceId", "processId", "processStarted", "target" })
            if (join.GetProperty(field).GetRawText() != receipt.GetProperty(field).GetRawText()) throw new LinkFailure("recovery_required");
    }
}
