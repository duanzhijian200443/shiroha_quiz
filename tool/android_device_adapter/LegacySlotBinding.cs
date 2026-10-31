using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace Shiroha.AndroidDevice;

internal static class LegacySlotBinding
{
    [DllImport("shiroha_handoff_native.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int shiroha_relay_open(uint role, out ulong handle);
    [DllImport("shiroha_handoff_native.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int shiroha_relay_state(ulong handle);
    [DllImport("shiroha_handoff_native.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int shiroha_relay_close(ulong handle);
    internal static int Run()
    {
        ulong guard = 0; byte[] clear = []; int result = 78;
        try
        {
            if (shiroha_relay_open(2, out guard) != 0 || guard == 0) throw new LinkFailure("runtime_not_authorized");
            void Current() { if (shiroha_relay_state(guard) != 0) throw new LinkFailure("runtime_not_authorized"); }
            using var input = new FileStream(Path.Combine(AppContext.BaseDirectory, "link-installation.json"), FileMode.Open, FileAccess.Read, FileShare.Read);
            if (input.Length is < 1 or > 16384) throw new LinkFailure("invalid_target");
            byte[] bytes = new byte[(int)input.Length]; input.ReadExactly(bytes);
            using var config = LinkFrames.StrictObject(bytes);
            DeviceClient.Fields(config.RootElement, ["version", "stateDirectory", "slotDirectory", "slotRef",
                "connectorInstanceId", "adapterExecutable", "windowsClientExecutable"]);
            var directory = DeviceClient.Text(config.RootElement, "slotDirectory");
            if (config.RootElement.GetProperty("version").GetInt32() != 1 || !Path.IsPathFullyQualified(directory) ||
                !Path.GetFullPath(DeviceClient.Text(config.RootElement, "adapterExecutable")).Equals(Environment.ProcessPath, StringComparison.OrdinalIgnoreCase))
                throw new LinkFailure("invalid_target");
            clear = ProtectedDeviceStore.Read(directory, Current);
            using var record = LinkFrames.StrictObject(clear);
            if (DeviceClient.Text(record.RootElement, "purpose") != "android-read") throw new LinkFailure("pairing_required");
            string device = DeviceClient.Text(record.RootElement, "deviceId"),
                installation = DeviceClient.Text(record.RootElement, "installationId"), profile = DeviceClient.Text(record.RootElement, "profileId");
            if (!DeviceTarget.HexDigest(device) || !Guid.TryParseExact(installation, "D", out _) || !Guid.TryParseExact(profile, "D", out _))
                throw new LinkFailure("credential_store_corrupt");
            Current();
            Console.WriteLine(JsonSerializer.Serialize(new { deviceIdentity = device, installationIdentity = installation, profileReference = profile }));
            result = 0;
        }
        catch { Console.Error.WriteLine("legacy_binding_unavailable"); result = 78; }
        finally { CryptographicOperations.ZeroMemory(clear); if (guard != 0 && shiroha_relay_close(guard) != 0) result = 79; }
        return result;
    }
}
