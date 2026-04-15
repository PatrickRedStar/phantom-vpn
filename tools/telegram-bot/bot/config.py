"""Load config from .env."""
from __future__ import annotations

import os
from dataclasses import dataclass

from dotenv import load_dotenv

load_dotenv()


def _req(name: str) -> str:
    v = os.environ.get(name)
    if not v:
        raise RuntimeError(f"env var {name} is required")
    return v


@dataclass(frozen=True)
class Config:
    bot_token: str
    admin_telegram_id: int
    phantom_admin_url: str
    phantom_admin_token: str


CONFIG = Config(
    bot_token=_req("BOT_TOKEN"),
    admin_telegram_id=int(_req("ADMIN_TELEGRAM_ID")),
    phantom_admin_url=os.environ.get(
        "PHANTOM_ADMIN_URL", "http://127.0.0.1:8081"
    ).rstrip("/"),
    phantom_admin_token=_req("PHANTOM_ADMIN_TOKEN"),
)
