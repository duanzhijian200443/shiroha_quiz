using System.IO.Pipes;
using System.Net;
using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace Shiroha.AndroidDevice;

// Explicit isolated Windows fixture: generated identities, DPAPI objects and
// duplex pipes only. No phone, installed Link slot or TCP connection is used.
internal static class DeviceAddressRefreshTests
{
    private static string stage = "configuration";
    private static void Check(bool value) { if (!value) throw new Exception("address_fixture_failed"); }
    private static void Reject(Action work, string code)
    {
        try { work(); }
        catch (LinkFailure error) when (error.Code == code) { return; }
        throw new Exception("address_fixture_expected_refusal");
    }
    private static string Digest(byte[] value) => Convert.ToHexStringLower(SHA256.HashData(value));
    private static void Admission() { }
    private const string Profile = "10000000-0000-4000-8000-000000000001";
    private const string Installation = "20000000-0000-4000-8000-000000000001";

    internal static async Task<int> Run()
    {
        if (!OperatingSystem.IsWindows()) return 78;
        string root = Path.Combine(AppContext.BaseDirectory, "address-fixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var originalOutput = Console.Out;
        bool complete = false;
        Console.SetOut(TextWriter.Null); // Never print test certificates/identities.
        try
        {
            using var serverKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            var request = new CertificateRequest("CN=Shiroha isolated server", serverKey, HashAlgorithmName.SHA256);
            request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
            request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
            request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.1") }, true));
            using var serverLeaf = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddHours(1));
            byte[] serverPfx = serverLeaf.Export(X509ContentType.Pfx);
            byte[] clientPfx = ProtectedDeviceStore.CreateClientIdentity(Admission);
            var target = new DeviceTarget(Digest(serverKey.ExportSubjectPublicKeyInfo()), Digest(serverLeaf.RawData),
                Profile, IPAddress.Parse("192.168.1.2"), 46443);
            byte[] paired = JsonSerializer.SerializeToUtf8Bytes(new {
                purpose = "android-read", clientPfx = Convert.ToBase64String(clientPfx),
                deviceId = target.DeviceId, certificateDigest = target.CertificateDigest,
                installationId = Installation, profileId = Profile, associationRevision = 7,
                address = target.Address.ToString(), port = 46443
            });
            try
            {
                using var record = LinkFrames.StrictObject(paired);
                using (var server = WindowsTlsClientIdentity.Import(serverPfx, Path.Combine(root, "server"), Admission))
                using (var client = WindowsTlsClientIdentity.Import(clientPfx, Path.Combine(root, "client"), Admission))
                {
                    foreach (string variant in new[] { "original", "candidate", "pin", "device", "installation",
                        "profile", "offer-revision", "proof-revision", "tls-deadline" })
                    {
                        stage = variant;
                        await Exchange(target, record.RootElement, server.Certificate, client.Certificate, variant);
                    }
                    stage = "v2-route-proof";
                    await V2RouteProof(root, paired, target, server.Certificate, record.RootElement);
                }
                Check(!File.Exists(Path.Combine(root, "client", "native-client-key.pending")));
                Check(!File.Exists(Path.Combine(root, "server", "native-client-key.pending")));
                Check(DeviceClient.RecoveryReport("tls", "deadline") == "SHIROHA_ANDROID_RECOVERY|P|tls|deadline");
                Check(DeviceClient.RecoveryReport("settlement-receipt", "io") == "SHIROHA_ANDROID_RECOVERY|P|settlement-receipt|io");
                stage = "persistence";
                Persistence(root, paired, record.RootElement);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(serverPfx);
                CryptographicOperations.ZeroMemory(clientPfx);
                CryptographicOperations.ZeroMemory(paired);
            }
            Console.SetOut(originalOutput);
            complete = true;
            Console.WriteLine("PASS: address refresh isolated Windows mTLS (9 cases), CNG retirement, DPAPI CAS/interruption, v2 refusal, real sealed v2 provenance and run-only candidate routing (8 cases); no device/TCP/installation");
            return 0;
        }
        catch (Exception error)
        {
            Console.SetOut(originalOutput);
            string category = error is LinkFailure link ? link.Code :
                error is IOException ? "io" : error is UnauthorizedAccessException ? "access" : "assertion";
            Console.Error.WriteLine($"address_refresh_fixture_failed stage={stage} category={category}");
            return 79;
        }
        finally
        {
            Console.SetOut(originalOutput);
            // Only this fixture's newly generated child is eligible for cleanup.
            if (complete) Directory.Delete(root, true);
        }
    }

