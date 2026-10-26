"""Admin-only guard decorator."""
from __future__ import annotations

import logging
from functools import wraps

from telegram import Update
from telegram.constants import ChatType
from telegram.ext import ContextTypes

from .config import CONFIG

log = logging.getLogger(__name__)


def admin_only(handler):
    @wraps(handler)
    async def wrapper(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        uid = update.effective_user.id if update.effective_user else None
        chat = update.effective_chat.type if update.effective_chat else None
        if uid != CONFIG.admin_telegram_id or chat != ChatType.PRIVATE:
            log.warning("denied user_id=%s chat=%s", uid, chat)
            return None
        return await handler(update, ctx)

    return wrapper
