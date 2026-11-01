using System.Net;
using System.Text.Json;

namespace Shiroha.AndroidDevice;

internal static class LinkInitializationTests
{
    internal static void Run()
    {
        static void Reject(Action action)
        {
            try { action(); } catch (LinkFailure) { return; }
            throw new Exception("link_initialization_expected_refusal");
        }
        var target = new DeviceTarget(new string('a', 64), new string('b', 64),
            "10000000-0000-4000-8000-000000000001", IPAddress.Parse("192.168.1.2"), 46443);
        var binding = new { deviceIdentity = target.DeviceId, installationIdentity = "installation", profileReference = target.ProfileId };
        var fields = new Dictionary<string, object?> {
            ["formatVersion"] = 1, ["slotRef"] = "slot", ["operationId"] = "original-operation",
            ["initializationSource"] = "new_pairing", ["ownershipState"] = "UNCLAIMED",
            ["ownerKind"] = "independent_link", ["ownerInstanceId"] = "owner", ["ownerGeneration"] = null,
            ["verifiedInstallationBinding"] = null, ["adapterCredentialSlotRef"] = null,
            ["resourceGeneration"] = null, ["lastSettlementRef"] = null,
            ["lastSettlementState"] = "UNKNOWN", ["revision"] = 0,
        };
        void Validate(bool initializing) => SlotFence.RequireOwnerRecord(JsonSerializer.SerializeToElement(fields),
            "owner", "slot", "original-operation", "resource", initializing, target, "installation");
        Validate(true);
        Reject(() => Validate(false));
        fields["ownershipState"] = "LINK_OWNED";
        Reject(() => Validate(false));
        fields["ownerGeneration"] = "original-operation";
        fields["adapterCredentialSlotRef"] = "device.dpapi";
        fields["resourceGeneration"] = "resource";
        Reject(() => Validate(false));
        fields["verifiedInstallationBinding"] = binding;
        fields["lastSettlementState"] = "CLEAN";
        fields["lastSettlementRef"] = "resource";
        Validate(false);
        foreach (var name in new[] { "ownerInstanceId", "slotRef", "operationId", "ownerGeneration", "resourceGeneration" })
        {
            var original = fields[name]; fields[name] = "another-owner-or-run";
            Reject(() => Validate(false)); fields[name] = original;
        }
        fields["formatVersion"] = 9; Reject(() => Validate(false)); fields["formatVersion"] = 1;
        fields["grant"] = "not-an-authority"; Reject(() => Validate(false)); fields.Remove("grant");
        var receipt = new Dictionary<string, object?> {
            ["formatVersion"] = 2, ["operationId"] = "original-operation", ["receiptRef"] = "resource",
            ["runId"] = "run", ["resourceId"] = "resource", ["processId"] = 100,
            ["processStarted"] = "123456", ["slotRef"] = "slot", ["owner"] = "owner",
            ["mode"] = "pairing", ["target"] = binding, ["targetClose"] = true,
            ["tlsShutdown"] = true, ["keyRetired"] = true,
        };
        void ValidateReceipt() => LinkAdapterContext.ValidateInitialReceipt(JsonSerializer.SerializeToElement(receipt), "slot", target, "installation");
        ValidateReceipt();
        foreach (var name in new[] { "targetClose", "tlsShutdown", "keyRetired" })
        { receipt[name] = false; Reject(ValidateReceipt); receipt[name] = true; }
        receipt["mode"] = "enable-proof"; Reject(ValidateReceipt); receipt["mode"] = "pairing";
        receipt["target"] = new { deviceIdentity = target.DeviceId, installationIdentity = "different", profileReference = target.ProfileId };
        Reject(ValidateReceipt);
        RegistrationBoundaryTests.Run();
        Console.WriteLine("PASS: initialization owner, preparation and original-receipt boundary fixtures; no native or credential access");
    }
}
