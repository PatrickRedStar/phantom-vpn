from __future__ import annotations

import logging

import uvicorn

from app.config import load_settings
from app.web import create_app


def run() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    settings = load_settings()
    uvicorn.run(
        "app.web:create_app",
        host=settings.bot_host,
        port=settings.bot_port,
        factory=True,
        reload=False,
    )


if __name__ == "__main__":
    run()

