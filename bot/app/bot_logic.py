from __future__ import annotations

import asyncio
import base64
from dataclasses import dataclass
import html
import json
import io
import logging
import re
import uuid
from datetime import datetime, timedelta, timezone
import qrcode
from aiogram import Bot, Dispatcher, F, Router
from aiogram.exceptions import TelegramBadRequest
from aiogram.filters import Command, CommandStart
from aiogram.types import (
    BufferedInputFile,
    CallbackQuery,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    LabeledPrice,
    Message,
    PreCheckoutQuery,
)

from app.admin_client import AdminApiClient, AdminApiError, parse_expires_at
from app.config import Settings, VpnServer
from app.db import Database
from app.keyboards import (
    admin_home_keyboard,
    back_keyboard,
    main_menu_keyboard,
    plan_keyboard,
    bindings_keyboard,
)
from app.payments import InvoicePayload
from app.repositories import BotRepository
from app.xui_client import XuiApiClient, XuiApiError

logger = logging.getLogger(__name__)
router = Router()
_PENDING_INVOICE_TTL = timedelta(minutes=30)
_PENDING_INVOICE_CHECKOUT_GRACE = timedelta(minutes=10)
_PENDING_INVOICE_JANITOR_INTERVAL_SEC = 60


@dataclass
class PendingInvoice:
    chat_id: int
    invoice_message_id: int
    preview_message_id: int | None
    payload: str
    kind: str
    created_at: datetime
    expires_at: datetime
    checkout_started_at: datetime | None = None


class BotContext:
    def __init__(
        self,
        settings: Settings,
        db: Database,
        admin: AdminApiClient,
        xui: XuiApiClient | None = None,
    ) -> None:
        self.settings = settings
        self.db = db
        self.admin = admin
        self.xui = xui
        self.admin_create_draft: dict[int, dict[str, str]] = {}
        self.vless_buy_draft: dict[int, dict[str, str]] = {}
        self.selected_server: dict[int, str] = {}
        self.last_ephemeral_message_by_chat: dict[int, int] = {}
        self.ephemeral_state_lock = asyncio.Lock()
        self.pending_invoices: dict[int, PendingInvoice] = {}
        self.pending_invoice_tasks: dict[int, asyncio.Task[None]] = {}
        self.pending_invoice_lock = asyncio.Lock()


def build_dispatcher(ctx: BotContext) -> Dispatcher:
    dp = Dispatcher()
    dp["ctx"] = ctx
    dp.include_router(router)
    return dp


async def _safe_delete_message(bot: Bot, chat_id: int, message_id: int) -> None:
    try:
        await bot.delete_message(chat_id=chat_id, message_id=message_id)
    except TelegramBadRequest:
        return
    except Exception as exc:  # noqa: BLE001
        logger.debug("ephemeral_delete_failed chat=%s msg=%s err=%s", chat_id, message_id, exc)


async def _delete_message_if_exists(bot: Bot, chat_id: int, message_id: int | None) -> None:
    if message_id is None:
        return
    try:
        await bot.delete_message(chat_id=chat_id, message_id=message_id)
    except TelegramBadRequest:
        return
    except Exception as exc:  # noqa: BLE001
        logger.debug("invoice_delete_failed chat=%s msg=%s err=%s", chat_id, message_id, exc)


async def _pop_pending_invoice(ctx: BotContext, chat_id: int) -> PendingInvoice | None:
    async with ctx.pending_invoice_lock:
        pending = ctx.pending_invoices.pop(chat_id, None)
        task = ctx.pending_invoice_tasks.pop(chat_id, None)
    if task is not None and task is not asyncio.current_task():
        task.cancel()
    return pending


async def _cleanup_pending_invoice_messages(bot: Bot, pending: PendingInvoice) -> None:
    await _delete_message_if_exists(bot, pending.chat_id, pending.invoice_message_id)
    await _delete_message_if_exists(bot, pending.chat_id, pending.preview_message_id)


async def _clear_pending_invoice(ctx: BotContext, bot: Bot, chat_id: int) -> None:
    pending = await _pop_pending_invoice(ctx, chat_id)
    if pending is None:
        return
    await _cleanup_pending_invoice_messages(bot, pending)


async def _pending_invoice_cleanup_worker(ctx: BotContext, bot: Bot, chat_id: int) -> None:
    try:
        while True:
            await asyncio.sleep(_PENDING_INVOICE_JANITOR_INTERVAL_SEC)
            now = datetime.now(timezone.utc)
            async with ctx.pending_invoice_lock:
                pending = ctx.pending_invoices.get(chat_id)
                if pending is None:
                    return
                if pending.expires_at > now:
                    continue
            expired = await _pop_pending_invoice(ctx, chat_id)
            if expired is None:
                return
            await _cleanup_pending_invoice_messages(bot, expired)
            return
    except asyncio.CancelledError:
        raise
    except Exception as exc:  # noqa: BLE001
        logger.debug("invoice_cleanup_worker_failed chat=%s err=%s", chat_id, exc)
    finally:
        async with ctx.pending_invoice_lock:
            task = ctx.pending_invoice_tasks.get(chat_id)
            if task is asyncio.current_task():
                ctx.pending_invoice_tasks.pop(chat_id, None)


async def _store_pending_invoice(ctx: BotContext, bot: Bot, pending: PendingInvoice) -> None:
    await _clear_pending_invoice(ctx, bot, pending.chat_id)
    async with ctx.pending_invoice_lock:
        ctx.pending_invoices[pending.chat_id] = pending
        if pending.chat_id not in ctx.pending_invoice_tasks:
            ctx.pending_invoice_tasks[pending.chat_id] = asyncio.create_task(
                _pending_invoice_cleanup_worker(ctx, bot, pending.chat_id),
            )


async def _mark_pending_invoice_checkout(ctx: BotContext, chat_id: int) -> None:
    now = datetime.now(timezone.utc)
    async with ctx.pending_invoice_lock:
        pending = ctx.pending_invoices.get(chat_id)
        if pending is None:
            return
        pending.checkout_started_at = now
        pending.expires_at = now + _PENDING_INVOICE_CHECKOUT_GRACE


async def _mark_ephemeral(ctx: BotContext, sent: Message) -> None:
    chat_id = sent.chat.id
    previous_message_id: int | None = None
    async with ctx.ephemeral_state_lock:
        previous_message_id = ctx.last_ephemeral_message_by_chat.get(chat_id)
        ctx.last_ephemeral_message_by_chat[chat_id] = sent.message_id
    if previous_message_id and previous_message_id != sent.message_id:
        await _safe_delete_message(sent.bot, chat_id, previous_message_id)


