"""Entry point: build Application, wire handlers, run polling."""
from __future__ import annotations

import logging

from telegram import Update
from telegram.ext import Application

from . import handlers
from .api import PhantomAPI
from .config import CONFIG

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-5s %(name)s: %(message)s",
)
log = logging.getLogger("phantom-telegram-bot")


def main() -> None:
    log.info(
        "booting bot: admin_id=%s admin_url=%s",
        CONFIG.admin_telegram_id,
        CONFIG.phantom_admin_url,
    )

    api = PhantomAPI(CONFIG.phantom_admin_url, CONFIG.phantom_admin_token)
    handlers.init(api)

    app = Application.builder().token(CONFIG.bot_token).build()
    handlers.register(app)

    log.info("Application started — polling")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
