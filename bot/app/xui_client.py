from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from dataclasses import dataclass
from typing import Any, Optional

import httpx

logger = logging.getLogger(__name__)


class XuiApiError(RuntimeError):
    pass


@dataclass(frozen=True)
class VlessUser:
    email: str
    client_uuid: str
    sub_url: str
    expiry_time: int  # ms, 0 = unlimited


class XuiApiClient:
    """HTTP client for 3x-ui panel REST API."""

    def __init__(
        self,
        base_url: str,
        username: str,
        password: str,
        inbound_ids: list[int],
        sub_url: str,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.inbound_ids = inbound_ids
        self.sub_url = sub_url.rstrip("/")
        # 3x-ui API lives at {webBasePath}{webBasePath}api/...
        # e.g. with webBasePath=/panel/ → /panel/panel/api/...
        # base_url is the webBasePath (e.g. https://host:2053/panel)
        # Extract the path suffix and double it for API prefix
        from urllib.parse import urlparse
        parsed = urlparse(self.base_url)
        path = parsed.path.rstrip("/")
        self._api_prefix = self.base_url.rstrip("/") + path + "/api"
        self._http = httpx.AsyncClient(verify=False, timeout=15.0)
        self._logged_in = False

    async def close(self) -> None:
        await self._http.aclose()

    async def login(self) -> None:
        # Login URL is at webBasePath/login, e.g. /panel/login
        # base_url is like https://host:2053/panel (= webBasePath)
        url = self.base_url.rstrip("/") + "/login"
        resp = await self._http.post(
            url,
            data={"username": self.username, "password": self.password},
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        body = resp.json()
        if not body.get("success"):
            raise XuiApiError(f"3x-ui login failed: {body.get('msg', resp.text)}")
        self._logged_in = True
        logger.info("xui_logged_in")

    async def _ensure_session(self) -> None:
        if not self._logged_in:
            await self.login()

    async def _api(self, method: str, path: str, **kwargs: Any) -> Any:
        await self._ensure_session()
        url = f"{self._api_prefix}{path}"
        for attempt in range(3):
            resp = await self._http.request(method, url, **kwargs)
            if resp.status_code == 404 or resp.status_code == 401:
                # Session expired — re-login once
                if attempt < 2:
                    await self.login()
                    continue
            if resp.status_code >= 400:
                raise XuiApiError(f"3x-ui {resp.status_code}: {resp.text[:200]}")
            body = resp.json()
            if not body.get("success"):
                raise XuiApiError(f"3x-ui error: {body.get('msg', '')}")
            return body.get("obj")
        raise XuiApiError("3x-ui: max retries exceeded")

    # ── Low-level API ──

    async def list_inbounds(self) -> list[dict[str, Any]]:
        result = await self._api("GET", "/inbounds/list")
        return result if isinstance(result, list) else []

    async def get_inbound(self, inbound_id: int) -> dict[str, Any]:
        result = await self._api("GET", f"/inbounds/get/{inbound_id}")
        return result if isinstance(result, dict) else {}

    async def add_client(self, inbound_id: int, client: dict[str, Any]) -> None:
        settings_str = json.dumps({"clients": [client]})
        await self._api(
            "POST",
            "/inbounds/addClient",
            json={"id": inbound_id, "settings": settings_str},
        )

    async def update_client(self, inbound_id: int, client_uuid: str, client: dict[str, Any]) -> None:
        settings_str = json.dumps({"clients": [client]})
        await self._api(
            "POST",
            f"/inbounds/updateClient/{client_uuid}",
            json={"id": inbound_id, "settings": settings_str},
        )

    async def del_client(self, inbound_id: int, client_uuid: str) -> None:
        await self._api("POST", f"/inbounds/{inbound_id}/delClient/{client_uuid}")

    async def get_client_traffic(self, email: str) -> Optional[dict[str, Any]]:
        result = await self._api("GET", f"/inbounds/getClientTraffics/{email}")
        return result if isinstance(result, dict) else None

    async def get_online_clients(self) -> list[str]:
        result = await self._api("POST", "/inbounds/onlines")
        return result if isinstance(result, list) else []

    # ── High-level methods ──

    @property
    def _inbound_id(self) -> int:
        return self.inbound_ids[0]

    async def create_vless_user(self, name: str, tg_user_id: int, days: int | None) -> VlessUser:
        """Create VLESS client in the configured inbound."""
        client_uuid = str(uuid.uuid4())
        sub_id = str(tg_user_id)
        expiry_ms = int((time.time() + days * 86400) * 1000) if days and days > 0 else 0
        client = {
            "id": client_uuid,
            "email": name,
            "enable": True,
            "expiryTime": expiry_ms,
            "limitIp": 0,
            "totalGB": 0,
            "subId": sub_id,
            "tgId": tg_user_id,
            "reset": 0,
        }
        await self.add_client(self._inbound_id, client)
        return VlessUser(
            email=name,
            client_uuid=client_uuid,
            sub_url=f"{self.sub_url}/sub/{sub_id}",
            expiry_time=expiry_ms,
        )

    async def extend_vless_user(self, email: str, days: int) -> int:
        """Extend expiry for a VLESS user. Returns new expiry_ms."""
        client, _ = await self._find_client(email)
        if client is None:
            raise XuiApiError(f"Client '{email}' not found")
        old_expiry = client.get("expiryTime", 0)
        now_ms = int(time.time() * 1000)
        if old_expiry == 0 or old_expiry < now_ms:
            new_expiry_ms = int((time.time() + days * 86400) * 1000)
        else:
            new_expiry_ms = old_expiry + days * 86400 * 1000
        client["expiryTime"] = new_expiry_ms
        await self.update_client(self._inbound_id, client["id"], client)
        return new_expiry_ms

    async def set_vless_user_expiry(self, email: str, days: int) -> int:
        """Set expiry to now + days for a VLESS user. Returns new expiry_ms."""
        new_expiry_ms = int((time.time() + days * 86400) * 1000) if days > 0 else 0
        client, _ = await self._find_client(email)
        if client is None:
            raise XuiApiError(f"Client '{email}' not found")
        client["expiryTime"] = new_expiry_ms
        await self.update_client(self._inbound_id, client["id"], client)
        return new_expiry_ms

    async def set_vless_user_enabled(self, email: str, enabled: bool) -> None:
        """Enable or disable a VLESS user."""
        client, _ = await self._find_client(email)
        if client is None:
            raise XuiApiError(f"Client '{email}' not found")
        client["enable"] = enabled
        await self.update_client(self._inbound_id, client["id"], client)

    async def delete_vless_user(self, email: str) -> None:
        """Delete a VLESS user."""
        client, _ = await self._find_client(email)
        if client is None:
            raise XuiApiError(f"Client '{email}' not found")
        await self.del_client(self._inbound_id, client["id"])

    async def get_vless_user_info(self, email: str) -> Optional[dict[str, Any]]:
        """Get info about a VLESS user."""
        client, _ = await self._find_client(email)
        if client is None:
            return None
        traffic = await self.get_client_traffic(email)
        online_list = await self.get_online_clients()
        return {
            "email": email,
            "uuid": client["id"],
            "enable": client.get("enable", True),
            "expiryTime": client.get("expiryTime", 0),
            "subId": client.get("subId", ""),
            "up": (traffic or {}).get("up", 0),
            "down": (traffic or {}).get("down", 0),
            "online": email in online_list,
        }

    async def list_vless_clients(self) -> list[dict[str, Any]]:
        """List all clients from the configured inbound."""
        if not self.inbound_ids:
            return []
        inbound = await self.get_inbound(self._inbound_id)
        settings = json.loads(inbound.get("settings", "{}"))
        clients = settings.get("clients", [])
        online_list = await self.get_online_clients()
        result = []
        for c in clients:
            email = c.get("email", "")
            result.append({
                "email": email,
                "uuid": c.get("id", ""),
                "enable": c.get("enable", True),
                "expiryTime": c.get("expiryTime", 0),
                "subId": c.get("subId", ""),
                "tgId": c.get("tgId"),
                "online": email in online_list,
            })
        return result

    def get_sub_url(self, tg_user_id: int) -> str:
        return f"{self.sub_url}/sub/{tg_user_id}"

    async def update_vless_client_binding(self, email: str, tg_user_id: int) -> None:
        """Update subId and tgId for an existing client in 3x-ui."""
        client, _ = await self._find_client(email)
        if client is None:
            raise XuiApiError(f"Client '{email}' not found")
        client["subId"] = str(tg_user_id)
        client["tgId"] = tg_user_id
        await self.update_client(self._inbound_id, client["id"], client)

    async def delete_clients_by_suffix(self, inbound_id: int, suffix: str) -> int:
        """Delete all clients whose email ends with the given suffix from a specific inbound."""
        inbound = await self.get_inbound(inbound_id)
        settings = json.loads(inbound.get("settings", "{}"))
        deleted = 0
        for client in settings.get("clients", []):
            if client.get("email", "").endswith(suffix):
                await self.del_client(inbound_id, client["id"])
                deleted += 1
        return deleted

    # ── Internal helpers ──

    async def _find_client(self, email: str) -> tuple[Optional[dict[str, Any]], int]:
        """Find a client by email in the configured inbound."""
        inbound = await self.get_inbound(self._inbound_id)
        settings = json.loads(inbound.get("settings", "{}"))
        for client in settings.get("clients", []):
            if client.get("email") == email:
                return client, self._inbound_id
        return None, self._inbound_id