async def _answer_ephemeral(message: Message, ctx: BotContext, text: str, **kwargs: object) -> Message:
    sent = await message.answer(text, **kwargs)
    await _mark_ephemeral(ctx, sent)
    return sent


async def _answer_ephemeral_photo(message: Message, ctx: BotContext, **kwargs: object) -> Message:
    sent = await message.answer_photo(**kwargs)
    await _mark_ephemeral(ctx, sent)
    return sent


async def _show_main_menu(message: Message, ctx: BotContext, tg_user_id: int) -> None:
    await _answer_ephemeral(
        message,
        ctx,
        "Выберите действие:",
        reply_markup=main_menu_keyboard(is_admin=_is_admin(ctx, tg_user_id)),
    )


async def _start_buy_subscription_flow(message: Message, ctx: BotContext, tg_user_id: int) -> None:
    if ctx.xui is None:
        await _answer_ephemeral(message, ctx, "VLESS временно недоступен. Обратитесь в поддержку.")
        return
    ctx.vless_buy_draft[tg_user_id] = {"step": "name"}
    await _answer_ephemeral(
        message,
        ctx,
        "Вы выбрали VLESS — максимально быстрый и современный протокол. "
        "Он отлично работает на iOS, Android, Windows и macOS через любые V2Ray-клиенты.\n\n"
        "🏷 Придумайте название для вашего конфига:\n"
        "(Это имя будет отображаться в вашем приложении)\n\n"
        "⚠️ Требования:\n"
        "• До 20 символов\n"
        "• Латиница (A-z), цифры (0-9)\n"
        "• Дефис или пробел\n\n"
        "Введите имя сообщениям ниже: 👇",
        reply_markup=back_keyboard("main:home"),
    )


async def _show_support(message: Message, ctx: BotContext) -> None:
    await _answer_ephemeral(
        message,
        ctx,
        "Поддержка: @a1ex_995",
        reply_markup=back_keyboard("main:home"),
    )


async def _show_admin_panel(message: Message, ctx: BotContext, tg_user_id: int) -> None:
    if not _is_admin(ctx, tg_user_id):
        await _answer_ephemeral(message, ctx, "Доступ запрещен.")
        return
    await _answer_ephemeral(message, ctx, "Админ-меню:", reply_markup=admin_home_keyboard())


async def _show_user_subscriptions(message: Message, ctx: BotContext, tg_user_id: int) -> None:
    async with ctx.db.session() as session:
        repo = BotRepository(session)
        bindings = await repo.list_client_bindings(tg_user_id)
    vless_bindings = [binding for binding in bindings if binding.product_type == "vless"]
    if not vless_bindings:
        await _answer_ephemeral(
            message,
            ctx,
            "Подписок пока нет. Нажмите «🛒 Купить подписку».",
            reply_markup=back_keyboard("main:home"),
        )
        return

    lines: list[str] = []
    extend_entries: list[tuple[str, str, str]] = []
    for binding in vless_bindings:
        info = await _get_vless_user_info(ctx, binding.client_name)
        if info is None:
            lines.append(f"- {binding.client_name} [VLESS] | not found")
            continue
        exp = _format_expires_ms(_to_expiry_ms(info.get("expiryTime", 0)))
        enabled = "on" if info.get("enable") else "off"
        online = "online" if info.get("online") else "offline"
        lines.append(f"- {binding.client_name} [VLESS] | {enabled}/{online} | до: {exp}")

        if _is_extendable_expiry_ms(info.get("expiryTime", 0)):
            cb_data = f"extend_pick:vless:{binding.client_name}"
            if len(cb_data.encode()) <= 64:
                extend_entries.append(("vless", binding.client_name, f"⏳ Продлить {binding.client_name}"))

    text = "Ваши подписки:\n" + "\n".join(lines)
    if not extend_entries:
        await _answer_ephemeral(
            message,
            ctx,
            text + "\n\nДля продления сейчас нет срочных подписок.",
            reply_markup=back_keyboard("main:home"),
        )
        return

    await _answer_ephemeral(
        message,
        ctx,
        text + "\n\nВыберите подписку для продления:",
        reply_markup=bindings_keyboard(
            extend_entries,
            prefix="extend_pick",
            back_callback="main:home",
        ),
    )


