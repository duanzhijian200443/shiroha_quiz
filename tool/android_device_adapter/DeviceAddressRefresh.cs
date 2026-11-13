using System.Net;
using System.Text.Json;

namespace Shiroha.AndroidDevice;

// Routing-only update. The sealed v2 registration package is never rewritten.
internal static class DeviceAddressRefresh
{
    internal static void RequireV1(JsonElement custody)
    {
        int version = custody.GetProperty("formatVersion").GetInt32();
        if (version == 2) throw new LinkFailure("address_update_unsupported");
        if (version != 1 || DeviceClient.Text(custody, "ownershipState") != "LINK_OWNED" ||
            DeviceClient.Text(custody, "ownerKind") != "independent_link" ||
            DeviceClient.Text(custody, "adapterCredentialSlotRef") != "device.dpapi")
            throw new LinkFailure("owner_conflict");
    }

    // Run-only routing proof for sealed v2 custody. The sealed package is never
    // rewritten; ProtectedDeviceStore.Read verifies the original provenance.
    internal static void RequireV2(JsonElement custody)
    {
        if (custody.GetProperty("formatVersion").GetInt32() != 2 ||
            DeviceClient.Text(custody, "ownershipState") != "LINK_OWNED" ||
            DeviceClient.Text(custody, "ownerKind") != "independent_link" ||
            DeviceClient.Text(custody, "adapterCredentialSlotRef") != "device.dpapi")
            throw new LinkFailure("owner_conflict");
    }

    internal static void RequirePairedRecord(JsonElement record)
    {
        DeviceClient.Fields(record, ["purpose", "clientPfx", "deviceId", "certificateDigest",
            "installationId", "profileId", "associationRevision", "address", "port"]);
        if (DeviceClient.Text(record, "purpose") != "android-read" ||
            !Guid.TryParseExact(DeviceClient.Text(record, "installationId"), "D", out _) ||
            record.GetProperty("associationRevision").GetInt32() < 1 ||
            record.GetProperty("port").GetInt32() != 46443)
            throw new LinkFailure("credential_store_corrupt");
    }

    // Called only after original proof and TLS EOF; persistence is still owed.
    internal static byte[] Replacement(JsonElement record, IPAddress candidate)
    {
        RequirePairedRecord(record);
        if (!DeviceTarget.PrivateV4(candidate)) throw new LinkFailure("invalid_target");
        using var bytes = new MemoryStream();
        using (var writer = new Utf8JsonWriter(bytes))
        {
            writer.WriteStartObject();
            foreach (var property in record.EnumerateObject())
            {
                if (property.Name == "address") writer.WriteString("address", candidate.ToString());
                else property.WriteTo(writer);
            }
            writer.WriteEndObject();
        }
        return bytes.ToArray();
    }
}
