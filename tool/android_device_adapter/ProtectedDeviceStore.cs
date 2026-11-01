using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace Shiroha.AndroidDevice;

/// <summary>Dedicated current-user DPAPI object; never reads Windows Shiroha credentials.</summary>
internal static class ProtectedDeviceStore
{
    [StructLayout(LayoutKind.Sequential)] private struct Blob { internal int Length; internal IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref Blob input, string description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr pointer);

    private static byte[] Protect(byte[] value, bool encrypt, Action requireAdmission)
    {
        requireAdmission();
        if (!OperatingSystem.IsWindows() || value.Length is < 1 or > 65536) throw new LinkFailure("credential_store_unavailable");
        var input = new Blob { Length = value.Length, Data = Marshal.AllocHGlobal(value.Length) };
        Blob output = default;
        try
        {
            Marshal.Copy(value, 0, input.Data, value.Length);
            bool ok = encrypt ? CryptProtectData(ref input, "Shiroha Android adapter v1", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok || output.Length is < 1 or > 65536) throw new LinkFailure("credential_store_unavailable");
            byte[] result = new byte[output.Length]; Marshal.Copy(output.Data, result, 0, result.Length); return result;
        }
        finally
        {
            Marshal.Copy(new byte[value.Length], 0, input.Data, value.Length); Marshal.FreeHGlobal(input.Data);
            if (output.Data != IntPtr.Zero) { Marshal.Copy(new byte[output.Length], 0, output.Data, output.Length); LocalFree(output.Data); }
        }
    }

    internal static byte[] CreateClientIdentity(Action? requireAdmission = null)
    {
        (requireAdmission ?? DeviceTransport.RequireRuntime)();
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var cert = CreateClientLeaf(key, false);
        return cert.Export(X509ContentType.Pfx);
    }

    internal static X509Certificate2 CreateClientLeaf(ECDsa key, bool negativeIdentity)
    {
        var request = new CertificateRequest(negativeIdentity
            ? "CN=Shiroha Android negative identity" : "CN=Shiroha Android transport adapter", key, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        var usage = new OidCollection { new("1.3.6.1.5.5.7.3.2") };
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(usage, true));
        return request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddYears(2));
    }

    internal static byte[] Read(string directory, Action? requireAdmission = null, Action? requireSlot = null)
    {
        requireAdmission ??= DeviceTransport.RequireRuntime;
        requireAdmission();
        using var guard = new FileStream(Path.Combine(directory, "adapter.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        (requireSlot ?? (() => SlotFence.RequireLegacy(directory)))();
        using var file = File.OpenRead(Path.Combine(directory, "device.dpapi"));
        if (file.Length is < 1 or > 65536) throw new LinkFailure("credential_store_corrupt");
        byte[] bytes = new byte[(int)file.Length]; file.ReadExactly(bytes);
        try {
            byte[] clear = Protect(bytes, false, requireAdmission);
            try {
                string custodyPath = Path.Combine(directory, "slot-ownership.json");
                if (File.Exists(custodyPath)) {
                    var custody = RegistrationCustody.Read(directory, "slot-ownership.json");
                    if (custody.GetProperty("formatVersion").GetInt32() == 2 && DeviceClient.Text(custody, "ownershipState") != "REGISTERING") {
                        using var document = LinkFrames.StrictObject(clear);
                        RegistrationCustody.Verify(directory, custody, document.RootElement, Convert.ToHexStringLower(SHA256.HashData(bytes)));
                    }
                }
                return clear;
            } catch { CryptographicOperations.ZeroMemory(clear); throw; }
        } finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    // Holds the SAME original resource mutex across decrypt, binding and source
    // verification. The callback must never acquire the slot control lock.
    internal static void Inspect(string directory, Action requireAdmission, Action requireSlot,
        Action<JsonElement, string> inspect)
    {
        requireAdmission();
        using var guard = new FileStream(Path.Combine(directory, "adapter.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        requireSlot();
        using var file = new FileStream(Path.Combine(directory, "device.dpapi"), FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length is < 1 or > 65536) throw new LinkFailure("credential_store_corrupt");
        byte[] bytes = new byte[(int)file.Length]; file.ReadExactly(bytes);
        byte[] clear = Protect(bytes, false, requireAdmission);
        try { using var parsed = LinkFrames.StrictObject(clear); inspect(parsed.RootElement, Convert.ToHexStringLower(SHA256.HashData(bytes))); }
        finally { CryptographicOperations.ZeroMemory(clear); CryptographicOperations.ZeroMemory(bytes); }
    }

    internal static void Create(string directory, byte[] configuration, Action? requireAdmission = null, Action? requireSlot = null)
    {
        requireAdmission ??= DeviceTransport.RequireRuntime;
        requireAdmission();
        using var parsed = LinkFrames.StrictObject(configuration);
        Directory.CreateDirectory(directory);
        using var guard = new FileStream(Path.Combine(directory, "adapter.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        (requireSlot ?? (() => SlotFence.RequireLegacy(directory)))();
        string target = Path.Combine(directory, "device.dpapi");
        if (File.Exists(target)) throw new LinkFailure("pairing_exists");
        byte[] encrypted = Protect(configuration, true, requireAdmission);
        string staging = Path.Combine(directory, "device.pending");
        try
        {
            using (var file = new FileStream(staging, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { file.Write(encrypted); file.Flush(true); }
            File.Move(staging, target, false);
        }
        catch { throw new LinkFailure("credential_commit_unknown"); }
        finally { CryptographicOperations.ZeroMemory(encrypted); }
    }

    internal static void Replace(string directory, byte[] expected, byte[] configuration, Action requireAdmission, Action? requireSlot = null)
    {
        requireAdmission();
        using var parsed = LinkFrames.StrictObject(configuration);
        using var guard = new FileStream(Path.Combine(directory, "adapter.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        string target = Path.Combine(directory, "device.dpapi"), pending = Path.Combine(directory, "device.pending");
        (requireSlot ?? (() => SlotFence.RequireLegacy(directory)))();
        using (var original = new FileStream(target, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            if (original.Length is < 1 or > 65536) throw new LinkFailure("credential_store_corrupt");
            byte[] encryptedOld = new byte[(int)original.Length]; original.ReadExactly(encryptedOld);
            byte[] clear = Protect(encryptedOld, false, requireAdmission);
            try { if (!CryptographicOperations.FixedTimeEquals(clear, expected)) throw new LinkFailure("stale_revision"); }
            finally { CryptographicOperations.ZeroMemory(clear); CryptographicOperations.ZeroMemory(encryptedOld); }
        }
        byte[] encrypted = Protect(configuration, true, requireAdmission);
        try
        {
            using (var staged = new FileStream(pending, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { staged.Write(encrypted); staged.Flush(true); }
            File.Replace(pending, target, null);
        }
        catch { throw new LinkFailure("credential_commit_unknown"); }
        finally { CryptographicOperations.ZeroMemory(encrypted); }
    }
}