    private static async Task Exchange(DeviceTarget original, JsonElement record,
        X509Certificate2 serverCertificate, X509Certificate2 clientCertificate, string variant)
    {
        var target = original with { Address = IPAddress.Parse("192.168.15.147") };
        if (variant == "original") target = original;
        if (variant == "pin") target = target with { CertificateDigest = new string('0', 64) };
        if (variant == "device") target = target with { DeviceId = new string('0', 64) };
        string pipeName = "shiroha-address-fixture-" + Guid.NewGuid().ToString("N");
        using var serverPipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        using var clientPipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        await Task.WhenAll(serverPipe.WaitForConnectionAsync(deadline.Token), clientPipe.ConnectAsync(deadline.Token));
        bool peerVerified = false, proofSettled = false;
        var serving = Task.Run(async () =>
        {
            try
            {
                if (variant == "tls-deadline") {
                    await Task.Delay(Timeout.Infinite, deadline.Token);
                    return;
                }
                using var tls = new SslStream(serverPipe, true, (_, certificate, _, _) => {
                    peerVerified = certificate != null && Digest(certificate.GetRawCertData()) == Digest(clientCertificate.RawData);
                    return peerVerified;
                });
                await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions {
                    ServerCertificate = serverCertificate, ClientCertificateRequired = true,
                    EnabledSslProtocols = SslProtocols.Tls13, AllowTlsResume = false,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck
                }, deadline.Token);
                Check(tls.IsMutuallyAuthenticated);
                var hello = await LinkFrames.Read(tls, false, deadline.Token);
                using var document = LinkFrames.StrictObject(hello.Body);
                string nonce = DeviceClient.Text(document.RootElement, "clientNonce");
                string serverNonce = DeviceClient.Nonce(), settlementNonce = DeviceClient.Nonce();
                string connection = Guid.NewGuid().ToString("D");
                await LinkFrames.Write(tls, 1, JsonSerializer.SerializeToUtf8Bytes(new {
                    type = "offer", purpose = "enable-proof", deviceId = original.DeviceId,
                    installationId = variant == "installation" ? Guid.NewGuid().ToString("D") : Installation,
                    profileId = variant == "profile" ? Guid.NewGuid().ToString("D") : Profile,
                    runtimeId = Guid.NewGuid().ToString("D"), connectionId = connection,
                    clientNonce = nonce, serverNonce, clientCertificateDigest = Digest(clientCertificate.RawData),
                    serverCertificateDigest = original.CertificateDigest, associationRevision = variant == "offer-revision" ? 8 : 7
                }), true, deadline.Token);
                await LinkFrames.Write(tls, 1, JsonSerializer.SerializeToUtf8Bytes(new {
                    type = "proof-complete", connectionId = connection, clientNonce = nonce, serverNonce,
                    profileId = Profile, associationRevision = variant == "proof-revision" ? 8 : 7, settlementNonce
                }), true, deadline.Token);
                var closing = await LinkFrames.Read(tls, false, deadline.Token);
                using var closed = LinkFrames.StrictObject(closing.Body);
                Check(DeviceClient.Text(closed.RootElement, "settlementNonce") == settlementNonce);
                Check(await tls.ReadAsync(new byte[1], deadline.Token) == 0);
                await tls.ShutdownAsync().WaitAsync(deadline.Token);
                proofSettled = true;
            }
            catch when (variant is not ("original" or "candidate")) { }
        });
        string? failure = null;
        try
        {
            using var establishment = CancellationTokenSource.CreateLinkedTokenSource(deadline.Token);
            if (variant == "tls-deadline") establishment.CancelAfter(TimeSpan.FromMilliseconds(150));
            using var tls = await DeviceTransport.AuthenticatePinned(clientPipe, target, clientCertificate, establishment.Token, Admission);
            var binding = await DeviceProof.Exchange(tls, clientCertificate, target, record, "enable-proof",
                establishment.Token, deadline.Token, _ => { });
            Check(binding.Profile == Profile && binding.Installation == Installation && binding.Revision == 7);
        }
        catch (LinkFailure error) { failure = error.Code; }
        catch (AuthenticationException) { failure = "tls"; }
        catch (OperationCanceledException) { failure = "deadline"; }
        finally { deadline.Cancel(); await serving; }
        switch (variant)
        {
            case "original": case "candidate": Check(failure == null && peerVerified && proofSettled); break;
            case "pin": case "device": Check(failure == "tls" && !proofSettled); break;
            case "offer-revision": case "proof-revision": Check(failure == "stale_revision" && !proofSettled); break;
            case "tls-deadline": Check(failure == "deadline" && !proofSettled); break;
            default: Check(failure == "device_mismatch" && !proofSettled); break;
        }
    }

    private static void Persistence(string root, byte[] paired, JsonElement record)
    {
        var custody = JsonSerializer.SerializeToElement(new {
            formatVersion = 1, ownershipState = "LINK_OWNED", ownerKind = "independent_link",
            adapterCredentialSlotRef = "device.dpapi"
        });
        DeviceAddressRefresh.RequireV1(custody);
        var sealedCustody = JsonSerializer.SerializeToElement(new { formatVersion = 2 });
        Reject(() => DeviceAddressRefresh.RequireV1(sealedCustody), "address_update_unsupported");
        string slot = Path.Combine(root, "slot");
        Directory.CreateDirectory(slot);
        void RequireSlot() => DeviceAddressRefresh.RequireV1(custody);
        ProtectedDeviceStore.Create(slot, paired, Admission, RequireSlot);
        byte[] oldCiphertext = File.ReadAllBytes(Path.Combine(slot, "device.dpapi"));
        byte[] updated = DeviceAddressRefresh.Replacement(record, IPAddress.Parse("192.168.15.147"));
        try
        {
            using var next = LinkFrames.StrictObject(updated);
            foreach (var field in record.EnumerateObject())
                Check(field.Name == "address" || field.Value.GetRawText() == next.RootElement.GetProperty(field.Name).GetRawText());
            byte[] wrongIdentity = JsonSerializer.SerializeToUtf8Bytes(new {
                purpose = "android-read", clientPfx = DeviceClient.Text(record, "clientPfx"),
                deviceId = new string('0', 64), certificateDigest = DeviceClient.Text(record, "certificateDigest"),
                installationId = Installation, profileId = Profile, associationRevision = 7,
                address = "192.168.15.147", port = 46443
            });
            try { Reject(() => ProtectedDeviceStore.ReplaceAddress(slot, paired, wrongIdentity, Admission, RequireSlot), "device_mismatch"); }
            finally { CryptographicOperations.ZeroMemory(wrongIdentity); }
            // Interrupted publication cannot overwrite either the old file or
            // original pending. No clean/success record is produced.
            File.WriteAllText(Path.Combine(slot, "device.pending"), "interrupted-fixture");
            Reject(() => ProtectedDeviceStore.ReplaceAddress(slot, paired, updated, Admission, RequireSlot), "credential_commit_unknown");
            Check(File.ReadAllBytes(Path.Combine(slot, "device.dpapi")).SequenceEqual(oldCiphertext));
            File.Delete(Path.Combine(slot, "device.pending"));
            byte[] stale = DeviceAddressRefresh.Replacement(record, IPAddress.Parse("192.168.1.3"));
            try { Reject(() => ProtectedDeviceStore.ReplaceAddress(slot, stale, updated, Admission, RequireSlot), "stale_revision"); }
            finally { CryptographicOperations.ZeroMemory(stale); }
            Check(File.ReadAllBytes(Path.Combine(slot, "device.dpapi")).SequenceEqual(oldCiphertext));
            using (var held = new FileStream(Path.Combine(slot, "adapter.lock"), FileMode.Open, FileAccess.ReadWrite, FileShare.None)) {
                try { ProtectedDeviceStore.ReplaceAddress(slot, paired, updated, Admission, RequireSlot); throw new Exception("lock_bypassed"); }
                catch (IOException) { }
            }
            // Sealed v2 fails at the credential owner boundary before mutation.
            Reject(() => ProtectedDeviceStore.ReplaceAddress(slot, paired, updated, Admission,
                () => DeviceAddressRefresh.RequireV1(sealedCustody)), "address_update_unsupported");
            Check(File.ReadAllBytes(Path.Combine(slot, "device.dpapi")).SequenceEqual(oldCiphertext));
            ProtectedDeviceStore.ReplaceAddress(slot, paired, updated, Admission, RequireSlot);
            Reject(() => ProtectedDeviceStore.ReplaceAddress(slot, paired, updated, Admission, RequireSlot), "stale_revision");
            byte[] actual = ProtectedDeviceStore.Read(slot, Admission, RequireSlot);
            try { Check(actual.SequenceEqual(updated)); }
            finally { CryptographicOperations.ZeroMemory(actual); }
            Check(!File.Exists(Path.Combine(slot, "device.pending")));

            // Actual interruption at the atomic publication boundary: Windows
            // denies replacement while this original target disallows delete.
            string blocked = Path.Combine(root, "blocked-slot");
            Directory.CreateDirectory(blocked);
            ProtectedDeviceStore.Create(blocked, paired, Admission, RequireSlot);
            string targetPath = Path.Combine(blocked, "device.dpapi");
            byte[] before = File.ReadAllBytes(targetPath);
            try
            {
                stage = "publish-denied";
                using (var reader = new FileStream(targetPath, FileMode.Open, FileAccess.Read, FileShare.Read))
                    Reject(() => ProtectedDeviceStore.ReplaceAddress(blocked, paired, updated, Admission, RequireSlot), "credential_commit_unknown");
                stage = "publish-old-preserved";
                Check(File.ReadAllBytes(targetPath).SequenceEqual(before));
                stage = "publish-pending-preserved";
                Check(File.Exists(Path.Combine(blocked, "device.pending")));
                stage = "publish-retry-refused";
                Reject(() => ProtectedDeviceStore.ReplaceAddress(blocked, paired, updated, Admission, RequireSlot), "credential_commit_unknown");
                stage = "publish-retry-old-preserved";
                Check(File.ReadAllBytes(targetPath).SequenceEqual(before));
            }
            finally { CryptographicOperations.ZeroMemory(before); }
        }
        finally { CryptographicOperations.ZeroMemory(updated); CryptographicOperations.ZeroMemory(oldCiphertext); }
    }

    private static async Task V2RouteProof(string root, byte[] paired, DeviceTarget original,
        X509Certificate2 serverCertificate, JsonElement record)
    {
        // The run-only v2 routing proof admits sealed LINK_OWNED custody and
        // never rewrites the sealed package; persistent refresh still refuses v2.
        var sealedOwned = JsonSerializer.SerializeToElement(new {
            formatVersion = 2, ownershipState = "LINK_OWNED", ownerKind = "independent_link",
            adapterCredentialSlotRef = "device.dpapi"
        });
        DeviceAddressRefresh.RequireV2(sealedOwned);
        Reject(() => DeviceAddressRefresh.RequireV2(JsonSerializer.SerializeToElement(new {
            formatVersion = 1, ownershipState = "LINK_OWNED", ownerKind = "independent_link",
            adapterCredentialSlotRef = "device.dpapi"
        })), "owner_conflict");
        Reject(() => DeviceAddressRefresh.RequireV2(JsonSerializer.SerializeToElement(new {
            formatVersion = 2, ownershipState = "SEALED", ownerKind = "independent_link",
            adapterCredentialSlotRef = "device.dpapi"
        })), "owner_conflict");
        Reject(() => DeviceAddressRefresh.RequireV1(sealedOwned), "address_update_unsupported");

        // Seal a REAL v2 package through the original producer path, so the
        // routing read genuinely runs RegistrationCustody.Verify instead of
        // skipping it for want of a custody record.
        string slot = Path.Combine(root, "v2-route-slot");
        Directory.CreateDirectory(slot);
        var registration = new { registrarInstanceId = "registrar", operationId = "registration",
            generation = "generation", runId = "run", resourceId = "resource" };
        var binding = new { deviceIdentity = original.DeviceId, installationIdentity = Installation,
            profileReference = Profile };
        var fields = new Dictionary<string, object?> {
            ["formatVersion"] = 2, ["slotRef"] = "slot", ["operationId"] = "registration",
            ["initializationSource"] = "registered_pairing", ["ownershipState"] = "REGISTERING",
            ["ownerKind"] = "independent_registrar", ["ownerInstanceId"] = "registrar",
            ["ownerGeneration"] = "generation", ["verifiedInstallationBinding"] = null,
            ["adapterCredentialSlotRef"] = null, ["resourceGeneration"] = "resource",
            ["lastSettlementRef"] = null, ["lastSettlementState"] = "UNKNOWN", ["revision"] = 0,
            ["registration"] = registration, ["sourceDigest"] = null, ["adoption"] = null
        };
        JsonElement Custody() => JsonSerializer.SerializeToElement(fields);
        RegistrationCustody.Publish(slot, "registration-attempt.json",
            JsonSerializer.SerializeToElement(new { formatVersion = 1, slotRef = "slot", registration }));
        void RegistrarSlot() => SlotFence.RequireOwnerRecord(Custody(), "registrar", "slot",
            "registration", "resource", true, registering: true);
        ProtectedDeviceStore.Create(slot, paired, Admission, RegistrarSlot);
        string credentialDigest = RegistrationCustody.Digest(slot, "device.dpapi");
        var clientBinding = RegistrationCustody.CredentialBinding(record);
        var receipt = JsonSerializer.SerializeToElement(new {
            formatVersion = 2, operationId = "registration", receiptRef = "resource", runId = "run",
            resourceId = "resource", processId = Environment.ProcessId, processStarted = "123456",
            slotRef = "slot", owner = "registrar", mode = "pairing", target = binding,
            targetClose = true, tlsShutdown = true, keyRetired = true });
        RegistrationCustody.Produce(slot, Custody(), receipt, clientBinding.Revision,
            clientBinding.ClientDigest, credentialDigest);
        RegistrationCustody.Publish(slot, "registration-joined.json", JsonSerializer.SerializeToElement(new {
            formatVersion = 1, operationId = "registration", slotRef = "slot", ownerInstanceId = "registrar",
            runId = "run", resourceId = "resource", processId = Environment.ProcessId, processStarted = "123456",
            adapterReceiptRef = "resource", target = binding, processExitCode = 0,
            stdinClosed = true, stdoutDrained = true, stderrDrained = true }));
        var files = new Dictionary<string, object?>();
        foreach (string name in RegistrationCustody.SourceFiles) files[name] = RegistrationCustody.Digest(slot, name);
        RegistrationCustody.Publish(slot, "registration-source.json",
            JsonSerializer.SerializeToElement(new { formatVersion = 1, slotRef = "slot", registration, files }));
        fields["ownershipState"] = "LINK_OWNED"; fields["ownerKind"] = "independent_link";
        fields["ownerInstanceId"] = "link"; fields["operationId"] = "adoption";
        fields["ownerGeneration"] = "adoption"; fields["verifiedInstallationBinding"] = binding;
        fields["adapterCredentialSlotRef"] = "device.dpapi"; fields["resourceGeneration"] = "business";
        fields["lastSettlementRef"] = "resource"; fields["lastSettlementState"] = "CLEAN";
        fields["adoption"] = new { connectorInstanceId = "link", operationId = "adoption" };
        fields["sourceDigest"] = RegistrationCustody.Digest(slot, "registration-source.json");
        File.WriteAllText(Path.Combine(slot, "slot-ownership.json"), Custody().GetRawText());
        void LinkSlot() => SlotFence.RequireOwnerRecord(Custody(), "link", "slot", "adoption", "business", false);
        DeviceAddressRefresh.RequireV2(Custody());

        var sealedFiles = new List<string> { "device.dpapi", "slot-ownership.json", "registration-source.json" };
        sealedFiles.AddRange(RegistrationCustody.SourceFiles);
        var before = new Dictionary<string, byte[]>();
        foreach (string name in sealedFiles) before[name] = File.ReadAllBytes(Path.Combine(slot, name));
        Check(before.Count == 7);
        void Unchanged()
        {
            foreach (string name in sealedFiles)
                Check(File.ReadAllBytes(Path.Combine(slot, name)).SequenceEqual(before[name]));
            foreach (string name in new[] { "device.pending", "native-client-key.pending",
                "link-settlement.pending", "adapter-origin.pending", "slot-ownership.pending" })
                Check(!File.Exists(Path.Combine(slot, name)));
        }

        // Real sealed provenance verification on the routing read path.
        byte[] clear = ProtectedDeviceStore.Read(slot, Admission, LinkSlot);
        string clientPfx;
        try
        {
            Check(clear.SequenceEqual(paired));
            using var sealedRecord = LinkFrames.StrictObject(clear);
            clientPfx = DeviceClient.Text(sealedRecord.RootElement, "clientPfx");
        }
        finally { CryptographicOperations.ZeroMemory(clear); }
        Unchanged();
        // A tampered source must fail closed, proving Verify is not decorative.
        string tampered = Path.Combine(slot, "registration-receipt.json");
        byte[] originalReceipt = File.ReadAllBytes(tampered);
        try
        {
            File.WriteAllBytes(tampered, originalReceipt.Concat(new byte[] { 32 }).ToArray());
            Reject(() => {
                byte[] leaked = ProtectedDeviceStore.Read(slot, Admission, LinkSlot);
                CryptographicOperations.ZeroMemory(leaked);
            }, "source_changed");
        }
        finally { File.WriteAllBytes(tampered, originalReceipt); }
        Unchanged();

        // The candidate drives real pinned mTLS with the credential read out of
        // the sealed package. Routing performs no address persistence, so every
        // sealed byte and the original owner binding survive each variant.
        byte[] sealedPfx = Convert.FromBase64String(clientPfx);
        try
        {
            using var identity = WindowsTlsClientIdentity.Import(sealedPfx,
                Path.Combine(root, "v2-route-client"), Admission);
            foreach (string variant in new[] { "candidate", "pin", "device", "installation",
                "profile", "offer-revision", "proof-revision", "tls-deadline" })
            {
                stage = "v2-route-" + variant;
                await Exchange(original, record, serverCertificate, identity.Certificate, variant);
                Unchanged();
            }
        }
        finally { CryptographicOperations.ZeroMemory(sealedPfx); }
        Check(!File.Exists(Path.Combine(root, "v2-route-client", "native-client-key.pending")));

        // Production route-only entry still requires a real runtime owner. With
        // no LinkAdapterContext it must refuse and write nothing. The successful
        // route branch needs the relay-authenticated adapter parent, which this
        // isolated fixture deliberately does not have.
        stage = "v2-route-owner-required";
        Check(DeviceClient.Run("enable-proof", slot, "192.168.15.147", 3, null, routeOnly: true)
            .GetAwaiter().GetResult() != 0);
        Unchanged();
    }
}
