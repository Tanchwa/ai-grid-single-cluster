#!/usr/bin/env python3
"""
Terraform external data source: converts an RSA PEM public key to a JWKS JSON string.
Reads {"public_key_pem": "..."} from stdin, writes {"jwks": "<json string>"} to stdout.
Requires: pip install cryptography
"""
import base64
import hashlib
import json
import sys

try:
    from cryptography.hazmat.primitives.serialization import (
        load_pem_public_key,
        load_pem_private_key,
        Encoding,
        PublicFormat,
    )
except ImportError:
    sys.stderr.write("error: 'cryptography' package is required. Run: pip install cryptography\n")
    sys.exit(1)

data = json.load(sys.stdin)
if "private_key_pem" in data:
    private_key = load_pem_private_key(data["private_key_pem"].encode(), password=None)
    key = private_key.public_key()
else:
    key = load_pem_public_key(data["public_key_pem"].encode())

n_val = key.public_numbers()


def b64url(n: int) -> str:
    length = (n.bit_length() + 7) // 8
    return base64.urlsafe_b64encode(n.to_bytes(length, "big")).rstrip(b"=").decode()


# kid = SHA-256 of the DER-encoded SubjectPublicKeyInfo structure, base64url-encoded.
# This matches how Kubernetes (PR #78502) and the Talos IRSA docs compute the key ID.
# RFC 7638 JWK thumbprint produces a different hash and will NOT match token kids.
der_bytes = key.public_bytes(encoding=Encoding.DER, format=PublicFormat.SubjectPublicKeyInfo)
kid = base64.urlsafe_b64encode(hashlib.sha256(der_bytes).digest()).rstrip(b"=").decode()

jwks = {
    "keys": [{
        "use": "sig",
        "alg": "RS256",
        "kty": "RSA",
        "kid": kid,
        "n": b64url(n_val.n),
        "e": b64url(n_val.e),
    }]
}

print(json.dumps({"jwks": json.dumps(jwks, separators=(",", ":"))}))
