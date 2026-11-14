namespace Shiroha.AndroidDevice;

internal static class Program
{
    // Business remains unavailable. Native proof is an explicit local task entry.
    internal const bool RuntimeAvailable = false;
    internal static int Main(string[] args)
    {
#if DEBUG
        if (args is ["--preauth-native-fixture", var fixtureDirectory, var fixtureScenario, var fixtureRun, var fixtureResource])
            return ProofExit(PreauthNativeFixture.Run(fixtureDirectory, fixtureScenario, fixtureRun, fixtureResource).GetAwaiter().GetResult());
#endif
        if (args is ["--self-test"]) return SyntheticTests.Run();
        if (args is [var registrationAction, var registrationRun, var registrationResource, "--current-user-cng-import"] &&
            registrationAction is "--register-pair" or "--link-inspect-registration")
        {
            try {
                using var owner = new LinkAdapterContext(registrationRun, registrationResource,
                    registering: registrationAction == "--register-pair", inspecting: registrationAction == "--link-inspect-registration");
                if (owner.Inspecting) { owner.InspectRegistration(); return 0; }
                owner.PrepareOrInspectPairing();
                return DeviceClient.Run("pairing", owner.Directory, null, 3, owner).GetAwaiter().GetResult();
            } catch { Console.Error.WriteLine("android_registration_unavailable"); return 79; }
        }
        if (args is [var action, var runId, var resourceId, "--current-user-cng-import"] &&
            action is "--link-business" or "--link-proof" or "--link-pair")
        {
            try
            {
                using var owner = new LinkAdapterContext(runId, resourceId, action == "--link-pair");
                if (action == "--link-pair" && owner.PrepareOrInspectPairing()) return 0;
                int code = DeviceClient.Run(action == "--link-business" ? "business" :
                    action == "--link-pair" ? "pairing" : "enable-proof",
                    owner.Directory, null, 3, owner).GetAwaiter().GetResult();
                return action == "--link-proof" ? ProofExit(code) : code;
            }
            catch { Console.Error.WriteLine("android_link_owner_unavailable"); return 79; }
        }
        if (args is ["--link-refresh-address", var refreshRun, var refreshResource, var candidate, "--current-user-cng-import"])
        {
            try
            {
                using var owner = new LinkAdapterContext(refreshRun, refreshResource);
                owner.RequireAddressRefresh();
                return ProofExit(DeviceClient.Run("enable-proof", owner.Directory, candidate, 3, owner).GetAwaiter().GetResult());
            }
            catch (LinkFailure error) {
                Console.Error.WriteLine(error.Code == "address_update_unsupported" ?
                    "android_address_update_unsupported" : "android_address_update_refused");
                return 79;
            }
            catch { Console.Error.WriteLine("android_address_update_refused"); return 79; }
        }
        if (args is ["--link-route-proof", var routeRun, var routeResource, var routeCandidate, "--current-user-cng-import"])
        {
            try
            {
                using var owner = new LinkAdapterContext(routeRun, routeResource);
                owner.RequireRouteProof();
                return ProofExit(DeviceClient.Run("enable-proof", owner.Directory, routeCandidate, 3, owner, routeOnly: true).GetAwaiter().GetResult());
            }
            catch { Console.Error.WriteLine("android_route_proof_refused"); return 79; }
        }
        if (args is ["--link-business-route", var businessRouteRun, var businessRouteResource, var businessRouteCandidate, "--current-user-cng-import"])
        {
            try
            {
                using var owner = new LinkAdapterContext(businessRouteRun, businessRouteResource);
                return DeviceClient.Run("business", owner.Directory, businessRouteCandidate, 3, owner).GetAwaiter().GetResult();
            }
            catch { Console.Error.WriteLine("android_link_owner_unavailable"); return 79; }
        }
        if (args is ["--pair", var directory, var address, "--current-user-cng-import"])
            return DeviceClient.Run("pairing", directory, address).GetAwaiter().GetResult();
        if (args is ["--enable-proof", var proofDirectory, "--current-user-cng-import"])
            return ProofExit(DeviceClient.Run("enable-proof", proofDirectory, null).GetAwaiter().GetResult());
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

    // Successful supervision owes live owner-identity capture before EOF.
    // Rejection/deadline also releases EOF, without granting any join evidence.
    // Keep the adapter alive until that original supervisor decision.
    private static int ProofExit(int code)
    {
        try { Console.OpenStandardInput().CopyToAsync(Stream.Null).GetAwaiter().GetResult(); }
        catch { /* EOF observation cannot change the original exit code. */ }
        return code;
    }
}

internal sealed class LinkFailure(string code) : Exception(code)
{
    internal string Code { get; } = code;
    public override string ToString() => $"LinkFailure({Code})";
}
