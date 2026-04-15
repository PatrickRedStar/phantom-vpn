"""httpx-wrapper for phantom-server admin HTTP API."""
from __future__ import annotations

from typing import Any, Optional

import httpx


class PhantomApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(f"{status}: {message}")
        self.status = status
        self.message = message


class PhantomAPI:
    def __init__(self, base_url: str, token: str, timeout: float = 10.0):
        self._base = base_url.rstrip("/")
        self._headers = {"Authorization": f"Bearer {token}"}
        self._timeout = timeout

    async def _request(
        self,
        method: str,
        path: str,
        *,
        json: Optional[dict] = None,
    ) -> Any:
        url = f"{self._base}{path}"
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as cli:
                r = await cli.request(method, url, headers=self._headers, json=json)
        except httpx.RequestError as e:
            raise PhantomApiError(0, f"network error: {e}") from e
        if r.status_code >= 400:
            raise PhantomApiError(r.status_code, r.text[:200])
        if not r.content:
            return None
        try:
            return r.json()
        except ValueError:
            return r.text

    # ─── Endpoints ─────────────────────────────────────────────────────────

    async def status(self) -> dict:
        return await self._request("GET", "/api/status")

    async def list_clients(self) -> list[dict]:
        return await self._request("GET", "/api/clients")

    async def create_client(
        self,
        name: str,
        expires_days: Optional[int] = None,
        is_admin: bool = False,
    ) -> dict:
        body: dict[str, Any] = {"name": name, "is_admin": is_admin}
        if expires_days is not None:
            body["expires_days"] = expires_days
        return await self._request("POST", "/api/clients", json=body)

    async def set_admin(self, name: str, is_admin: bool) -> None:
        await self._request(
            "POST", f"/api/clients/{name}/admin", json={"is_admin": is_admin}
        )

    async def delete_client(self, name: str) -> None:
        await self._request("DELETE", f"/api/clients/{name}")

    async def enable_client(self, name: str) -> None:
        await self._request("POST", f"/api/clients/{name}/enable")

    async def disable_client(self, name: str) -> None:
        await self._request("POST", f"/api/clients/{name}/disable")

    async def conn_string(self, name: str) -> str:
        r = await self._request("GET", f"/api/clients/{name}/conn_string")
        # expected shape: {"conn_string": "<base64>"}
        if isinstance(r, dict):
            return r.get("conn_string") or r.get("connString") or ""
        return str(r)

    async def subscription(
        self,
        name: str,
        action: str,
        days: Optional[int] = None,
    ) -> dict:
        body: dict[str, Any] = {"action": action}
        if days is not None:
            body["days"] = days
        return await self._request(
            "POST", f"/api/clients/{name}/subscription", json=body
        )
