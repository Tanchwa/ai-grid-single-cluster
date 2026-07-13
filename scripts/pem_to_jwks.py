#!/usr/bin/env python3
"""
Terraform external data source: converts an RSA PEM public key to a JWKS JSON string.
Reads {"public_key_pem": "..."} from stdin, writes {"jwks": "<json string>"} to stdout.
Requires: pip install cryptography
"""
import base64
import json
import sys

try:
    from cryptography.hazmat.primitives.serialization import load_pem_public_key
except ImportError:
    sys.stderr.write("error: 'cryptography' package is required. Run: pip install cryptography\n")
    sys.exit(1)

data = json.load(sys.stdin)
key = load_pem_public_key(data["public_key_pem"].encode())
n_val = key.public_numbers()


def b64url(n: int) -> str:
    length = (n.bit_length() + 7) // 8
    return base64.urlsafe_b64encode(n.to_bytes(length, "big")).rstrip(b"=").decode()


jwks = {
    "keys": [{
        "kty": "RSA",
        "alg": "RS256",
        "use": "sig",
        "n": b64url(n_val.n),
        "e": b64url(n_val.e),
    }]
}

print(json.dumps({"jwks": json.dumps(jwks, separators=(",", ":"))}))
