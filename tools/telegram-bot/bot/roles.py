"""Local storage of client roles (admin | regular). JSON file, atomic writes."""
from __future__ import annotations

import json
import os
import threading
from typing import Literal

Role = Literal["admin", "regular"]
_LOCK = threading.Lock()


def _load_raw(path: str) -> dict[str, str]:
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return {str(k): str(v) for k, v in data.items()}
    except (json.JSONDecodeError, OSError):
        pass
    return {}


def _save_raw(path: str, data: dict[str, str]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    os.replace(tmp, path)


class RoleStore:
    def __init__(self, path: str):
        self._path = path
        self._data: dict[str, str] = _load_raw(path)

    def get(self, name: str) -> Role:
        # Default to regular — safer (don't leak admin token).
        r = self._data.get(name, "regular")
        return "admin" if r == "admin" else "regular"

    def set(self, name: str, role: Role) -> None:
        with _LOCK:
            self._data[name] = role
            _save_raw(self._path, self._data)

    def delete(self, name: str) -> None:
        with _LOCK:
            if name in self._data:
                self._data.pop(name)
                _save_raw(self._path, self._data)

    def all(self) -> dict[str, Role]:
        return {k: ("admin" if v == "admin" else "regular") for k, v in self._data.items()}
