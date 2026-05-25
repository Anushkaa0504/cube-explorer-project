#!/usr/bin/env python3
"""Sign a Cube JWT (HS256).

Usage:
  sign_jwt.py USER_ID [ROLE_OVERRIDE]   # data-plane JWT, signed with CUBEJS_API_SECRET
                                        # ROLE_OVERRIDE may be a comma-separated list,
                                        # e.g. "customer,marketing" — both policies apply.
  sign_jwt.py --system                  # system/orchestration JWT, signed with CUBEJS_PLAYGROUND_AUTH_SECRET
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IDENTITY = ROOT / "model" / "cubes" / "identity.json"


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def user_from_identity(uid: int) -> dict | None:
    if not IDENTITY.exists():
        return None
    data = json.loads(IDENTITY.read_text())
    for u in data.get("users", []):
        if u.get("id") == uid:
            return u
    return None


def sign(claims: dict, secret: str) -> str:
    header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64(json.dumps(claims, separators=(",", ":")).encode())
    sig = b64(hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest())
    return f"{header}.{payload}.{sig}"


def system_token() -> str:
    """Mint a JWT for /cubejs-system/v1/* endpoints (orchestration API).

    Signed with CUBEJS_PLAYGROUND_AUTH_SECRET, not CUBEJS_API_SECRET. Cube
    accepts any HS256-signed JWT here; claims content is not authorized
    further, so we keep it minimal with an issued-at + 1h expiry.
    """
    secret = os.environ.get(
        "CUBEJS_PLAYGROUND_AUTH_SECRET", "system-secret-please-change-me"
    )
    now = int(time.time())
    return sign({"iat": now, "exp": now + 3600}, secret)


def main() -> None:
    if len(sys.argv) >= 2 and sys.argv[1] == "--system":
        print(system_token())
        return

    if len(sys.argv) < 2:
        print("Usage: sign_jwt.py USER_ID [ROLE_OVERRIDE]  |  sign_jwt.py --system", file=sys.stderr)
        sys.exit(2)

    uid = int(sys.argv[1])
    role_override = sys.argv[2] if len(sys.argv) > 2 else None
    secret = os.environ.get("CUBEJS_API_SECRET", "super-secret-please-change-me")

    user = user_from_identity(uid)
    claims: dict = {"user_id": uid}

    if user:
        claims["roles"] = user.get("roles", [])
        claims["tenant_id"] = user.get("tenant_id", "default")
        claims["email"] = user.get("email")
        if user.get("country"):
            claims["country"] = user["country"]
    if role_override:
        # Allow "customer,marketing" to stack two access policies on the same user.
        roles_list = [r.strip() for r in role_override.split(",") if r.strip()]
        claims["roles"] = roles_list
        claims["role"] = roles_list[0]

    print(sign(claims, secret))


if __name__ == "__main__":
    main()
