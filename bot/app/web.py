from __future__ import annotations

import asyncio
import logging

from aiogram import Bot
from aiogram.types import Update
from fastapi import FastAPI, Header, HTTPException, Request

from app.admin_client import AdminApiClient
from app.bot_logic import BotContext, build_dispatcher
from app.config import Settings, load_settings
from app.db import Database
from app.repositories import BotRepository
from app.xui_client import XuiApiClient, XuiApiError

logger = logging.getLogger(__name__)

# Existing VLESS clients → Telegram user IDs (one-time binding)
_EXISTING_VLESS_BINDINGS: dict[int, list[str]] = {
    396733927: [
        "RESERVE-RU-TLS", "ANDROID-TLS", "TEST-PC-TLS",
        "macbook m1 pro", "macbook m4 TLS", "linux-tls",
        "iphone 16 pro max TLS",
    ],
    1271472166: ["android_tv_polina_kitchen-tls", "yandex-alice-polina-tls"],
    396354134: ["papa-tls"],
    1280972196: ["mama-tls"],
    1546574276: [
        "Danil Pavlov TEST-TLS", "Danil Pavlov TEST-TLS-2",
        "Danil Pavlov TEST-TLS-3",
    ],
}


async def _bind_existing_vless_clients(db: Database, xui: XuiApiClient) -> None:
    """One-time migration: bind existing VLESS clients to Telegram IDs."""
    async with db.session() as session:
        repo = BotRepository(session)
        # Check if already done
        bindings = await repo.list_client_bindings(396733927)
        if any(b.client_name == "RESERVE-RU-TLS" for b in bindings):
            logger.info("vless_bindings already migrated, skipping")
            return
        for tg_user_id, client_names in _EXISTING_VLESS_BINDINGS.items():
            await repo.ensure_user(tg_user_id, None)
            for name in client_names:
                await repo.upsert_client_binding(tg_user_id, "vless", name, product_type="vless")
                try:
                    await xui.update_vless_client_binding(name, tg_user_id)
                    logger.info("vless_binding_updated email=%s tg_user_id=%d", name, tg_user_id)
                except XuiApiError:
                    logger.warning("vless_binding_failed email=%s — client not found in 3x-ui", name)
    logger.info("vless_bindings migration complete")


async def _cleanup_reality_clients(xui: XuiApiClient) -> None:
    """Remove bot-created @reality clients from inbound #2."""
    try:
        deleted = await xui.delete_clients_by_suffix(2, "@reality")
        if deleted > 0:
            logger.info("cleaned_up %d @reality clients from inbound #2", deleted)
    except XuiApiError:
        logger.warning("cleanup_reality_failed — inbound #2 may not exist")


def create_app() -> FastAPI:
    settings: Settings = load_settings()
    db = Database(settings.database_url)
    admin = AdminApiClient(list(settings.vpn_servers), settings.default_server_id)
    xui: XuiApiClient | None = None
    if settings.xui is not None:
        xui = XuiApiClient(
            base_url=settings.xui.base_url,
            username=settings.xui.username,
            password=settings.xui.password,
            inbound_ids=list(settings.xui.inbound_ids),
            sub_url=settings.xui.sub_url,
        )
    bot = Bot(token=settings.telegram_bot_token)
    ctx = BotContext(settings=settings, db=db, admin=admin, xui=xui)
    dp = build_dispatcher(ctx)

    app = FastAPI(title="GhostStream Telegram Bot")
    app.state.settings = settings
    app.state.db = db
    app.state.admin = admin
    app.state.bot = bot
    app.state.dp = dp

    @app.on_event("startup")
    async def startup() -> None:
        await db.init_models()
        async with db.session() as session:
            repo = BotRepository(session)
            await repo.backfill_bindings_from_legacy(settings.default_server_id)
        nonlocal xui
        if xui is not None:
            try:
                await xui.login()
            except Exception:
                logger.exception("xui_login_failed — VLESS features disabled")
                xui = None
                ctx.xui = None
        if xui is not None:
            await _bind_existing_vless_clients(db, xui)
            await _cleanup_reality_clients(xui)
        if settings.telegram_webhook_url:
            await bot.set_webhook(
                url=settings.telegram_webhook_url,
                secret_token=settings.telegram_webhook_secret or None,
                drop_pending_updates=False,
            )
            logger.info("bot_started webhook=%s", settings.telegram_webhook_url)
        else:
            await bot.delete_webhook(drop_pending_updates=False)
            asyncio.create_task(dp.start_polling(bot))
            logger.info("bot_started polling")

    @app.on_event("shutdown")
    async def shutdown() -> None:
        if not settings.telegram_webhook_url:
            await dp.stop_polling()
        await admin.close()
        if xui is not None:
            await xui.close()
        await bot.session.close()
        logger.info("bot_stopped")

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/telegram/webhook")
    async def telegram_webhook(
        request: Request,
        x_telegram_bot_api_secret_token: str | None = Header(default=None),
    ) -> dict[str, bool]:
        if settings.telegram_webhook_secret:
            if x_telegram_bot_api_secret_token != settings.telegram_webhook_secret:
                raise HTTPException(status_code=403, detail="invalid webhook secret")
        data = await request.json()
        update = Update.model_validate(data)
        await dp.feed_update(bot=bot, update=update)
        return {"ok": True}

    return app

