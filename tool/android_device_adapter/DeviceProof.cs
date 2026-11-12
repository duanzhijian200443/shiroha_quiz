using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Net.Security;
using static Shiroha.AndroidDevice.DeviceClient;

namespace Shiroha.AndroidDevice;

// Same original proof exchange, independent of routing and persistence.
internal static class DeviceProof
{
    internal sealed record Binding(string Profile, string Installation, int Revision);
    internal static async Task<Binding> Exchange(SslStream tls, X509Certificate2 client,
        DeviceTarget target, JsonElement record, string mode, CancellationToken establishment,
        CancellationToken stop, Action<string> enter, Action<string>? observeFingerprint = null)
    {
        string device = target.DeviceId, pin = target.CertificateDigest, profile = target.ProfileId;
        string? installation = record.GetProperty("installationId").GetString();
        enter("hello");
        string clientNonce = Nonce();
        await LinkFrames.Write(tls, 1, JsonSerializer.SerializeToUtf8Bytes(new {
            type = "hello", purpose = mode, expectedDeviceId = device,
            expectedProfileId = mode == "pairing" ? null : profile, clientNonce, linkVersions = new[] { 1 }
        }), false, establishment);
        enter("offer");
        var offerFrame = await LinkFrames.Read(tls, true, establishment);
        using var offerDocument = LinkFrames.StrictObject(offerFrame.Body);
        var offer = offerDocument.RootElement;
        Fields(offer, ["type", "purpose", "deviceId", "installationId", "profileId", "runtimeId", "connectionId", "clientNonce", "serverNonce", "clientCertificateDigest", "serverCertificateDigest", "associationRevision"]);
        string actualClient = Convert.ToHexStringLower(SHA256.HashData(client.RawData));
        if (offerFrame.Kind != 1 || Text(offer, "type") != "offer" || Text(offer, "purpose") != mode ||
            Text(offer, "deviceId") != device ||
            (installation != null && Text(offer, "installationId") != installation) ||
            !Guid.TryParseExact(Text(offer, "installationId"), "D", out _) ||
            Text(offer, "serverCertificateDigest") != pin || Text(offer, "clientCertificateDigest") != actualClient ||
            Text(offer, "clientNonce") != clientNonce ||
            !Guid.TryParseExact(Text(offer, "profileId"), "D", out _) ||
            !Guid.TryParseExact(Text(offer, "runtimeId"), "D", out _) ||
            !Guid.TryParseExact(Text(offer, "connectionId"), "D", out _) ||
            !IsNonce(Text(offer, "serverNonce")) ||
            (mode != "pairing" && Text(offer, "profileId") != profile)) throw new LinkFailure("device_mismatch");
        if (mode != "pairing" && offer.GetProperty("associationRevision").GetInt32() != record.GetProperty("associationRevision").GetInt32())
            throw new LinkFailure("stale_revision");
        string connectionId = Text(offer, "connectionId"), serverNonce = Text(offer, "serverNonce");
        profile = Text(offer, "profileId");
        installation = Text(offer, "installationId");
        observeFingerprint?.Invoke(actualClient);
        Console.WriteLine(JsonSerializer.Serialize(new { stage = "verified-offer", deviceId = device,
            certificateDigest = pin, clientCertificateDigest = actualClient, installationId = installation, profileId = profile,
            action = mode == "pairing" ? "Compare the full client fingerprint and confirm on the phone" : "Waiting for original P15 confirmation and settlement" }));
        enter("proof");
        var proofFrame = await LinkFrames.Read(tls, true, stop);
        using var proofDocument = LinkFrames.StrictObject(proofFrame.Body);
        var proof = proofDocument.RootElement;
        Fields(proof, ["type", "connectionId", "clientNonce", "serverNonce", "profileId", "associationRevision", "settlementNonce"]);
        if (proofFrame.Kind != 1 || Text(proof, "type") != "proof-complete" || Text(proof, "connectionId") != connectionId ||
            Text(proof, "clientNonce") != clientNonce || Text(proof, "serverNonce") != serverNonce ||
            Text(proof, "profileId") != profile || proof.GetProperty("associationRevision").GetInt32() < 1)
            throw new LinkFailure("protocol_violation");
        string settlementNonce = Text(proof, "settlementNonce");
        if (!IsNonce(settlementNonce)) throw new LinkFailure("protocol_violation");
        if (mode == "enable-proof" && proof.GetProperty("associationRevision").GetInt32() != record.GetProperty("associationRevision").GetInt32())
            throw new LinkFailure("stale_revision");
        enter("settlement");
        using var closing = CancellationTokenSource.CreateLinkedTokenSource(stop);
        closing.CancelAfter(TimeSpan.FromSeconds(5));
        await LinkFrames.Write(tls, 1, JsonSerializer.SerializeToUtf8Bytes(new { type = "closing", connectionId, clientNonce, serverNonce, settlementNonce }), false, closing.Token);
        await tls.ShutdownAsync().WaitAsync(closing.Token);
        byte[] one = new byte[1];
        if (await tls.ReadAsync(one, closing.Token) != 0) throw new LinkFailure("settlement_unknown");
        return new Binding(profile, installation!, proof.GetProperty("associationRevision").GetInt32());
    }
}
