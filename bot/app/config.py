from __future__ import annotations

import os
from dataclasses import dataclass
from typing import FrozenSet

from dotenv import load_dotenv


@dataclass(frozen=True)
class VpnServer:
    server_id: str
    name: str
    admin_api_base_url: str
    admin_api_token: str


@dataclass(frozen=True)
class XuiConfig:
    base_url: str
    username: str
    password: str
    inbound_ids: tuple[int, ...]
    sub_url: str


@dataclass(frozen=True)
class Settings:
    telegram_bot_token: str
    telegram_webhook_secret: str
    telegram_webhook_url: str
    telegram_provider_token: str
    database_url: str
    bot_host: str
    bot_port: int
    bot_admin_ids: FrozenSet[int]
    price_30_xtr: int
    price_90_xtr: int
    price_180_xtr: int
    vpn_servers: tuple[VpnServer, ...]
    default_server_id: str
    xui: XuiConfig | None = None


def load_settings() -> Settings:
    load_dotenv()
    vpn_servers = _parse_vpn_servers()
    if not vpn_servers:
        raise RuntimeError("No VPN servers configured")
    default_server_id = os.getenv("DEFAULT_VPN_SERVER_ID", vpn_servers[0].server_id).strip()
    if not any(s.server_id == default_server_id for s in vpn_servers):
        raise RuntimeError(f"DEFAULT_VPN_SERVER_ID '{default_server_id}' is not in configured servers")

    xui_config = _parse_xui_config()

    return Settings(
        telegram_bot_token=_required("TELEGRAM_BOT_TOKEN"),
        telegram_webhook_secret=os.getenv("TELEGRAM_WEBHOOK_SECRET", ""),
        telegram_webhook_url=os.getenv("TELEGRAM_WEBHOOK_URL", ""),
        telegram_provider_token=os.getenv("TELEGRAM_PROVIDER_TOKEN", ""),
        database_url=os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./bot.db"),
        bot_host=os.getenv("BOT_HOST", "0.0.0.0"),
        bot_port=int(os.getenv("BOT_PORT", "8090")),
        bot_admin_ids=_parse_admin_ids(os.getenv("BOT_ADMIN_IDS", "")),
        price_30_xtr=_required_int("PRICE_30_XTR"),
        price_90_xtr=_required_int("PRICE_90_XTR"),
        price_180_xtr=_required_int("PRICE_180_XTR"),
        vpn_servers=tuple(vpn_servers),
        default_server_id=default_server_id,
        xui=xui_config,
    )


def _required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required env var: {name}")
    return value


def _required_int(name: str) -> int:
    value = _required(name)
    try:
        number = int(value)
    except ValueError as exc:
        raise RuntimeError(f"Invalid int env var {name}: {value}") from exc
    if number <= 0:
        raise RuntimeError(f"Env var {name} must be > 0")
    return number


def _parse_admin_ids(raw: str) -> FrozenSet[int]:
    values: set[int] = set()
    for part in raw.split(","):
        candidate = part.strip()
        if not candidate:
            continue
        try:
            values.add(int(candidate))
        except ValueError as exc:
            raise RuntimeError(f"Invalid BOT_ADMIN_IDS value: {candidate}") from exc
    return frozenset(values)


def _parse_xui_config() -> XuiConfig | None:
    base_url = os.getenv("XUI_BASE_URL", "").strip()
    username = os.getenv("XUI_USERNAME", "").strip()
    password = os.getenv("XUI_PASSWORD", "").strip()
    sub_url = os.getenv("XUI_SUB_URL", "").strip()
    raw_ids = os.getenv("XUI_INBOUND_IDS", "").strip()
    if not all([base_url, username, password, sub_url, raw_ids]):
        return None
    try:
        inbound_ids = tuple(int(x.strip()) for x in raw_ids.split(",") if x.strip())
    except ValueError as exc:
        raise RuntimeError(f"Invalid XUI_INBOUND_IDS: {raw_ids}") from exc
    return XuiConfig(
        base_url=base_url,
        username=username,
        password=password,
        inbound_ids=inbound_ids,
        sub_url=sub_url,
    )


def _parse_vpn_servers() -> list[VpnServer]:
    raw = os.getenv("VPN_SERVERS_JSON", "").strip()
    if raw:
        import json

        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise RuntimeError("VPN_SERVERS_JSON is not valid JSON") from exc
        if not isinstance(data, list):
            raise RuntimeError("VPN_SERVERS_JSON must be a JSON array")
        servers: list[VpnServer] = []
        for item in data:
            if not isinstance(item, dict):
                raise RuntimeError("VPN_SERVERS_JSON entries must be objects")
            server_id = str(item.get("id", "")).strip()
            name = str(item.get("name", "")).strip() or server_id
            base_url = str(item.get("admin_api_base_url", "")).strip()
            token = str(item.get("admin_api_token", "")).strip()
            if not server_id or not base_url or not token:
                raise RuntimeError("Each VPN server must have id, admin_api_base_url, admin_api_token")
            servers.append(
                VpnServer(
                    server_id=server_id,
                    name=name,
                    admin_api_base_url=base_url,
                    admin_api_token=token,
                ),
            )
        return servers

    # Backward-compatible single server fallback
    base_url = os.getenv("ADMIN_API_BASE_URL", "").strip()
    token = os.getenv("ADMIN_API_TOKEN", "").strip()
    if base_url and token:
        return [
            VpnServer(
                server_id="default",
                name="Default",
                admin_api_base_url=base_url,
                admin_api_token=token,
            ),
        ]
    return []

