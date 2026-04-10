from __future__ import annotations

import asyncio
import logging
from contextlib import suppress
from datetime import datetime, timedelta, timezone

from aiogram import Bot
from aiogram.types import (
    BotCommand,
    BotCommandScopeAllPrivateChats,
    BotCommandScopeChat,
    BotCommandScopeDefault,
    Update,
)
from fastapi import FastAPI, Header, HTTPException, Request

from app.admin_client import AdminApiClient
from app.bot_logic import BotContext, build_dispatcher
from app.config import Settings, load_settings
from app.db import Database
from app.keyboards import back_keyboard
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

_NOTIFICATION_EXPIRING_3D = "expiring_3d"
_NOTIFICATION_EXPIRING_1D = "expiring_1d"
_NOTIFICATION_NO_ACTIVE = "no_active"
_THREE_DAYS_MS = 72 * 60 * 60 * 1000
_ONE_DAY_MS = 24 * 60 * 60 * 1000


def _user_commands() -> list[BotCommand]:
    return [
        BotCommand(command="start", description="Открыть главное меню"),
        BotCommand(command="menu", description="Показать меню"),
        BotCommand(command="my", description="Мои подписки"),
        BotCommand(command="support", description="Поддержка"),
    ]


async def _configure_bot_commands(bot: Bot, settings: Settings) -> None:
    user_commands = _user_commands()
    await bot.set_my_commands(user_commands, scope=BotCommandScopeDefault())
    await bot.set_my_commands(user_commands, scope=BotCommandScopeAllPrivateChats())
    if not settings.bot_admin_ids:
        return
    admin_commands = user_commands + [BotCommand(command="admin", description="Админ-меню")]
    for admin_id in sorted(settings.bot_admin_ids):
        await bot.set_my_commands(admin_commands, scope=BotCommandScopeChat(chat_id=admin_id))


def _to_expiry_ms(value: object) -> int:
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        try:
            return int(value.strip())
        except ValueError:
            return 0
    return 0


def _expiring_notification(
    client_name: str,
    remaining_ms: int,
) -> tuple[str, str, str] | None:
    if remaining_ms <= 0:
        return None
    if remaining_ms <= _ONE_DAY_MS:
        return (
            _NOTIFICATION_EXPIRING_1D,
            f"{client_name}:1d",
            (
                f"Напоминание: подписка {client_name} заканчивается меньше чем через сутки.\n"
                "Чтобы не потерять доступ, продлите ее заранее."
            ),
        )
    if remaining_ms <= _THREE_DAYS_MS:
        return (
            _NOTIFICATION_EXPIRING_3D,
            f"{client_name}:3d",
            (
                f"Напоминание: подписка {client_name} скоро закончится (меньше 3 дней).\n"
                "Если доступ еще нужен, продлите ее заранее."
            ),
        )
    return None


async def _send_notification_if_new(
    *,
    bot: Bot,
    repo: BotRepository,
    tg_user_id: int,
    notification_type: str,
    scope_key: str,
    text: str,
    client_name: str | None = None,
) -> bool:
    if await repo.was_notification_scope_sent(tg_user_id, notification_type, scope_key):
        return False
    try:
        await bot.send_message(
            chat_id=tg_user_id,
            text=text,
            reply_markup=back_keyboard("main:home", "⬅️ В меню"),
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "notification_send_failed user=%s type=%s scope=%s err=%s",
            tg_user_id,
            notification_type,
            scope_key,
            exc,
        )
        return False
    await repo.record_notification_send(
        tg_user_id=tg_user_id,
        notification_type=notification_type,
        scope_key=scope_key,
        client_name=client_name,
    )
    return True


