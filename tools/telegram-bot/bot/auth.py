"""Admin-only guard decorator."""
from __future__ import annotations

import logging
from functools import wraps

from telegram import Update
from telegram.ext import ContextTypes

from .config import CONFIG

log = logging.getLogger(__name__)


def admin_only(handler):
    @wraps(handler)
    async def wrapper(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
        uid = update.effective_user.id if update.effective_user else None
        if uid != CONFIG.admin_telegram_id:
            log.warning("denied user_id=%s", uid)
            return None
        return await handler(update, ctx)

    return wrapper
