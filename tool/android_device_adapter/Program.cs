namespace Shiroha.AndroidDevice;

internal static class Program
{
    // Business remains unavailable. Native proof is an explicit local task entry.
    internal const bool RuntimeAvailable = false;
    internal static int Main(string[] args)
    {
        if (args is ["--self-test"]) return SyntheticTests.Run();
        if (args is ["--handoff-binding"]) return LegacySlotBinding.Run();
        if (args is [var action, var runId, var resourceId, "--current-user-cng-import"] &&
            action is "--link-business" or "--link-proof")
        {
            try
            {
                using var owner = new LinkAdapterContext(runId, resourceId);
                return DeviceClient.Run(action == "--link-business" ? "business" : "enable-proof",
                    owner.Directory, null, 3, owner).GetAwaiter().GetResult();
            }
            catch { Console.Error.WriteLine("android_link_owner_unavailable"); return 79; }
        }
        if (args is ["--pair", var directory, var address, "--current-user-cng-import"])
            return DeviceClient.Run("pairing", directory, address).GetAwaiter().GetResult();
        if (args is ["--enable-proof", var proofDirectory, "--current-user-cng-import"])
            return DeviceClient.Run("enable-proof", proofDirectory, null).GetAwaiter().GetResult();
        if (args is ["--business", var businessDirectory, "--current-user-cng-import"])
            return DeviceClient.Run("business", businessDirectory, null).GetAwaiter().GetResult();
        if (args.Length >= 5 && args[0] == "--native-proof")
        {
            string[] options = args[5..];
            if (options.Distinct().Count() == options.Length && options.All(value =>
                value is "--existing-native-identity" or "--current-user-cng-import"))
                return NativeProof.Run(args[1], args[2], args[3], args[4],
                    options.Contains("--existing-native-identity"), options.Contains("--current-user-cng-import")).GetAwaiter().GetResult();
        }
        Console.Error.WriteLine("android_device_runtime_not_authorized");
        return 78;
    }
}

internal sealed class LinkFailure(string code) : Exception(code)
{
    internal string Code { get; } = code;
    public override string ToString() => $"LinkFailure({Code})";
}
