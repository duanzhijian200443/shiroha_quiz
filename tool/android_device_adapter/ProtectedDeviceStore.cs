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

    private static byte[] Protect(byte[] value, bool encrypt)
    {
        DeviceTransport.RequireRuntime();
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

    internal static byte[] CreateClientIdentity()
    {
        DeviceTransport.RequireRuntime();
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=Shiroha Android transport adapter", key, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        var usage = new OidCollection { new("1.3.6.1.5.5.7.3.2") };
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(usage, true));
        using var cert = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddYears(2));
        return cert.Export(X509ContentType.Pfx);
    }

    internal static byte[] Read(string directory)
    {
        DeviceTransport.RequireRuntime();
        using var guard = new FileStream(Path.Combine(directory, "adapter.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        using var file = File.OpenRead(Path.Combine(directory, "device.dpapi"));
        if (file.Length is < 1 or > 65536) throw new LinkFailure("credential_store_corrupt");
        byte[] bytes = new byte[(int)file.Length]; file.ReadExactly(bytes);
        try { return Protect(bytes, false); } finally { CryptographicOperations.ZeroMemory(bytes); }
    }

    internal static void Create(string directory, byte[] configuration)
    {
        DeviceTransport.RequireRuntime();
        using var parsed = LinkFrames.StrictObject(configuration);
        Directory.CreateDirectory(directory);
        using var guard = new FileStream(Path.Combine(directory, "adapter.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        string target = Path.Combine(directory, "device.dpapi");
        if (File.Exists(target)) throw new LinkFailure("pairing_exists");
        byte[] encrypted = Protect(configuration, true);
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
}
