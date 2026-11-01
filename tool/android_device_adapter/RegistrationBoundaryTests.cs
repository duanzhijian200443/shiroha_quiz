using System.Text.Json;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
namespace Shiroha.AndroidDevice;

internal static class RegistrationBoundaryTests
{
    internal static void Run()
    {
        static void Reject(Action action) {
            try { action(); } catch (LinkFailure) { return; }
            throw new Exception("registration_expected_refusal");
        }
        var registration = new { registrarInstanceId = "registrar", operationId = "registration", generation = "generation", runId = "run", resourceId = "resource" };
        var fields = new Dictionary<string, object?> {
            ["formatVersion"] = 2, ["slotRef"] = "slot", ["operationId"] = "registration", ["initializationSource"] = "registered_pairing",
            ["ownershipState"] = "REGISTERING", ["ownerKind"] = "independent_registrar", ["ownerInstanceId"] = "registrar", ["ownerGeneration"] = "generation",
            ["verifiedInstallationBinding"] = null, ["adapterCredentialSlotRef"] = null, ["resourceGeneration"] = "resource", ["lastSettlementRef"] = null,
            ["lastSettlementState"] = "UNKNOWN", ["revision"] = 0, ["registration"] = registration, ["sourceDigest"] = null, ["adoption"] = null
        };
        JsonElement Record() => JsonSerializer.SerializeToElement(fields);
        void Registrar() => SlotFence.RequireOwnerRecord(Record(), "registrar", "slot", "registration", "resource", true, registering: true);
        void Business() => SlotFence.RequireOwnerRecord(Record(), "link", "slot", "adoption", "business", false);
        Registrar(); Reject(Business);
        foreach (string field in new[] { "ownerInstanceId", "operationId", "ownerGeneration", "slotRef" }) {
            var prior = fields[field]; fields[field] = "wrong"; Reject(Registrar); fields[field] = prior;
        }
        fields["ownershipState"] = "SEALED";
        fields["verifiedInstallationBinding"] = new { deviceIdentity = new string('a', 64), installationIdentity = "installation", profileReference = "profile" };
        fields["adapterCredentialSlotRef"] = "device.dpapi"; fields["lastSettlementRef"] = "resource";
        fields["lastSettlementState"] = "CLEAN"; fields["sourceDigest"] = new string('b', 64);
        Reject(Registrar); Reject(Business);
        SlotFence.RequireOwnerRecord(Record(), "link", "slot", "adoption", "inspection", false, inspecting: true);
        fields["ownershipState"] = "ADOPT_PENDING"; fields["ownerKind"] = "independent_link";
        fields["ownerInstanceId"] = "link"; fields["operationId"] = "adoption"; fields["ownerGeneration"] = "adoption";
        fields["adoption"] = new { connectorInstanceId = "link", operationId = "adoption" };
        Reject(Registrar); Reject(Business);
        fields["ownershipState"] = "LINK_OWNED"; fields["resourceGeneration"] = "business";
        Business(); Reject(Registrar);
        fields["formatVersion"] = 99; Reject(Business); fields["formatVersion"] = 2;
        fields["adoption"] = new { connectorInstanceId = "other", operationId = "adoption" }; Reject(Business);

        // Pure synthetic ephemeral certificates; no DPAPI/private slot/TLS/CNG file.
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var certificate = ProtectedDeviceStore.CreateClientLeaf(key, false);
        byte[] pfx = certificate.Export(X509ContentType.Pfx);
        try {
            var paired = JsonSerializer.SerializeToElement(new { purpose = "android-read", associationRevision = 7, clientPfx = Convert.ToBase64String(pfx) });
            var binding = RegistrationCustody.CredentialBinding(paired);
            if (binding.Revision != 7 || binding.ClientDigest != Convert.ToHexStringLower(SHA256.HashData(certificate.RawData))) throw new Exception("credential_binding_failed");
            Reject(() => RegistrationCustody.CredentialBinding(JsonSerializer.SerializeToElement(new { purpose = "android-read", associationRevision = 0, clientPfx = Convert.ToBase64String(pfx) })));
            var origin = JsonSerializer.SerializeToElement(new { credentialDigest = new string('c', 64), associationRevision = 7,
                clientCertificateDigest = binding.ClientDigest, target = new { deviceIdentity = "device", installationIdentity = "installation", profileReference = "profile" } });
            JsonElement Paired(int revision, byte[] bytes) => JsonSerializer.SerializeToElement(new { purpose = "android-read", associationRevision = revision,
                clientPfx = Convert.ToBase64String(bytes), deviceId = "device", installationId = "installation", profileId = "profile" });
            RegistrationCustody.RequireCredentialBinding(origin, Paired(7, pfx), new string('c', 64));
            Reject(() => RegistrationCustody.RequireCredentialBinding(origin, Paired(8, pfx), new string('c', 64)));
            Reject(() => RegistrationCustody.RequireCredentialBinding(origin, Paired(7, pfx), new string('d', 64)));
            using var otherKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            using var otherCertificate = ProtectedDeviceStore.CreateClientLeaf(otherKey, false);
            byte[] otherPfx = otherCertificate.Export(X509ContentType.Pfx);
            try { Reject(() => RegistrationCustody.RequireCredentialBinding(origin, Paired(7, otherPfx), new string('c', 64))); }
            finally { CryptographicOperations.ZeroMemory(otherPfx); }
        } finally { CryptographicOperations.ZeroMemory(pfx); }
        Console.WriteLine("PASS: v2 registrar sealing/adoption/native custody fences and synthetic certificate-generation binding");
    }
}
