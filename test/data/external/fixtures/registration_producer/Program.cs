using System.Text.Json;
using System.Security.Cryptography;
namespace Shiroha.AndroidDevice;

// Test-only executable. No production command or configuration can select it.
internal static class Program
{
    internal const bool RuntimeAvailable = false;
    internal static int Main(string[] args)
    {
        if (args.Length != 1 && args.Length != 3) return 64;
        string directory = Path.GetFullPath(args[0]);
        var custody = RegistrationCustody.Read(directory, "slot-ownership.json");
        var registration = custody.GetProperty("registration");
        bool legacyRefused = false;
        try { SlotFence.RequireLegacy(directory); } catch (LinkFailure) { legacyRefused = true; }
        if (!legacyRefused) throw new Exception("legacy_entry_not_fenced");
        if (args.Length == 1) SlotFence.RequireOwnerRecord(custody,
            DeviceClient.Text(registration, "registrarInstanceId"), DeviceClient.Text(custody, "slotRef"),
            DeviceClient.Text(registration, "operationId"), DeviceClient.Text(registration, "resourceId"), true, registering: true);
        // This is deliberately not DPAPI and never passed to ProtectedDeviceStore.
        if (args.Length == 1) File.WriteAllText(Path.Combine(directory, "device.dpapi"), "synthetic-ciphertext-no-secret");
        var target = new { deviceIdentity = new string('a', 64), installationIdentity = "synthetic-installation", profileReference = "synthetic-profile" };
        var receipt = JsonSerializer.SerializeToElement(new { formatVersion = 2,
            operationId = DeviceClient.Text(registration, "operationId"), receiptRef = DeviceClient.Text(registration, "resourceId"),
            runId = args.Length == 1 ? DeviceClient.Text(registration, "runId") : args[1], resourceId = args.Length == 1 ? DeviceClient.Text(registration, "resourceId") : args[2],
            processId = Environment.ProcessId, processStarted = System.Diagnostics.Process.GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc().ToString(),
            slotRef = DeviceClient.Text(custody, "slotRef"), owner = DeviceClient.Text(registration, "registrarInstanceId"), mode = "pairing", target,
            targetClose = true, tlsShutdown = true, keyRetired = true });
        if (args.Length == 1) RegistrationCustody.Produce(directory, custody, receipt, 7, new string('b', 64), RegistrationCustody.Digest(directory, "device.dpapi"));
        Console.Error.WriteLine("SHIROHA_LINK_EVENT " + JsonSerializer.Serialize(new { type = "owner",
            runId = receipt.GetProperty("runId").GetString(), resourceId = receipt.GetProperty("resourceId").GetString(),
            processId = Environment.ProcessId, processStarted = receipt.GetProperty("processStarted").GetString(), slotRef = DeviceClient.Text(custody, "slotRef") }));
        Console.Error.WriteLine("SHIROHA_LINK_EVENT " + JsonSerializer.Serialize(new { type = "initialization-complete",
            runId = receipt.GetProperty("runId").GetString(), resourceId = receipt.GetProperty("resourceId").GetString(), target }));
        return 0;
    }
}
internal sealed class LinkFailure(string code) : Exception(code)
{
    internal string Code { get; } = code;
    public override string ToString() => $"LinkFailure({Code})";
}
