"""Read-only, stdlib-only independent framing/hash/P-256 fixture verification.

Uses no production codec, signing API, generated identity, native security
operation or network. The public RFC6979 key and P21 certificates stay pinned.
"""
from pathlib import Path
import hashlib
import json
import re
import struct

ROOT = Path(__file__).resolve().parents[2]
V = json.loads((ROOT / "test/data/external/fixtures/bootstrap_v1.json").read_text(encoding="utf8"))


def blob(name):
    return bytes.fromhex(V[name])


def number(name):
    return int(V[name])


def field(value):
    return struct.pack("<H", len(value)) + value


def u64(name):
    return struct.pack("<Q", number(name))


# P-256 standard domain parameters; verifier only (no signing or key creation).
P = int("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff", 16)
N = int("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)
B = int("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b", 16)
G = (int("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296", 16),
     int("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5", 16))


def add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0:
        return None
    slope = (((3 * a[0] * a[0] - 3) * pow(2 * a[1], -1, P)) if a == b
             else ((b[1] - a[1]) * pow(b[0] - a[0], -1, P))) % P
    x = (slope * slope - a[0] - b[0]) % P
    return x, (slope * (a[0] - x) - a[1]) % P


def multiply(k, point):
    result = None
    while k:
        if k & 1:
            result = add(result, point)
        point = add(point, point)
        k >>= 1
    return result


def verify(digest, signature):
    point = blob("point")
    x, y = int.from_bytes(point[1:33], "big"), int.from_bytes(point[33:], "big")
    assert len(point) == 65 and point[0] == 4
    assert x < P and y < P and (y*y - x*x*x + 3*x - B) % P == 0
    r, s = int.from_bytes(signature[:32], "big"), int.from_bytes(signature[32:], "big")
    if len(signature) != 64 or not (0 < r < N and 0 < s < N):
        return False
    w = pow(s, -1, N)
    check = add(multiply(int.from_bytes(digest, "big") * w % N, G), multiply(r*w % N, (x, y)))
    return check is not None and check[0] % N == r


def require(condition):
    if not condition:
        raise SystemExit("FAIL: P22 independent fixture validation")


def main():
    old = (ROOT / "test/data/external/external_certificate_der_test.dart").read_text(encoding="utf8")
    for name, old_name in [("point", "_pointHex"), ("issuerDer", "_issuerCertHex"),
                           ("serverDer", "_serverCertHex"), ("clientDer", "_clientCertHex")]:
        match = re.search(r"const " + old_name + r"\s*=\s*(.*?);", old, re.S)
        require(blob(name) == bytes.fromhex("".join(re.findall(r"'([0-9a-f]+)'", match[1]))))
    installation = field(V["installationId"].encode("utf8"))
    identity = hashlib.sha256(blob("clientDer")).digest()
    server = hashlib.sha256(blob("serverDer")).digest()
    require(blob("credentialIdentity") == identity and blob("serverLeafDigest") == server)
    transcript = (b"SHIROHA-EXTERNAL-PROOF-V1\0\1" + blob("nonce") + blob("requestId")
                  + blob("profileId") + installation + u64("generation") + blob("runtimeInstanceId")
                  + identity + u64("expectedRevision") + u64("expiresAtUtcMs"))
    unsigned = (b"SHREXEPD\1" + blob("runtimeInstanceId") + u64("publicationEpoch")
                + u64("generation") + struct.pack("<H", V["port"]) + server
                + installation + u64("publishedAtUtcMs"))
    require(transcript == blob("transcript") and len(transcript) == 201)
    require(unsigned == blob("descriptorUnsigned") and len(unsigned) == 121)
    require(unsigned + blob("descriptorSignature") == blob("descriptor"))
    for message, digest_name, signature_name in [
        (transcript, "transcriptDigest", "transcriptSignature"),
        (b"SHIROHA-EXTERNAL-ENDPOINT-V1\0" + unsigned, "descriptorDigest", "descriptorSignature")]:
        digest = hashlib.sha256(message).digest()
        signature = blob(signature_name)
        require(digest == blob(digest_name) and verify(digest, signature))
        for i in range(len(message)):
            wrong = bytearray(message)
            wrong[i] ^= 1
            require(not verify(hashlib.sha256(wrong).digest(), signature))
    submission = (b"SHREXSUB\1" + blob("submissionId") + blob("point")
                  + field(V["displayLabel"].encode()) + field(V["clientBuild"].encode()))
    challenge = (b"SHREXCHA\1" + blob("submissionId") + blob("requestId") + blob("nonce")
                 + blob("profileId") + installation + u64("generation") + blob("runtimeInstanceId")
                 + u64("publicationEpoch") + identity + u64("expectedRevision") + u64("expiresAtUtcMs")
                 + field(blob("clientDer")))
    proof = b"SHREXPRF\1" + blob("submissionId") + blob("requestId") + blob("transcriptSignature")
    require(submission == blob("submission") and challenge == blob("challenge") and proof == blob("proof"))
    print("PASS: independent framing/SHA256/ECDSA, P21 fixture reuse and 351 byte-tamper rejections")


if __name__ == "__main__":
    main()
