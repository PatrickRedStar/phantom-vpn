from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class InvoicePayload:
    action: str
    tg_user_id: int
    days: int
    subscription_id: str | None = None
    server_id: str | None = None
    client_name: str | None = None
    product: str = "vless"
    nonce: str = ""

    def encode(self) -> str:
        # Compact format: single-char keys, skip None fields, short nonce.
        # Telegram invoice_payload limit is 128 bytes.
        body: dict[str, Any] = {"a": self.action, "u": self.tg_user_id, "d": self.days}
        if self.product != "vless":
            body["p"] = self.product
        if self.server_id:
            body["s"] = self.server_id
        if self.client_name:
            body["c"] = self.client_name
        body["n"] = (self.nonce or uuid.uuid4().hex)[:12]
        return json.dumps(body, ensure_ascii=True, separators=(",", ":"))

    @staticmethod
    def decode(value: str) -> "InvoicePayload":
        raw: dict[str, Any] = json.loads(value)
        # Support both compact (a/u/d) and legacy (action/tg_user_id/days) keys
        action = str(raw.get("a") or raw.get("action", ""))
        tg_user_id = int(raw.get("u") or raw.get("tg_user_id", 0))
        days = int(raw.get("d") or raw.get("days", 0))
        product = str(raw.get("p") or raw.get("product") or "vless")
        server_id = raw.get("s") or raw.get("server_id")
        client_name = raw.get("c") or raw.get("client_name")
        nonce = str(raw.get("n") or raw.get("nonce") or "")
        return InvoicePayload(
            action=action,
            tg_user_id=tg_user_id,
            days=days,
            server_id=server_id,
            client_name=client_name,
            product=product,
            nonce=nonce,
        )
