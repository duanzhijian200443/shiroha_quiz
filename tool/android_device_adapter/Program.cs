namespace Shiroha.AndroidDevice;

internal static class Program
{
    // Business remains unavailable. Native proof is an explicit local task entry.
    internal const bool RuntimeAvailable = false;
    internal static int Main(string[] args)
    {
        if (args is ["--self-test"]) return SyntheticTests.Run();
        if (args is ["--pair", var directory, var address, "--current-user-cng-import"])
            return DeviceClient.Run("pairing", directory, address).GetAwaiter().GetResult();
        if (args is ["--enable-proof", var proofDirectory, "--current-user-cng-import"])
            return DeviceClient.Run("enable-proof", proofDirectory, null).GetAwaiter().GetResult();
        if (args is ["--business", var businessDirectory, "--current-user-cng-import"])
            return DeviceClient.Run("business", businessDirectory, null).GetAwaiter().GetResult();
        if (args is ["--business", var unifiedDirectory, "--profile=3", "--current-user-cng-import"])
            return DeviceClient.Run("business", unifiedDirectory, null, 3).GetAwaiter().GetResult();
        if (args is ["--hosted-business", var hostedDirectory, "--profile=3", "--current-user-cng-import"])
        {
            if (!DeviceClient.IsRecordDirectory(hostedDirectory)) return 78;
            // Only original process/stream settlement with no retained key
            // marker permits the App to release this child. Never repair here.
            var result = DeviceClient.Run("business", hostedDirectory, null, 3).GetAwaiter().GetResult();
            if (result == 79) return 79;
            try
            {
                using var lease = new FileStream(Path.Combine(hostedDirectory, "adapter.lock"),
                    FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                return File.Exists(Path.Combine(hostedDirectory, "native-client-key.pending")) ? 79 : 0;
            }
            catch { return 79; }
        }
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