@router.message(CommandStart())
async def cmd_start(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    async with ctx.db.session() as session:
        repo = BotRepository(session)
        await repo.ensure_user(message.from_user.id, message.from_user.username)
    await _answer_ephemeral(
        message,
        ctx,
        "Привет! Добро пожаловать на борт! 🚀\n\n"
        "Это твой персональный доступ к свободному интернету через современный протокол VLESS. "
        "Мы сделали ставку на производительность и скрытность:\n"
        "🚀 Скорость — космос: Выжимай из своего провайдера максимум, наши серверы поддерживают более 500 Мбит/с.\n"
        "🤫 Приватность и тишина: В отличие от крупных сервисов, которые блокируют первыми, "
        "мы остаемся в тени благодаря небольшой аудитории.\n"
        "🎯 Умная балансировка: Весь RU-трафик идет напрямую. Пользуйся банками, доставкой и госуслугами "
        "без задержек и лишних переключений.\n\n"
        "Готов подключиться?",
        reply_markup=main_menu_keyboard(is_admin=_is_admin(ctx, message.from_user.id)),
    )


@router.message(Command("menu"))
async def cmd_menu(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    await _show_main_menu(message, ctx, message.from_user.id)


@router.message(Command("my"))
async def cmd_my_subscriptions(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    await _show_user_subscriptions(message, ctx, message.from_user.id)


@router.message(Command("support"))
@router.message(Command("help"))
async def cmd_support(message: Message, ctx: BotContext) -> None:
    await _show_support(message, ctx)


@router.message(Command("admin"))
async def cmd_admin(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    await _show_admin_panel(message, ctx, message.from_user.id)


@router.callback_query(F.data.startswith("main:"))
async def main_menu_action(callback: CallbackQuery, ctx: BotContext) -> None:
    if callback.from_user is None:
        return
    await callback.answer()
    message = callback.message
    if message is None or not isinstance(message, Message):
        return

    action = (callback.data or "").split(":", 1)[1]
    if action == "buy":
        await _start_buy_subscription_flow(message, ctx, callback.from_user.id)
        return
    if action == "subs":
        await _show_user_subscriptions(message, ctx, callback.from_user.id)
        return
    if action == "home":
        await _show_main_menu(message, ctx, callback.from_user.id)
        return
    if action == "help":
        await _show_support(message, ctx)
        return
    if action == "admin":
        await _show_admin_panel(message, ctx, callback.from_user.id)
        return
    await _answer_ephemeral(message, ctx, "Неизвестная команда меню.")


@router.message(F.text == "Купить подписку")
@router.message(F.text == "🛒 Купить подписку")
async def buy_subscription(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    await _start_buy_subscription_flow(message, ctx, message.from_user.id)


@router.callback_query(F.data.startswith("buy_product:"))
async def buy_product_selected(callback: CallbackQuery, ctx: BotContext) -> None:
    if callback.from_user is None:
        return
    product = (callback.data or "").split(":")[1]
    if product != "vless":
        await callback.answer("Доступен только VLESS.", show_alert=True)
        return
    if ctx.xui is None:
        await callback.answer("VLESS временно недоступен.", show_alert=True)
        return
    await callback.answer()
    ctx.vless_buy_draft[callback.from_user.id] = {"step": "name"}
    if callback.message is None or not isinstance(callback.message, Message):
        return
    await _answer_ephemeral(
        callback.message,
        ctx,
        "Вы выбрали VLESS — максимально быстрый и современный протокол. "
        "Он отлично работает на iOS, Android, Windows и macOS через любые V2Ray-клиенты.\n\n"
        "🏷 Придумайте название для вашего конфига:\n"
        "(Это имя будет отображаться в вашем приложении)\n\n"
        "⚠️ Требования:\n"
        "• До 20 символов\n"
        "• Латиница (A-z), цифры (0-9)\n"
        "• Дефис или пробел\n\n"
        "Введите имя сообщениям ниже: 👇",
        reply_markup=back_keyboard("main:home"),
    )


@router.callback_query(F.data.startswith("buy_vless_plan:"))
async def buy_vless_plan_selected(callback: CallbackQuery, bot: Bot, ctx: BotContext) -> None:
    if callback.from_user is None:
        return
    parts = (callback.data or "").split(":")
    if len(parts) < 2:
        await callback.answer("Некорректный тариф", show_alert=True)
        return
    days_str = parts[1]
    days = int(days_str)
    price = _plan_price_for_user(ctx, callback.from_user.id, days)
    if price is None:
        await callback.answer("Тариф недоступен", show_alert=True)
        return
    draft = ctx.vless_buy_draft.get(callback.from_user.id, {})
    client_name = draft.get("name", "")
    if not client_name:
        await callback.answer("Сначала введите имя", show_alert=True)
        return
    # Final pre-check before invoice to avoid paying for an already occupied name.
    info = await _get_vless_user_info(ctx, client_name)
    if info is not None:
        ctx.vless_buy_draft[callback.from_user.id] = {"step": "name"}
        await callback.answer("Имя уже занято", show_alert=True)
        if callback.message is None or not isinstance(callback.message, Message):
            return
        await _answer_ephemeral(
            callback.message,
            ctx,
            "Это имя уже занято. Введите другое имя для подписки:",
            reply_markup=back_keyboard("main:home"),
        )
        return
    ctx.vless_buy_draft.pop(callback.from_user.id, None)
    await callback.answer()
    await _clear_pending_invoice(ctx, bot, callback.from_user.id)
    preview_message = await bot.send_message(
        chat_id=callback.from_user.id,
        text=(
            "Вы почти у цели! Проверьте данные вашего заказа:\n"
            f"📝 Подписка: VLESS на {days} дней — «{html.escape(client_name)}»\n\n"
            "Для завершения покупки используются Telegram Stars. Это официальная валюта мессенджера, "
            "которую легко пополнить любой картой через посредников (важно, ниже лишь примеры):\n\n"
            "🔹 <a href=\"https://ggsel.net/catalog/telegram-stars\">GGSEL — Telegram Stars</a>\n"
            "🔹 <a href=\"https://plati.market/search/Telegram%20Stars\">Plati.Market — Telegram Stars</a>"
        ),
        parse_mode="HTML",
        disable_web_page_preview=True,
    )
    payload = InvoicePayload(
        action="buy",
        tg_user_id=callback.from_user.id,
        days=days,
        product="vless",
        client_name=client_name,
    ).encode()
    try:
        invoice_message = await bot.send_invoice(
            chat_id=callback.from_user.id,
            title=f"VLESS VPN {days} дней",
            description=f"VLESS подписка на {days} дней — {client_name}",
            payload=payload,
            provider_token=ctx.settings.telegram_provider_token,
            currency="XTR",
            prices=[LabeledPrice(label=f"VLESS {days} дней", amount=price)],
            start_parameter=f"buy-vless-{days}",
        )
    except Exception:
        await _delete_message_if_exists(bot, callback.from_user.id, preview_message.message_id)
        await bot.send_message(
            chat_id=callback.from_user.id,
            text="Не удалось создать счет на оплату. Попробуйте еще раз.",
        )
        return
    now = datetime.now(timezone.utc)
    await _store_pending_invoice(
        ctx,
        bot,
        PendingInvoice(
            chat_id=callback.from_user.id,
            invoice_message_id=invoice_message.message_id,
            preview_message_id=preview_message.message_id,
            payload=payload,
            kind="buy",
            created_at=now,
            expires_at=now + _PENDING_INVOICE_TTL,
        ),
    )


@router.callback_query(F.data.startswith("buy_server:"))
async def buy_server_selected(callback: CallbackQuery, ctx: BotContext) -> None:
    _ = ctx
    await callback.answer("Доступен только VLESS.", show_alert=True)


@router.callback_query(F.data.startswith("buy_plan:"))
async def buy_plan_selected(callback: CallbackQuery, bot: Bot, ctx: BotContext) -> None:
    _ = bot
    _ = ctx
    await callback.answer("Доступен только VLESS.", show_alert=True)


@router.message(F.text == "Мои подписки")
@router.message(F.text == "📁 Мои подписки")
async def list_subscriptions(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    await _show_user_subscriptions(message, ctx, message.from_user.id)


@router.message(F.text == "Продлить подписку")
async def extend_menu(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    async with ctx.db.session() as session:
        repo = BotRepository(session)
        bindings = await repo.list_client_bindings(message.from_user.id)
    vless_bindings = [binding for binding in bindings if binding.product_type == "vless"]
    if not vless_bindings:
        await _answer_ephemeral(message, ctx, "Нет VLESS подписок для продления.")
        return
    entries: list[tuple[str, str, str]] = []
    for binding in vless_bindings:
        info = await _get_vless_user_info(ctx, binding.client_name)
        if info is None:
            continue
        expiry_ms = _to_expiry_ms(info.get("expiryTime", 0))
        if not _is_extendable_expiry_ms(expiry_ms):
            continue
        exp = _format_expires_ms(expiry_ms)
        entries.append(("vless", binding.client_name, f"{binding.client_name} [VLESS] до {exp}"))
    if not entries:
        await _answer_ephemeral(
            message,
            ctx,
            "Нет срочных VLESS подписок для продления.",
            reply_markup=back_keyboard("main:home"),
        )
        return
    kb = bindings_keyboard(entries, prefix="extend_pick", back_callback="main:home")
    await _answer_ephemeral(message, ctx, "Выберите подписку для продления:", reply_markup=kb)


@router.callback_query(F.data.startswith("extend_pick:"))
async def extend_pick(callback: CallbackQuery, ctx: BotContext) -> None:
    parts = (callback.data or "").split(":")
    if len(parts) < 3:
        await callback.answer("Некорректный выбор", show_alert=True)
        return
    server_id, client_name = parts[1], parts[2]
    await callback.answer()
    message = callback.message
    if message is None or not isinstance(message, Message):
        return
    await _answer_ephemeral(
        message,
        ctx,
        "Выберите период продления:",
        reply_markup=plan_keyboard(
            f"extend_plan:{server_id}:{client_name}",
            back_callback="main:subs",
            back_text="⬅️ К подпискам",
        ),
    )


@router.callback_query(F.data.startswith("extend_plan:"))
async def extend_plan(callback: CallbackQuery, bot: Bot, ctx: BotContext) -> None:
    if callback.from_user is None:
        return
    parts = (callback.data or "").split(":")
    if len(parts) < 4:
        await callback.answer("Некорректный тариф", show_alert=True)
        return
    _, server_id, client_name, days = parts
    if server_id != "vless":
        await callback.answer("Доступно только VLESS продление.", show_alert=True)
        return
    info = await _get_vless_user_info(ctx, client_name)
    if info is None:
        await callback.answer("Подписка не найдена.", show_alert=True)
        return
    if not _is_extendable_expiry_ms(info.get("expiryTime", 0)):
        await callback.answer("Бессрочную подписку продлевать не нужно.", show_alert=True)
        return
    days_int = int(days)
    price = _plan_price_for_user(ctx, callback.from_user.id, days_int)
    if price is None:
        await callback.answer("Тариф недоступен", show_alert=True)
        return
    await callback.answer()
    await _clear_pending_invoice(ctx, bot, callback.from_user.id)
    payload = InvoicePayload(
        action="extend",
        tg_user_id=callback.from_user.id,
        days=days_int,
        server_id="vless",
        client_name=client_name,
        product="vless",
    ).encode()
    try:
        invoice_message = await bot.send_invoice(
            chat_id=callback.from_user.id,
            title=f"Продление VLESS на {days_int} дней",
            description=f"Продление существующей подписки на {days_int} дней",
            payload=payload,
            provider_token=ctx.settings.telegram_provider_token,
            currency="XTR",
            prices=[LabeledPrice(label=f"Продление {days_int} дней", amount=price)],
            start_parameter=f"extend-vless-{days_int}",
        )
    except Exception:
        await bot.send_message(
            chat_id=callback.from_user.id,
            text="Не удалось создать счет на оплату. Попробуйте еще раз.",
        )
        return
    now = datetime.now(timezone.utc)
    await _store_pending_invoice(
        ctx,
        bot,
        PendingInvoice(
            chat_id=callback.from_user.id,
            invoice_message_id=invoice_message.message_id,
            preview_message_id=None,
            payload=payload,
            kind="extend",
            created_at=now,
            expires_at=now + _PENDING_INVOICE_TTL,
        ),
    )


@router.message(F.text == "Подключение")
async def connect_menu(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    async with ctx.db.session() as session:
        repo = BotRepository(session)
        bindings = await repo.list_client_bindings(message.from_user.id)
    vless_bindings = [binding for binding in bindings if binding.product_type == "vless"]
    if not vless_bindings:
        await _answer_ephemeral(message, ctx, "Нет VLESS подписок. Сначала купите подписку.")
        return
    entries: list[tuple[str, str, str]] = []
    for binding in vless_bindings:
        exp = await _get_vless_expiry_str(ctx, binding.client_name)
        entries.append(("vless", binding.client_name, f"{binding.client_name} [VLESS] до {exp}"))
    kb = bindings_keyboard(entries, prefix="conn_pick", back_callback="main:home")
    await _answer_ephemeral(message, ctx, "Выберите подписку для подключения:", reply_markup=kb)


@router.callback_query(F.data.startswith("conn_pick:"))
async def connection_pick(callback: CallbackQuery, ctx: BotContext) -> None:
    if callback.from_user is None:
        return
    parts = (callback.data or "").split(":")
    if len(parts) < 3:
        await callback.answer("Некорректная подписка", show_alert=True)
        return
    server_id, client_name = parts[1], parts[2]
    if server_id != "vless":
        await callback.answer("Доступно только VLESS подключение.", show_alert=True)
        return
    if ctx.xui is None:
        await callback.answer("VLESS сервер не настроен.", show_alert=True)
        return
    await callback.answer()

    sub_url = ctx.xui.get_sub_url(callback.from_user.id)
    await callback.message.answer(
        f"VLESS подписка: `{client_name}`\n\n"
        f"Subscription URL (добавьте в V2Ray/Hiddify/Streisand):\n"
        f"`{sub_url}`",
        parse_mode="Markdown",
        reply_markup=back_keyboard("main:home", "⬅️ В меню"),
    )
    await callback.message.answer_photo(
        BufferedInputFile(_qr_png(sub_url), filename=f"{client_name}.png"),
        caption="QR для подписки VLESS",
    )


@router.message(F.text == "Поддержка")
@router.message(F.text == "Помощь")
@router.message(F.text == "ℹ️ Помощь")
async def support(message: Message, ctx: BotContext) -> None:
    await _show_support(message, ctx)


@router.message(F.text == "Админка")
@router.message(F.text == "Админ-меню")
@router.message(F.text == "🔐 Админ-меню")
async def admin_panel(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    await _show_admin_panel(message, ctx, message.from_user.id)


@router.callback_query(F.data == "adm:list")
async def admin_list_clients(callback: CallbackQuery, ctx: BotContext) -> None:
    if not _is_admin_cb(ctx, callback):
        return
    await callback.answer()
    if ctx.xui is None:
        if callback.message is not None and isinstance(callback.message, Message):
            await _answer_ephemeral(
                callback.message,
                ctx,
                "VLESS не настроен.",
                reply_markup=admin_home_keyboard(),
            )
        return
    lines: list[str] = ["Клиенты:", "", "VLESS:"]
    try:
        vless_clients = await ctx.xui.list_vless_clients()
    except XuiApiError:
        lines.append("  [VLESS] — ошибка API")
        vless_clients = []
    if vless_clients:
        for vc in vless_clients:
            email = vc.get("email", "?")
            enabled = "on" if vc.get("enable") else "off"
            online = "online" if vc.get("online") else "offline"
            exp = _format_expires_ms(vc.get("expiryTime", 0))
            lines.append(f"  VL: {email} | {enabled}/{online} | {exp}")
    else:
        lines.append("  Нет клиентов.")
    text = "\n".join(lines)
    if callback.message is None or not isinstance(callback.message, Message):
        return
    await _answer_ephemeral(callback.message, ctx, text, reply_markup=admin_home_keyboard())


@router.callback_query(F.data == "adm:create:start")
async def admin_create_start(callback: CallbackQuery, ctx: BotContext) -> None:
    if not _is_admin_cb(ctx, callback):
        return
    await callback.answer()
    if ctx.xui is None:
        if callback.message is not None and isinstance(callback.message, Message):
            await _answer_ephemeral(callback.message, ctx, "VLESS не настроен.", reply_markup=admin_home_keyboard())
        return
    rows = [
        [InlineKeyboardButton(text="VLESS", callback_data="adm:create:product:vl")],
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="main:admin")],
    ]
    if callback.message is None or not isinstance(callback.message, Message):
        return
    await _answer_ephemeral(
        callback.message,
        ctx,
        "Выберите тип клиента:",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=rows),
    )


@router.callback_query(F.data.startswith("adm:create:product:"))
async def admin_create_product(callback: CallbackQuery, ctx: BotContext) -> None:
    if not _is_admin_cb(ctx, callback):
        return
    await callback.answer()
    product = (callback.data or "").split(":")[-1]
    if product != "vl":
        if callback.message is not None and isinstance(callback.message, Message):
            await _answer_ephemeral(
                callback.message,
                ctx,
                "Доступно только создание VLESS клиента.",
                reply_markup=admin_home_keyboard(),
            )
        return
    if callback.from_user is not None:
        ctx.admin_create_draft[callback.from_user.id] = {
            "step": "name",
            "product": "vl",
        }
    if callback.message is None or not isinstance(callback.message, Message):
        return
    await _answer_ephemeral(
        callback.message,
        ctx,
        "Отправь имя клиента одним сообщением.",
        reply_markup=back_keyboard("main:admin"),
    )


@router.callback_query(F.data == "adm:extend:start")
async def admin_extend_start(callback: CallbackQuery, ctx: BotContext) -> None:
    if not _is_admin_cb(ctx, callback):
        return
    await callback.answer()
    if ctx.xui is None:
        if callback.message is not None and isinstance(callback.message, Message):
            await _answer_ephemeral(callback.message, ctx, "VLESS не настроен.", reply_markup=admin_home_keyboard())
        return
    rows: list[list[InlineKeyboardButton]] = []
    try:
        vless_clients = await ctx.xui.list_vless_clients()
    except XuiApiError:
        vless_clients = []
    for vc in vless_clients:
        if not _is_extendable_expiry_ms(vc.get("expiryTime", 0)):
            continue
        email = vc.get("email", "?")
        exp = _format_expires_ms(_to_expiry_ms(vc.get("expiryTime", 0)))
        label = f"VL: {email} | {exp}"
        cb_data = f"ae:vl:{email}"
        if len(cb_data.encode()) <= 64:
            rows.append([InlineKeyboardButton(text=label, callback_data=cb_data)])
    if not rows:
        if callback.message is not None and isinstance(callback.message, Message):
            await _answer_ephemeral(
                callback.message,
                ctx,
                "Нет срочных клиентов для продления.",
                reply_markup=admin_home_keyboard(),
            )
        return
    rows.append([InlineKeyboardButton(text="⬅️ Назад", callback_data="main:admin")])
    if callback.message is None or not isinstance(callback.message, Message):
        return
    await _answer_ephemeral(
        callback.message,
        ctx,
        "Выберите клиента:",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=rows),
    )


@router.callback_query(F.data.startswith("ae:"))
async def admin_extend_pick(callback: CallbackQuery, ctx: BotContext) -> None:
    if not _is_admin_cb(ctx, callback):
        return
    await callback.answer()
    parts = (callback.data or "").split(":")
    if len(parts) >= 3 and parts[1] == "vl":
        prefix = f"aed:vl:{parts[2]}"
    else:
        if callback.message is not None and isinstance(callback.message, Message):
            await _answer_ephemeral(callback.message, ctx, "Доступно только продление VLESS.")
        return
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="30 дней", callback_data=f"{prefix}:30")],
        [InlineKeyboardButton(text="90 дней", callback_data=f"{prefix}:90")],
        [InlineKeyboardButton(text="180 дней", callback_data=f"{prefix}:180")],
        [InlineKeyboardButton(text="⬅️ К клиентам", callback_data="adm:extend:start")],
    ])
    if callback.message is None or not isinstance(callback.message, Message):
        return
    await _answer_ephemeral(callback.message, ctx, "На сколько дней продлить?", reply_markup=kb)


@router.callback_query(F.data.startswith("aed:"))
async def admin_extend_apply(callback: CallbackQuery, ctx: BotContext) -> None:
    if not _is_admin_cb(ctx, callback):
        return
    await callback.answer()
    parts = (callback.data or "").split(":")
    try:
        if parts[1] == "vl" and len(parts) >= 4:
            email, days = parts[2], int(parts[3])
            if ctx.xui is None:
                if callback.message is not None and isinstance(callback.message, Message):
                    await _answer_ephemeral(
                        callback.message,
                        ctx,
                        "VLESS не настроен.",
                        reply_markup=admin_home_keyboard(),
                    )
                return
            info = await _get_vless_user_info(ctx, email)
            if info is None:
                if callback.message is not None and isinstance(callback.message, Message):
                    await _answer_ephemeral(callback.message, ctx, "Клиент не найден.")
                return
            if not _is_extendable_expiry_ms(info.get("expiryTime", 0)):
                if callback.message is not None and isinstance(callback.message, Message):
                    await _answer_ephemeral(callback.message, ctx, "Бессрочного клиента продлевать не нужно.")
                return
            new_exp = await ctx.xui.extend_vless_user(email, days)
            exp = _format_expires_ms(new_exp)
            if callback.message is None or not isinstance(callback.message, Message):
                return
            await _answer_ephemeral(
                callback.message,
                ctx,
                f"VL: `{email}` продлен на {days} дней.\nНовый срок: {exp}",
                parse_mode="Markdown",
            )
        else:
            if callback.message is not None and isinstance(callback.message, Message):
                await _answer_ephemeral(callback.message, ctx, "Доступно только продление VLESS.")
    except XuiApiError as exc:
        if callback.message is not None and isinstance(callback.message, Message):
            await callback.message.answer(
                f"Ошибка: {exc}",
                reply_markup=admin_home_keyboard(),
            )


@router.pre_checkout_query()
async def pre_checkout(pre_checkout_query: PreCheckoutQuery, ctx: BotContext) -> None:
    # Payload validation is performed on successful_payment too.
    try:
        payload = InvoicePayload.decode(pre_checkout_query.invoice_payload)
    except Exception:
        payload = None
    if payload is not None and payload.tg_user_id == pre_checkout_query.from_user.id:
        await _mark_pending_invoice_checkout(ctx, payload.tg_user_id)
    await pre_checkout_query.answer(ok=True)


@router.message(F.successful_payment)
async def successful_payment(message: Message, ctx: BotContext) -> None:
    if message.from_user is None or message.successful_payment is None:
        return
    payment = message.successful_payment
    try:
        payload = InvoicePayload.decode(payment.invoice_payload)
    except Exception:
        await message.answer("Некорректный payload платежа.")
        return
    if payload.tg_user_id != message.from_user.id:
        await message.answer("Payload не соответствует пользователю.")
        return
    await _clear_pending_invoice(ctx, message.bot, message.from_user.id)

    async with ctx.db.session() as session:
        repo = BotRepository(session)
        is_new = await repo.mark_payment_if_new(
            telegram_charge_id=payment.telegram_payment_charge_id,
            provider_charge_id=payment.provider_payment_charge_id,
            invoice_payload=payment.invoice_payload,
            amount_xtr=payment.total_amount,
            tg_user_id=message.from_user.id,
        )
        if not is_new:
            await message.answer("Платеж уже обработан ранее.")
            return

        if payload.product != "vless":
            await message.answer("Поддерживается только VLESS.")
            return

        if payload.action == "buy":
            await _handle_buy_vless(message, ctx, repo, payload, payment)
            return

        if payload.action == "extend":
            await _handle_extend_vless(message, ctx, repo, payload, payment)
            return

        await message.answer("Неизвестное действие платежа.")


@router.message()
async def fallback(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    if await _handle_vless_buy_name(message, ctx):
        return
    if await _handle_admin_create_draft(message, ctx):
        return
    await _answer_ephemeral(message, ctx, "Используйте кнопки меню ниже.")
    await _show_main_menu(message, ctx, message.from_user.id)


def _fmt_dt(value: datetime | None) -> str:
    if value is None:
        return "бессрочно"
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def _qr_png(data: str) -> bytes:
    image = qrcode.make(data)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def _is_admin(ctx: BotContext, tg_user_id: int) -> bool:
    return tg_user_id in ctx.settings.bot_admin_ids


def _is_admin_cb(ctx: BotContext, callback: CallbackQuery) -> bool:
    user = callback.from_user
    if user is None or not _is_admin(ctx, user.id):
        return False
    return True


def _plan_price(ctx: BotContext, days: int) -> int | None:
    if days == 30:
        return ctx.settings.price_30_xtr
    if days == 90:
        return ctx.settings.price_90_xtr
    if days == 180:
        return ctx.settings.price_180_xtr
    return None


def _plan_price_for_user(ctx: BotContext, tg_user_id: int, days: int) -> int | None:
    if _is_admin(ctx, tg_user_id):
        return ctx.settings.admin_price_xtr
    return _plan_price(ctx, days)


def _validate_vless_name(name: str) -> str | None:
    """Return error message or None if valid."""
    if not name:
        return "Имя не может быть пустым."
    if len(name) > 20:
        return "Максимум 20 символов."
    if not re.match(r'^[A-Za-z0-9][A-Za-z0-9 _-]*$', name):
        return "Только латиница, цифры, пробелы, дефис, подчёркивание. Первый символ — буква/цифра."
    if '  ' in name:
        return "Двойные пробелы не допускаются."
    return None


async def _handle_vless_buy_name(message: Message, ctx: BotContext) -> bool:
    """Intercept text message when user is choosing a VLESS name for purchase."""
    if message.from_user is None:
        return False
    draft = ctx.vless_buy_draft.get(message.from_user.id)
    if not draft or draft.get("step") != "name":
        return False
    name = (message.text or "").strip()
    error = _validate_vless_name(name)
    if error:
        await _answer_ephemeral(
            message,
            ctx,
            f"Некорректное имя: {error}\nПопробуйте ещё раз:",
            reply_markup=back_keyboard("main:home"),
        )
        return True
    if ctx.xui is not None:
        existing = await ctx.xui.get_vless_user_info(name)
        if existing is not None:
            await _answer_ephemeral(
                message,
                ctx,
                "Это имя уже занято. Выберите другое:",
                reply_markup=back_keyboard("main:home"),
            )
            return True
    draft["name"] = name
    draft["step"] = "plan"
    await _answer_ephemeral(
        message,
        ctx,
        f"Имя: `{name}`\nВыберите тариф:",
        reply_markup=plan_keyboard("buy_vless_plan", back_callback="main:home"),
        parse_mode="Markdown",
    )
    return True


async def _handle_admin_create_draft(message: Message, ctx: BotContext) -> bool:
    if message.from_user is None or not _is_admin(ctx, message.from_user.id):
        return False
    draft = ctx.admin_create_draft.get(message.from_user.id)
    if not draft:
        return False
    text = (message.text or "").strip()
    step = draft.get("step")
    if step == "name":
        if not text:
            await _answer_ephemeral(message, ctx, "Имя пустое. Введи имя клиента.")
            return True
        error = _validate_vless_name(text)
        if error:
            await _answer_ephemeral(message, ctx, f"Некорректное имя: {error}")
            return True
        draft["name"] = text
        draft["step"] = "days"
        await _answer_ephemeral(message, ctx, "Срок? Отправь число дней (30/90/180) или 0 для бессрочно.")
        return True
    if step == "days":
        try:
            days = int(text)
        except ValueError:
            await _answer_ephemeral(message, ctx, "Нужно число дней. Пример: 30")
            return True
        name = draft.get("name", "")
        ctx.admin_create_draft.pop(message.from_user.id, None)
        if ctx.xui is None:
            await message.answer("VLESS не настроен.", reply_markup=admin_home_keyboard())
            return True
        try:
            vless_user = await ctx.xui.create_vless_user(
                name, message.from_user.id, None if days == 0 else days,
            )
            async with ctx.db.session() as session:
                repo = BotRepository(session)
                await repo.upsert_client_binding(
                    message.from_user.id, "vless", vless_user.email, product_type="vless",
                )
        except XuiApiError as exc:
            await message.answer(f"Ошибка 3x-ui: {exc}", reply_markup=admin_home_keyboard())
            return True
        exp = _format_expires_ms(vless_user.expiry_time)
        sub_url = vless_user.sub_url
        await message.answer(
            f"VLESS клиент создан: `{vless_user.email}`\n"
            f"Действует до: {exp}\n\nSub URL:\n`{sub_url}`",
            parse_mode="Markdown",
        )
        await message.answer_photo(
            BufferedInputFile(_qr_png(sub_url), filename=f"{name}.png"),
            caption="QR для подписки VLESS",
        )
        return True
    return False


def _selected_server_id(ctx: BotContext, tg_user_id: int) -> str:
    return ctx.selected_server.get(tg_user_id, ctx.settings.default_server_id)


def _selected_server_for_user(ctx: BotContext, tg_user_id: int) -> VpnServer:
    sid = _selected_server_id(ctx, tg_user_id)
    return _get_server(ctx, sid)


def _server_exists(ctx: BotContext, server_id: str) -> bool:
    return any(s.server_id == server_id for s in ctx.settings.vpn_servers)


def _get_server(ctx: BotContext, server_id: str) -> VpnServer:
    for server in ctx.settings.vpn_servers:
        if server.server_id == server_id:
            return server
    return ctx.settings.vpn_servers[0]


async def _handle_buy_vless(
    message: Message,
    ctx: BotContext,
    repo: BotRepository,
    payload: InvoicePayload,
    payment: Any,
) -> None:
    if ctx.xui is None:
        await message.answer("Оплата прошла, но VLESS сервер не настроен.")
        return
    requested_name = payload.client_name or f"tg_{message.from_user.id}_{uuid.uuid4().hex[:8]}"
    client_name = requested_name
    vless_user: Any
    try:
        vless_user = await ctx.xui.create_vless_user(client_name, message.from_user.id, payload.days)
    except XuiApiError as exc:
        err_text = str(exc)
        if _is_duplicate_email_error(err_text):
            fallback_name = _build_fallback_client_name(client_name)
            try:
                vless_user = await ctx.xui.create_vless_user(fallback_name, message.from_user.id, payload.days)
                client_name = fallback_name
                await repo.add_subscription_event(
                    f"vless:{client_name}",
                    "provision_duplicate_renamed",
                    {
                        "requested_name": requested_name,
                        "resolved_name": client_name,
                        "days": payload.days,
                        "charge_id": payment.telegram_payment_charge_id,
                    },
                )
            except XuiApiError as fallback_exc:
                logger.exception("xui_api_error payment_buy_vless_duplicate_fallback")
                await _handle_payment_provision_failed(
                    ctx=ctx,
                    message=message,
                    repo=repo,
                    client_name=requested_name,
                    days=payload.days,
                    amount_xtr=payment.total_amount,
                    charge_id=payment.telegram_payment_charge_id,
                    error_text=str(fallback_exc),
                )
                return
        else:
            await repo.add_subscription_event(
                f"vless:{requested_name}",
                "provision_retry",
                {
                    "requested_name": requested_name,
                    "days": payload.days,
                    "charge_id": payment.telegram_payment_charge_id,
                    "error": err_text,
                },
            )
            try:
                vless_user = await ctx.xui.create_vless_user(client_name, message.from_user.id, payload.days)
            except XuiApiError as retry_exc:
                logger.exception("xui_api_error payment_buy_vless_retry_failed")
                await _handle_payment_provision_failed(
                    ctx=ctx,
                    message=message,
                    repo=repo,
                    client_name=requested_name,
                    days=payload.days,
                    amount_xtr=payment.total_amount,
                    charge_id=payment.telegram_payment_charge_id,
                    error_text=str(retry_exc),
                )
                return

    await repo.upsert_client_binding(message.from_user.id, "vless", vless_user.email, product_type="vless")
    await repo.add_subscription_event(
        f"vless:{vless_user.email}",
        "created_via_payment",
        {
            "days": payload.days,
            "charge_id": payment.telegram_payment_charge_id,
            "requested_name": requested_name,
            "resolved_name": vless_user.email,
        },
    )

    expiry_str = _format_expires_ms(vless_user.expiry_time)
    sub_url = vless_user.sub_url
    await message.answer(
        f"VLESS подписка создана!\n\n"
        f"Email: `{vless_user.email}`\n"
        f"Действует до: {expiry_str}\n\n"
        f"Subscription URL (добавьте в V2Ray/Hiddify/Streisand):\n"
        f"`{sub_url}`",
        parse_mode="Markdown",
    )
    await message.answer_photo(
        BufferedInputFile(_qr_png(sub_url), filename=f"{client_name}.png"),
        caption="QR для подписки VLESS",
    )
    await _notify_payment_to_admins(
        ctx=ctx,
        message=message,
        action="buy",
        client_name=vless_user.email,
        days=payload.days,
        amount_xtr=payment.total_amount,
    )


async def _handle_extend_vless(
    message: Message,
    ctx: BotContext,
    repo: BotRepository,
    payload: InvoicePayload,
    payment: Any,
) -> None:
    if ctx.xui is None:
        await message.answer("Оплата прошла, но VLESS сервер не настроен.")
        return
    if not payload.client_name:
        await message.answer("Не указан client_name для продления VLESS.")
        return
    try:
        new_expiry_ms = await ctx.xui.extend_vless_user(payload.client_name, payload.days)
        await repo.upsert_client_binding(message.from_user.id, "vless", payload.client_name, product_type="vless")
        await repo.add_subscription_event(
            f"vless:{payload.client_name}",
            "extended_via_payment",
            {"days": payload.days, "charge_id": payment.telegram_payment_charge_id},
        )
    except XuiApiError as exc:
        logger.exception("xui_api_error payment_extend_vless")
        await message.answer(f"Оплата прошла, но ошибка продления VLESS: {exc}")
        return
    await message.answer(
        f"VLESS подписка `{payload.client_name}` продлена на {payload.days} дней.\n"
        f"Новый срок: {_format_expires_ms(new_expiry_ms)}",
        parse_mode="Markdown",
    )
    await _notify_payment_to_admins(
        ctx=ctx,
        message=message,
        action="extend",
        client_name=payload.client_name,
        days=payload.days,
        amount_xtr=payment.total_amount,
    )


async def _notify_payment_to_admins(
    ctx: BotContext,
    message: Message,
    action: str,
    client_name: str,
    days: int,
    amount_xtr: int,
) -> None:
    user = message.from_user
    if user is None:
        return
    admin_ids = sorted(ctx.settings.bot_admin_ids)
    if not admin_ids:
        return
    username = f"@{user.username}" if user.username else "-"
    full_name = user.full_name or "-"
    months = max(1, days // 30) if days > 0 else 0
    if action == "buy":
        action_line = f"Купил подписку {client_name} -> на {months} мес. ({days} дней) за {amount_xtr} ⭐"
    elif action == "extend":
        action_line = f"Продлил подписку {client_name} -> на {months} мес. ({days} дней) за {amount_xtr} ⭐"
    else:
        action_line = f"Операция {action} {client_name} -> на {days} дней за {amount_xtr} ⭐"
    text = (
        f"ID: {user.id}\n"
        f"Username: {username}\n"
        f"Name: {full_name}\n"
        f"{action_line}"
    )
    for admin_id in admin_ids:
        try:
            await message.bot.send_message(chat_id=admin_id, text=text)
        except Exception as exc:  # noqa: BLE001
            logger.warning("payment_notify_failed admin_id=%s err=%s", admin_id, exc)


def _is_duplicate_email_error(error_text: str) -> bool:
    return "duplicate email" in error_text.lower()


def _build_fallback_client_name(base_name: str) -> str:
    suffix = uuid.uuid4().hex[:4]
    normalized = (base_name or "vless").strip()
    max_prefix_len = max(1, 20 - len(suffix) - 1)
    prefix = normalized[:max_prefix_len].rstrip(" _-")
    if not prefix:
        prefix = "vless"
    return f"{prefix}-{suffix}"


async def _handle_payment_provision_failed(
    ctx: BotContext,
    message: Message,
    repo: BotRepository,
    client_name: str,
    days: int,
    amount_xtr: int,
    charge_id: str,
    error_text: str,
) -> None:
    await repo.add_subscription_event(
        f"vless:{client_name}",
        "provision_failed_after_payment",
        {
            "client_name": client_name,
            "days": days,
            "charge_id": charge_id,
            "error": error_text,
        },
    )
    await message.answer(
        "Оплата прошла, но выдача подписки временно не завершена.\n"
        "Мы уже уведомили администратора и вручную завершим активацию.",
    )
    await _notify_provision_failed_to_admins(
        ctx=ctx,
        message=message,
        client_name=client_name,
        days=days,
        amount_xtr=amount_xtr,
        charge_id=charge_id,
        error_text=error_text,
    )


async def _notify_provision_failed_to_admins(
    ctx: BotContext,
    message: Message,
    client_name: str,
    days: int,
    amount_xtr: int,
    charge_id: str,
    error_text: str,
) -> None:
    user = message.from_user
    if user is None:
        return
    admin_ids = sorted(ctx.settings.bot_admin_ids)
    if not admin_ids:
        return
    username = f"@{user.username}" if user.username else "-"
    full_name = user.full_name or "-"
    text = (
        "PAYMENT PROVISION FAILED\n"
        f"ID: {user.id}\n"
        f"Username: {username}\n"
        f"Name: {full_name}\n"
        f"Client: {client_name}\n"
        f"Days: {days}\n"
        f"Amount: {amount_xtr} ⭐\n"
        f"Charge: {charge_id}\n"
        f"Error: {error_text}"
    )
    for admin_id in admin_ids:
        try:
            await message.bot.send_message(chat_id=admin_id, text=text)
        except Exception as exc:  # noqa: BLE001
            logger.warning("provision_failed_notify admin_id=%s err=%s", admin_id, exc)


async def _get_vless_user_info(ctx: BotContext, email: str) -> dict[str, Any] | None:
    if ctx.xui is None:
        return None
    try:
        return await ctx.xui.get_vless_user_info(email)
    except XuiApiError:
        return None


async def _get_vless_expiry_str(ctx: BotContext, email: str) -> str:
    info = await _get_vless_user_info(ctx, email)
    if info is None:
        return "N/A"
    return _format_expires_ms(_to_expiry_ms(info.get("expiryTime", 0)))


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


def _is_extendable_expiry_ms(value: object) -> bool:
    return _to_expiry_ms(value) > 0


def _format_expires_ms(ms: int | None) -> str:
    """Format expiry time in milliseconds to a human-readable string."""
    expiry_ms = _to_expiry_ms(ms)
    if expiry_ms <= 0:
        return "∞"
    from datetime import datetime, timezone
    dt = datetime.fromtimestamp(expiry_ms / 1000, tz=timezone.utc)
    return dt.strftime("%Y-%m-%d %H:%M UTC")


def _sanitize_conn_string(conn_string: str) -> str:
    if not conn_string:
        raise ValueError("empty conn_string")
    padded = conn_string + "=" * ((4 - len(conn_string) % 4) % 4)
    try:
        raw = base64.urlsafe_b64decode(padded.encode("ascii"))
        payload = json.loads(raw.decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        raise ValueError("invalid base64/json payload") from exc
    if not isinstance(payload, dict):
        raise ValueError("payload is not object")
    # Never issue admin credentials through Telegram bot
    payload.pop("admin", None)
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(encoded).decode("ascii").rstrip("=")
