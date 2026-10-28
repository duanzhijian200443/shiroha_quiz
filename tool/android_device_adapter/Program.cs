namespace Shiroha.AndroidDevice;

internal static class Program
{
    // Source/compile/fixture delivery only. No option enables real acquisition.
    internal const bool RuntimeAvailable = false;
    internal static int Main(string[] args)
    {
        if (args is ["--self-test"]) return SyntheticTests.Run();
        Console.Error.WriteLine("android_device_runtime_not_authorized");
        return 78;
    }
}

internal sealed class LinkFailure(string code) : Exception(code)
{
    internal string Code { get; } = code;
    public override string ToString() => $"LinkFailure({Code})";
}
