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
    roles_path: str


CONFIG = Config(
    bot_token=_req("BOT_TOKEN"),
    admin_telegram_id=int(_req("ADMIN_TELEGRAM_ID")),
    phantom_admin_url=_req("PHANTOM_ADMIN_URL").rstrip("/"),
    phantom_admin_token=_req("PHANTOM_ADMIN_TOKEN"),
    roles_path=os.environ.get("ROLES_PATH", "/data/roles.json"),
)
