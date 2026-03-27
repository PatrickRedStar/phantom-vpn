from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from typing import Any, Optional

import httpx

from app.config import VpnServer


class AdminApiError(RuntimeError):
    pass


class AdminApiClient:
    def __init__(self, servers: list[VpnServer], default_server_id: str) -> None:
        self.default_server_id = default_server_id
        self.server_map: dict[str, VpnServer] = {s.server_id: s for s in servers}
        self.clients: dict[str, httpx.AsyncClient] = {
            s.server_id: httpx.AsyncClient(
                base_url=s.admin_api_base_url.rstrip("/"),
                headers={"Authorization": f"Bearer {s.admin_api_token}"},
                timeout=15.0,
            )
            for s in servers
        }
        if default_server_id not in self.server_map:
            raise RuntimeError(f"Unknown default server id: {default_server_id}")

    async def close(self) -> None:
        for client in self.clients.values():
            await client.aclose()

    def list_servers(self) -> list[VpnServer]:
        return list(self.server_map.values())

    async def get_status(self, server_id: Optional[str] = None) -> dict[str, Any]:
        data = await self._request("GET", "/api/status", server_id=server_id)
        return data if isinstance(data, dict) else {}

    async def create_client(
        self,
        name: str,
        expires_days: Optional[int] = None,
        server_id: Optional[str] = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {"name": name}
        if expires_days is not None:
            payload["expires_days"] = expires_days
        return await self._request("POST", "/api/clients", json=payload, server_id=server_id)

    async def extend_subscription(self, client_name: str, days: int, server_id: Optional[str] = None) -> dict[str, Any]:
        payload = {"action": "extend", "days": days}
        return await self._request("POST", f"/api/clients/{client_name}/subscription", json=payload, server_id=server_id)

    async def set_subscription(self, client_name: str, days: int, server_id: Optional[str] = None) -> dict[str, Any]:
        payload = {"action": "set", "days": days}
        return await self._request("POST", f"/api/clients/{client_name}/subscription", json=payload, server_id=server_id)

    async def cancel_subscription(self, client_name: str, server_id: Optional[str] = None) -> dict[str, Any]:
        payload = {"action": "cancel"}
        return await self._request("POST", f"/api/clients/{client_name}/subscription", json=payload, server_id=server_id)

    async def revoke_subscription(self, client_name: str, server_id: Optional[str] = None) -> dict[str, Any]:
        payload = {"action": "revoke"}
        return await self._request("POST", f"/api/clients/{client_name}/subscription", json=payload, server_id=server_id)

    async def set_client_enabled(
        self,
        client_name: str,
        enabled: bool,
        server_id: Optional[str] = None,
    ) -> dict[str, Any]:
        endpoint = "enable" if enabled else "disable"
        return await self._request("POST", f"/api/clients/{client_name}/{endpoint}", server_id=server_id)

    async def delete_client(self, client_name: str, server_id: Optional[str] = None) -> dict[str, Any]:
        return await self._request("DELETE", f"/api/clients/{client_name}", server_id=server_id)

    async def get_conn_string(self, client_name: str, server_id: Optional[str] = None) -> str:
        data = await self._request("GET", f"/api/clients/{client_name}/conn_string", server_id=server_id)
        value = data.get("conn_string")
        if not value:
            raise AdminApiError("Admin API returned empty conn_string")
        return str(value)

    async def get_client_by_name(self, client_name: str, server_id: Optional[str] = None) -> Optional[dict[str, Any]]:
        data = await self._request("GET", "/api/clients", server_id=server_id)
        if not isinstance(data, list):
            return None
        for item in data:
            if item.get("name") == client_name:
                return item
        return None

    async def list_clients(self, server_id: Optional[str] = None) -> list[dict[str, Any]]:
        data = await self._request("GET", "/api/clients", server_id=server_id)
        if not isinstance(data, list):
            return []
        return [item for item in data if isinstance(item, dict)]

    async def get_client_logs(self, client_name: str, server_id: Optional[str] = None) -> list[dict[str, Any]]:
        data = await self._request("GET", f"/api/clients/{client_name}/logs", server_id=server_id)
        if not isinstance(data, list):
            return []
        return [item for item in data if isinstance(item, dict)]

    async def get_client_stats(self, client_name: str, server_id: Optional[str] = None) -> list[dict[str, Any]]:
        data = await self._request("GET", f"/api/clients/{client_name}/stats", server_id=server_id)
        if not isinstance(data, list):
            return []
        return [item for item in data if isinstance(item, dict)]

    async def _request(self, method: str, path: str, server_id: Optional[str] = None, **kwargs: Any) -> Any:
        sid = server_id or self.default_server_id
        client = self.clients.get(sid)
        if client is None:
            raise AdminApiError(f"Unknown server_id: {sid}")
        max_attempts = 4
        for attempt in range(1, max_attempts + 1):
            try:
                response = await client.request(method, path, **kwargs)
                if response.status_code >= 500:
                    raise AdminApiError(f"Admin API {response.status_code}: {response.text}")
                if response.status_code >= 400:
                    raise AdminApiError(f"Admin API {response.status_code}: {response.text}")
                if not response.content:
                    return {}
                return response.json()
            except (httpx.HTTPError, AdminApiError) as exc:
                if attempt == max_attempts:
                    raise AdminApiError(str(exc)) from exc
                await asyncio.sleep(0.5 * (2 ** (attempt - 1)))
        raise AdminApiError("Unexpected retry flow")


def parse_expires_at(value: Any) -> Optional[datetime]:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(float(value), tz=timezone.utc)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    return None