async def _run_notification_pass(
    *,
    bot: Bot,
    db: Database,
    xui: XuiApiClient,
    settings: Settings,
) -> None:
    try:
        clients = await xui.list_vless_clients()
    except XuiApiError as exc:
        logger.warning("notification_pass_skip: cannot list 3x-ui clients err=%s", exc)
        return

    client_by_email: dict[str, dict[str, object]] = {}
    for item in clients:
        email = str(item.get("email", "")).strip()
        if email:
            client_by_email[email] = item

    now = datetime.now(timezone.utc)
    now_ms = int(now.timestamp() * 1000)
    no_active_since = now - timedelta(seconds=settings.notify_no_active_cooldown_sec)
    no_active_window = int(now.timestamp()) // settings.notify_no_active_cooldown_sec

    sent_count = 0
    async with db.session() as session:
        repo = BotRepository(session)
        bindings = await repo.list_all_client_bindings(product_type="vless")
        payment_user_ids = await repo.list_payment_user_ids()
        binding_user_ids = {binding.tg_user_id for binding in bindings}
        candidate_user_ids = binding_user_ids | payment_user_ids
        active_user_ids: set[int] = set()

        for binding in bindings:
            client = client_by_email.get(binding.client_name)
            if client is None:
                continue
            if not bool(client.get("enable", True)):
                continue

            expiry_ms = _to_expiry_ms(client.get("expiryTime", 0))
            if expiry_ms <= 0:
                active_user_ids.add(binding.tg_user_id)
                continue
            if expiry_ms <= now_ms:
                continue

            active_user_ids.add(binding.tg_user_id)
            notification = _expiring_notification(binding.client_name, expiry_ms - now_ms)
            if notification is None:
                continue
            notification_type, scope_suffix, text = notification
            scope_key = f"{scope_suffix}:{expiry_ms}"
            if await _send_notification_if_new(
                bot=bot,
                repo=repo,
                tg_user_id=binding.tg_user_id,
                notification_type=notification_type,
                scope_key=scope_key,
                text=text,
                client_name=binding.client_name,
            ):
                sent_count += 1

        no_active_users = sorted(candidate_user_ids - active_user_ids)
        for tg_user_id in no_active_users:
            if await repo.was_notification_type_sent_since(
                tg_user_id=tg_user_id,
                notification_type=_NOTIFICATION_NO_ACTIVE,
                since=no_active_since,
            ):
                continue
            if await _send_notification_if_new(
                bot=bot,
                repo=repo,
                tg_user_id=tg_user_id,
                notification_type=_NOTIFICATION_NO_ACTIVE,
                scope_key=f"no-active:{no_active_window}",
                text=(
                    "Сейчас у вас нет активных подписок.\n"
                    "Если снова нужен доступ, оформить подписку можно в меню."
                ),
            ):
                sent_count += 1

    logger.info(
        "notification_pass_done bindings=%d clients=%d sent=%d",
        len(bindings),
        len(client_by_email),
        sent_count,
    )


async def _notification_loop(
    *,
    bot: Bot,
    db: Database,
    xui: XuiApiClient,
    settings: Settings,
    stop_event: asyncio.Event,
) -> None:
    logger.info("notification_loop_started interval_sec=%d", settings.notify_scan_interval_sec)
    while not stop_event.is_set():
        try:
            await _run_notification_pass(bot=bot, db=db, xui=xui, settings=settings)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("notification_loop_pass_failed")
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=settings.notify_scan_interval_sec)
        except asyncio.TimeoutError:
            continue
    logger.info("notification_loop_stopped")


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


async def _cleanup_stale_vless_bindings(db: Database, xui: XuiApiClient) -> None:
    """Remove bindings from bot DB if client no longer exists in 3x-ui."""
    async with db.session() as session:
        repo = BotRepository(session)
        bindings = await repo.list_all_client_bindings(product_type="vless")
        if not bindings:
            logger.info("stale_bindings_cleanup: no vless bindings in DB")
            return
        try:
            clients = await xui.list_vless_clients()
        except XuiApiError:
            logger.warning("stale_bindings_cleanup_failed — cannot list 3x-ui clients")
            return
        existing_emails = {
            str(item.get("email", "")).strip()
            for item in clients
            if str(item.get("email", "")).strip()
        }
        stale_ids = [binding.id for binding in bindings if binding.client_name not in existing_emails]
        for binding_id in stale_ids:
            await repo.delete_client_binding_by_id(binding_id)
        logger.info(
            "stale_bindings_cleanup finished: checked=%d deleted=%d",
            len(bindings),
            len(stale_ids),
        )


def create_app() -> FastAPI:
    settings: Settings = load_settings()
    db = Database(settings.database_url)
    admin = AdminApiClient(list(settings.vpn_servers), settings.default_server_id)
    xui: XuiApiClient | None = None
    if settings.xui is not None:
        verify: bool | str = settings.xui.ca_bundle if settings.xui.ca_bundle else settings.xui.tls_verify
        xui = XuiApiClient(
            base_url=settings.xui.base_url,
            username=settings.xui.username,
            password=settings.xui.password,
            inbound_ids=list(settings.xui.inbound_ids),
            sub_url=settings.xui.sub_url,
            verify=verify,
        )
    bot = Bot(token=settings.telegram_bot_token)
    ctx = BotContext(settings=settings, db=db, admin=admin, xui=xui)
    dp = build_dispatcher(ctx)

    app = FastAPI(title="VLESS Telegram Bot")
    app.state.settings = settings
    app.state.db = db
    app.state.admin = admin
    app.state.bot = bot
    app.state.dp = dp
    app.state.notification_stop_event = None
    app.state.notification_task = None

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
            await _cleanup_stale_vless_bindings(db, xui)
            stop_event = asyncio.Event()
            app.state.notification_stop_event = stop_event
            app.state.notification_task = asyncio.create_task(
                _notification_loop(
                    bot=bot,
                    db=db,
                    xui=xui,
                    settings=settings,
                    stop_event=stop_event,
                ),
            )
        try:
            await _configure_bot_commands(bot, settings)
        except Exception:
            logger.exception("bot_commands_setup_failed")
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
        notification_stop_event: asyncio.Event | None = app.state.notification_stop_event
        notification_task: asyncio.Task[None] | None = app.state.notification_task
        if notification_stop_event is not None:
            notification_stop_event.set()
        if notification_task is not None:
            with suppress(asyncio.CancelledError):
                await notification_task
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
