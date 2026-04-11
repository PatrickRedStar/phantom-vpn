"""conn_string manipulation: strip admin url/token for regular clients."""
from __future__ import annotations

import base64
import json


def _b64url_decode(s: str) -> bytes:
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def _b64url_encode(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode("ascii").rstrip("=")


def strip_admin(conn_b64: str) -> str:
    """Decode base64url → drop `admin` key → re-encode.

    The server's build_conn_string() embeds {"admin": {"url", "token"}} in
    every conn_string. For regular clients we remove it so the phone does
    not get admin panel credentials.
    """
    raw = _b64url_decode(conn_b64.strip())
    obj = json.loads(raw)
    obj.pop("admin", None)
    out = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return _b64url_encode(out)


def decode_to_dict(conn_b64: str) -> dict:
    """For debug/inspection — decode base64url into dict."""
    return json.loads(_b64url_decode(conn_b64.strip()))
