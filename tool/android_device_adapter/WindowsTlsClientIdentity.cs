using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace Shiroha.AndroidDevice;

/// <summary>One newly imported current-user CNG key, retained through TLS close.
/// No certificate-store enrollment, enumeration or existing-key acquisition.</summary>
internal sealed class WindowsTlsClientIdentity : IDisposable
{
    private readonly string markerPath;
    private readonly FileStream directoryLease;
    private FileStream? marker;
    private byte[] expectedMarker = [];
    private X509Certificate2? certificate;
    private ECDsaCng? signing;
    private CngKey? key;
    private string? keyName;
    private bool closed, failed;

    internal X509Certificate2 Certificate => !closed && certificate != null
        ? certificate : throw new LinkFailure("credential_store_unavailable");

    private WindowsTlsClientIdentity(string directory)
    {
        Directory.CreateDirectory(directory);
        directoryLease = new FileStream(Path.Combine(directory, "adapter.lock"),
            FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        markerPath = Path.Combine(directory, "native-client-key.pending");
        try
        {
            // Crash/unknown retirement is not permission to import another key.
            marker = new FileStream(markerPath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
            WriteMarker(null);
        }
        catch
        {
            marker?.Dispose(); directoryLease.Dispose();
            throw new LinkFailure("settlement_unknown");
        }
    }

    internal static WindowsTlsClientIdentity Import(byte[] pfx, string directory, Action requireAdmission)
    {
        requireAdmission();
        if (!OperatingSystem.IsWindows() || pfx.Length is < 1 or > 65536)
            throw new LinkFailure("credential_rejected");
        var owner = new WindowsTlsClientIdentity(directory);
        try
        {
            // Do not preserve an input-supplied provider or key-container name.
            var limits = new Pkcs12LoaderLimits { PreserveKeyName = false, PreserveStorageProvider = false };
            owner.certificate = X509CertificateLoader.LoadPkcs12(pfx, null, X509KeyStorageFlags.UserKeySet, limits);
            owner.signing = owner.certificate.GetECDsaPrivateKey() as ECDsaCng
                ?? throw new LinkFailure("credential_rejected");
            owner.key = owner.signing.Key;
            if (owner.key.IsMachineKey || owner.key.IsEphemeral ||
                owner.key.Provider != CngProvider.MicrosoftSoftwareKeyStorageProvider ||
                string.IsNullOrWhiteSpace(owner.key.KeyName)) throw new LinkFailure("credential_rejected");
            owner.keyName = owner.key.KeyName;
            owner.WriteMarker(owner.keyName);
            requireAdmission();
            return owner;
        }
        catch
        {
            // A failed import remains non-authorizing. Unknown provider ownership
            // retains the marker and blocks replacement instead of guessing.
            owner.failed = owner.keyName == null;
            owner.Dispose();
            throw;
        }
    }

    private void WriteMarker(string? name)
    {
        expectedMarker = JsonSerializer.SerializeToUtf8Bytes(new
        {
            kind = "android-native-proof-client-import", version = 1,
            provider = "Microsoft Software Key Storage Provider", currentUser = true, keyName = name,
        });
        marker!.Position = 0;
        marker.SetLength(0);
        marker.Write(expectedMarker);
        marker.Flush(true);
    }

    public void Dispose()
    {
        if (closed)
        {
            if (failed) throw new LinkFailure("settlement_unknown");
            return;
        }
        closed = true;
        if (keyName == null) failed = true;
        try { key?.Delete(); } catch { failed = true; }
        try { signing?.Dispose(); } catch { failed = true; }
        try { certificate?.Dispose(); } catch { failed = true; }
        try
        {
            if (keyName != null)
            {
                if (!OperatingSystem.IsWindows()) failed = true;
                else if (CngKey.Exists(keyName, CngProvider.MicrosoftSoftwareKeyStorageProvider, CngKeyOpenOptions.None))
                    failed = true;
            }
            if (marker != null)
            {
                marker.Position = 0;
                byte[] original = new byte[expectedMarker.Length];
                marker.ReadExactly(original);
                if (marker.Length != original.Length || !original.SequenceEqual(expectedMarker)) failed = true;
            }
        }
        catch { failed = true; }
        try { marker?.Dispose(); } catch { failed = true; }
        if (!failed)
        {
            // The original directory lease still excludes other adapter writers.
            try { File.Delete(markerPath); } catch { failed = true; }
        }
        try { directoryLease.Dispose(); } catch { failed = true; }
        if (failed) throw new LinkFailure("settlement_unknown");
    }
}
