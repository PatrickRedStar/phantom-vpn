from __future__ import annotations

import base64
import json
import io
import logging
import re
import uuid
from datetime import datetime, timezone
import qrcode
from aiogram import Bot, Dispatcher, F, Router
from aiogram.filters import CommandStart
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
    main_menu_keyboard,
    plan_keyboard,
    product_keyboard,
    server_select_keyboard,
    subscriptions_keyboard,
    bindings_keyboard,
)
from app.payments import InvoicePayload
from app.repositories import BotRepository
from app.xui_client import XuiApiClient, XuiApiError

logger = logging.getLogger(__name__)
router = Router()


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


def build_dispatcher(ctx: BotContext) -> Dispatcher:
    dp = Dispatcher()
    dp["ctx"] = ctx
    dp.include_router(router)
    return dp


@router.message(CommandStart())
async def cmd_start(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    async with ctx.db.session() as session:
        repo = BotRepository(session)
        await repo.ensure_user(message.from_user.id, message.from_user.username)
    await message.answer(
        "GhostStream Bot запущен.\nВыберите действие:",
        reply_markup=main_menu_keyboard(is_admin=_is_admin(ctx, message.from_user.id)),
    )


@router.message(F.text == "Купить подписку")
async def buy_subscription(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    if ctx.xui is not None:
        await message.answer("Выберите продукт:", reply_markup=product_keyboard("buy_product"))
        return
    # No VLESS available — go straight to GhostStream flow
    server = _selected_server_for_user(ctx, message.from_user.id)
    if server is None:
        servers = [(s.server_id, s.name) for s in ctx.settings.vpn_servers]
        await message.answer("Выберите VPN сервер:", reply_markup=server_select_keyboard(servers, "buy_server"))
        return
    await message.answer(f"Сервер: {server.name}\nВыберите тариф:", reply_markup=plan_keyboard(f"buy_plan:{server.server_id}"))


@router.callback_query(F.data.startswith("buy_product:"))
async def buy_product_selected(callback: CallbackQuery, ctx: BotContext) -> None:
    if callback.from_user is None:
        return
    product = (callback.data or "").split(":")[1]
    await callback.answer()
    if product == "vless":
        ctx.vless_buy_draft[callback.from_user.id] = {"step": "name"}
        await callback.message.answer(
            "VLESS — универсальный протокол для iOS и любых V2Ray-клиентов.\n\n"
            "Введите имя для подписки (до 20 символов, латиница, цифры, дефис, пробел):",
        )
        return
    # GhostStream — continue with server selection
    server = _selected_server_for_user(ctx, callback.from_user.id)
    if server is None:
        servers = [(s.server_id, s.name) for s in ctx.settings.vpn_servers]
        await callback.message.answer("Выберите VPN сервер:", reply_markup=server_select_keyboard(servers, "buy_server"))
        return
    await callback.message.answer(
        f"Сервер: {server.name}\nВыберите тариф:",
        reply_markup=plan_keyboard(f"buy_plan:{server.server_id}"),
    )


@router.callback_query(F.data.startswith("buy_vless_plan:"))
async def buy_vless_plan_selected(callback: CallbackQuery, bot: Bot, ctx: BotContext) -> None:
    if callback.from_user is None:
        return
    days_str = (callback.data or "").split(":")[1]
    days = int(days_str)
    price = _plan_price(ctx, days)
    if price is None:
        await callback.answer("Тариф недоступен", show_alert=True)
        return
    draft = ctx.vless_buy_draft.pop(callback.from_user.id, {})
    client_name = draft.get("name", "")
    if not client_name:
        await callback.answer("Сначала введите имя", show_alert=True)
        return
    await callback.answer()
    payload = InvoicePayload(
        action="buy",
        tg_user_id=callback.from_user.id,
        days=days,
        product="vless",
        client_name=client_name,
    ).encode()
    await bot.send_invoice(
        chat_id=callback.from_user.id,
        title=f"VLESS VPN {days} дней",
        description=f"VLESS подписка на {days} дней — {client_name}",
        payload=payload,
        provider_token=ctx.settings.telegram_provider_token,
        currency="XTR",
        prices=[LabeledPrice(label=f"VLESS {days} дней", amount=price)],
        start_parameter=f"buy-vless-{days}",
    )


@router.callback_query(F.data.startswith("buy_server:"))
async def buy_server_selected(callback: CallbackQuery, ctx: BotContext) -> None:
    if callback.from_user is None:
        return
    server_id = (callback.data or "").split(":")[1]
    if not _server_exists(ctx, server_id):
        await callback.answer("Сервер не найден", show_alert=True)
        return
    ctx.selected_server[callback.from_user.id] = server_id
    await callback.answer()
    server = _get_server(ctx, server_id)
    await callback.message.answer(
        f"Сервер: {server.name}\nВыберите тариф:",
        reply_markup=plan_keyboard(f"buy_plan:{server_id}"),
    )


@router.callback_query(F.data.startswith("buy_plan:"))
async def buy_plan_selected(callback: CallbackQuery, bot: Bot, ctx: BotContext) -> None:
    if callback.from_user is None:
        return
    parts = (callback.data or "").split(":")
    if len(parts) == 3:
        _, server_id, days_str = parts
    elif len(parts) == 2:
        _, days_str = parts
        server_id = _selected_server_id(ctx, callback.from_user.id)
    else:
        await callback.answer("Некорректный тариф", show_alert=True)
        return
    days = int(days_str)
    price = _plan_price(ctx, days)
    if price is None:
        await callback.answer("Тариф недоступен", show_alert=True)
        return
    if not _server_exists(ctx, server_id):
        await callback.answer("Сервер не выбран", show_alert=True)
        return
    await callback.answer()
    payload = InvoicePayload(
        action="buy",
        tg_user_id=callback.from_user.id,
        days=days,
        server_id=server_id,
    ).encode()
    await bot.send_invoice(
        chat_id=callback.from_user.id,
        title=f"GhostStream VPN {days} дней",
        description=f"Новая подписка на {days} дней",
        payload=payload,
        provider_token=ctx.settings.telegram_provider_token,
        currency="XTR",
        prices=[LabeledPrice(label=f"Подписка {days} дней", amount=price)],
        start_parameter=f"buy-{days}",
    )


@router.message(F.text == "Мои подписки")
async def list_subscriptions(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    async with ctx.db.session() as session:
        repo = BotRepository(session)
        bindings = await repo.list_client_bindings(message.from_user.id)
    if not bindings:
        await message.answer("Подписок пока нет. Нажмите «Купить подписку».")
        return
    lines = []
    for binding in bindings:
        if binding.product_type == "vless":
            await _append_vless_binding_info(lines, ctx, binding)
        else:
            server = _get_server(ctx, binding.server_id)
            try:
                client = await ctx.admin.get_client_by_name(binding.client_name, server_id=binding.server_id)
            except AdminApiError:
                client = None
            if client is None:
                lines.append(f"- {binding.client_name} [{server.name}] GhostStream | server unavailable")
                continue
            expires = _format_expires(client.get("expires_at"))
            enabled = "on" if client.get("enabled") else "off"
            online = "online" if client.get("connected") else "offline"
            lines.append(f"- {binding.client_name} [{server.name}] GhostStream | {enabled}/{online} | до: {expires}")
    await message.answer("Ваши подписки:\n" + "\n".join(lines))


@router.message(F.text == "Продлить подписку")
async def extend_menu(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    async with ctx.db.session() as session:
        repo = BotRepository(session)
        bindings = await repo.list_client_bindings(message.from_user.id)
    if not bindings:
        await message.answer("Нет подписок для продления.")
        return
    entries: list[tuple[str, str, str]] = []
    for b in bindings:
        if b.product_type == "vless":
            exp = await _get_vless_expiry_str(ctx, b.client_name)
            entries.append((b.server_id, b.client_name, f"{b.client_name} [VLESS] до {exp}"))
        else:
            server = _get_server(ctx, b.server_id)
            try:
                client = await ctx.admin.get_client_by_name(b.client_name, server_id=b.server_id)
            except AdminApiError:
                client = None
            exp = _format_expires((client or {}).get("expires_at"))
            entries.append((b.server_id, b.client_name, f"{b.client_name} [{server.name}] до {exp}"))
    kb = bindings_keyboard(entries, prefix="extend_pick")
    await message.answer("Выберите подписку для продления:", reply_markup=kb)


@router.callback_query(F.data.startswith("extend_pick:"))
async def extend_pick(callback: CallbackQuery) -> None:
    parts = (callback.data or "").split(":")
    if len(parts) < 3:
        await callback.answer("Некорректный выбор", show_alert=True)
        return
    server_id, client_name = parts[1], parts[2]
    await callback.answer()
    await callback.message.answer(
        "Выберите период продления:",
        reply_markup=plan_keyboard(f"extend_plan:{server_id}:{client_name}"),
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
    days_int = int(days)
    price = _plan_price(ctx, days_int)
    if price is None:
        await callback.answer("Тариф недоступен", show_alert=True)
        return
    is_vless = server_id == "vless"
    product = "vless" if is_vless else "ghoststream"
    product_label = "VLESS" if is_vless else "GhostStream"
    await callback.answer()
    payload = InvoicePayload(
        action="extend",
        tg_user_id=callback.from_user.id,
        days=days_int,
        server_id=server_id,
        client_name=client_name,
        product=product,
    ).encode()
    await bot.send_invoice(
        chat_id=callback.from_user.id,
        title=f"Продление {product_label} на {days_int} дней",
        description=f"Продление существующей подписки на {days_int} дней",
        payload=payload,
        provider_token=ctx.settings.telegram_provider_token,
        currency="XTR",
        prices=[LabeledPrice(label=f"Продление {days_int} дней", amount=price)],
        start_parameter=f"extend-{product}-{days_int}",
    )


@router.message(F.text == "Подключение")
async def connect_menu(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    async with ctx.db.session() as session:
        repo = BotRepository(session)
        bindings = await repo.list_client_bindings(message.from_user.id)
    if not bindings:
        await message.answer("Нет подписок. Сначала купите подписку.")
        return
    entries: list[tuple[str, str, str]] = []
    for b in bindings:
        if b.product_type == "vless":
            exp = await _get_vless_expiry_str(ctx, b.client_name)
            entries.append((b.server_id, b.client_name, f"{b.client_name} [VLESS] до {exp}"))
        else:
            server = _get_server(ctx, b.server_id)
            try:
                client = await ctx.admin.get_client_by_name(b.client_name, server_id=b.server_id)
            except AdminApiError:
                client = None
            exp = _format_expires((client or {}).get("expires_at"))
            entries.append((b.server_id, b.client_name, f"{b.client_name} [{server.name}] до {exp}"))
    kb = bindings_keyboard(entries, prefix="conn_pick")
    await message.answer("Выберите подписку для подключения:", reply_markup=kb)


@router.callback_query(F.data.startswith("conn_pick:"))
async def connection_pick(callback: CallbackQuery, ctx: BotContext) -> None:
    if callback.from_user is None:
        return
    parts = (callback.data or "").split(":")
    if len(parts) < 3:
        await callback.answer("Некорректная подписка", show_alert=True)
        return
    server_id, client_name = parts[1], parts[2]
    await callback.answer()

    # VLESS — send subscription URL instead of conn_string
    if server_id == "vless" and ctx.xui is not None:
        sub_url = ctx.xui.get_sub_url(callback.from_user.id)
        await callback.message.answer(
            f"VLESS подписка: `{client_name}`\n\n"
            f"Subscription URL (добавьте в V2Ray/Hiddify/Streisand):\n"
            f"`{sub_url}`",
            parse_mode="Markdown",
        )
        await callback.message.answer_photo(
            BufferedInputFile(_qr_png(sub_url), filename=f"{client_name}.png"),
            caption="QR для подписки VLESS",
        )
        return

    try:
        raw_conn_string = await ctx.admin.get_conn_string(client_name, server_id=server_id)
        conn_string = _sanitize_conn_string(raw_conn_string)
    except AdminApiError as exc:
        await callback.message.answer(f"Ошибка Admin API: {exc}")
        return
    except ValueError as exc:
        await callback.message.answer(f"Conn string отклонен: {exc}")
        return
    await callback.message.answer(f"`{conn_string}`", parse_mode="Markdown")
    await callback.message.answer_photo(
        BufferedInputFile(_qr_png(conn_string), filename=f"{client_name}.png"),
        caption=f"QR для {client_name}",
    )


@router.message(F.text == "Поддержка")
async def support(message: Message) -> None:
    await message.answer("Поддержка: @ghoststream_support")


@router.message(F.text == "Админка")
async def admin_panel(message: Message, ctx: BotContext) -> None:
    if message.from_user is None:
        return
    if not _is_admin(ctx, message.from_user.id):
        await message.answer("Доступ запрещен.")
        return
    await message.answer("Админ-меню:", reply_markup=admin_home_keyboard())


@router.callback_query(F.data == "adm:list")
async def admin_list_clients(callback: CallbackQuery, ctx: BotContext) -> None:
    if not _is_admin_cb(ctx, callback):
        return
    await callback.answer()
    lines: list[str] = ["Клиенты:"]
    for server in ctx.settings.vpn_servers:
        try:
            clients = await ctx.admin.list_clients(server_id=server.server_id)
        except AdminApiError:
            lines.append(f"\n[{server.name}] — ошибка API")
            continue
        if clients:
            lines.append(f"\n{server.name}:")
            for c in clients:
                name = c.get("name", "?")
                enabled = "on" if c.get("enabled") else "off"
                online = "online" if c.get("connected") else "offline"
                exp = _format_expires(c.get("expires_at"))
                lines.append(f"  GS: {name} | {enabled}/{online} | {exp}")
    if ctx.xui is not None:
        try:
            vless_clients = await ctx.xui.list_vless_clients()
        except XuiApiError:
            lines.append("\n[VLESS] — ошибка API")
            vless_clients = []
        if vless_clients:
            lines.append("\nVLESS:")
            for vc in vless_clients:
                email = vc.get("email", "?")
                enabled = "on" if vc.get("enable") else "off"
                online = "online" if vc.get("online") else "offline"
                exp = _format_expires_ms(vc.get("expiryTime", 0))
                lines.append(f"  VL: {email} | {enabled}/{online} | {exp}")
    text = "\n".join(lines) if len(lines) > 1 else "Клиентов нет."
    await callback.message.answer(text, reply_markup=admin_home_keyboard())


@router.callback_query(F.data == "adm:create:start")
async def admin_create_start(callback: CallbackQuery, ctx: BotContext) -> None:
    if not _is_admin_cb(ctx, callback):
        return
    await callback.answer()
    rows = [[InlineKeyboardButton(text="GhostStream", callback_data="adm:create:product:gs")]]
    if ctx.xui is not None:
        rows.append([InlineKeyboardButton(text="VLESS", callback_data="adm:create:product:vl")])
    await callback.message.answer("Выберите тип клиента:", reply_markup=InlineKeyboardMarkup(inline_keyboard=rows))


@router.callback_query(F.data.startswith("adm:create:product:"))
async def admin_create_product(callback: CallbackQuery, ctx: BotContext) -> None:
    if not _is_admin_cb(ctx, callback):
        return
    await callback.answer()
    product = (callback.data or "").split(":")[-1]
    if callback.from_user is not None:
        ctx.admin_create_draft[callback.from_user.id] = {
            "step": "name",
            "product": product,
            "server_id": _selected_server_id(ctx, callback.from_user.id),
        }
    await callback.message.answer("Отправь имя клиента одним сообщением.")


@router.callback_query(F.data == "adm:extend:start")
async def admin_extend_start(callback: CallbackQuery, ctx: BotContext) -> None:
    if not _is_admin_cb(ctx, callback):
        return
    await callback.answer()
    rows: list[list[InlineKeyboardButton]] = []
    for server in ctx.settings.vpn_servers:
        try:
            clients = await ctx.admin.list_clients(server_id=server.server_id)
        except AdminApiError:
            continue
        for c in clients:
            name = c.get("name", "?")
            exp = _format_expires(c.get("expires_at"))
            label = f"GS: {name} | {exp}"
            cb_data = f"ae:gs:{server.server_id}:{name}"
            if len(cb_data.encode()) <= 64:
                rows.append([InlineKeyboardButton(text=label, callback_data=cb_data)])
    if ctx.xui is not None:
        try:
            vless_clients = await ctx.xui.list_vless_clients()
        except XuiApiError:
            vless_clients = []
        for vc in vless_clients:
            email = vc.get("email", "?")
            exp = _format_expires_ms(vc.get("expiryTime", 0))
            label = f"VL: {email} | {exp}"
            cb_data = f"ae:vl:{email}"
            if len(cb_data.encode()) <= 64:
                rows.append([InlineKeyboardButton(text=label, callback_data=cb_data)])
    if not rows:
        await callback.message.answer("Нет клиентов для продления.", reply_markup=admin_home_keyboard())
        return
    await callback.message.answer("Выберите клиента:", reply_markup=InlineKeyboardMarkup(inline_keyboard=rows))


@router.callback_query(F.data.startswith("ae:"))
async def admin_extend_pick(callback: CallbackQuery, ctx: BotContext) -> None:
    if not _is_admin_cb(ctx, callback):
        return
    await callback.answer()
    parts = (callback.data or "").split(":")
    if parts[1] == "gs" and len(parts) >= 4:
        prefix = f"aed:gs:{parts[2]}:{parts[3]}"
    elif parts[1] == "vl" and len(parts) >= 3:
        prefix = f"aed:vl:{parts[2]}"
    else:
        return
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="30 дней", callback_data=f"{prefix}:30")],
        [InlineKeyboardButton(text="90 дней", callback_data=f"{prefix}:90")],
        [InlineKeyboardButton(text="180 дней", callback_data=f"{prefix}:180")],
    ])
    await callback.message.answer("На сколько дней продлить?", reply_markup=kb)


@router.callback_query(F.data.startswith("aed:"))
async def admin_extend_apply(callback: CallbackQuery, ctx: BotContext) -> None:
    if not _is_admin_cb(ctx, callback):
        return
    await callback.answer()
    parts = (callback.data or "").split(":")
    try:
        if parts[1] == "gs" and len(parts) >= 5:
            server_id, name, days = parts[2], parts[3], int(parts[4])
            result = await ctx.admin.extend_subscription(name, days, server_id=server_id)
            exp = _format_expires(result.get("expires_at"))
            await callback.message.answer(
                f"GS: `{name}` продлен на {days} дней.\nНовый срок: {exp}",
                parse_mode="Markdown",
            )
        elif parts[1] == "vl" and len(parts) >= 4:
            email, days = parts[2], int(parts[3])
            if ctx.xui is None:
                await callback.message.answer("VLESS не настроен.")
                return
            new_exp = await ctx.xui.extend_vless_user(email, days)
            exp = _format_expires_ms(new_exp)
            await callback.message.answer(
                f"VL: `{email}` продлен на {days} дней.\nНовый срок: {exp}",
                parse_mode="Markdown",
            )
        else:
            await callback.message.answer("Некорректные данные.")
    except (AdminApiError, XuiApiError) as exc:
        await callback.message.answer(f"Ошибка: {exc}")


@router.pre_checkout_query()
async def pre_checkout(pre_checkout_query: PreCheckoutQuery) -> None:
    # Payload validation is performed on successful_payment too.
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

        if payload.action == "buy" and payload.product == "vless":
            await _handle_buy_vless(message, ctx, repo, payload, payment)
            return

        if payload.action == "buy":
            server_id = payload.server_id or _selected_server_id(ctx, message.from_user.id)
            if not _server_exists(ctx, server_id):
                await message.answer("Оплата прошла, но сервер не найден в конфиге.")
                return
            client_name = f"tg_{message.from_user.id}_{uuid.uuid4().hex[:8]}"
            try:
                await ctx.admin.create_client(client_name, payload.days, server_id=server_id)
                client_state = await ctx.admin.get_client_by_name(client_name, server_id=server_id)
                expires_at = parse_expires_at((client_state or {}).get("expires_at"))
                await repo.upsert_client_binding(message.from_user.id, server_id, client_name)
                await repo.add_subscription_event(
                    f"{server_id}:{client_name}",
                    "created_via_payment",
                    {"days": payload.days, "charge_id": payment.telegram_payment_charge_id},
                )
                raw_conn_string = await ctx.admin.get_conn_string(client_name, server_id=server_id)
                conn_string = _sanitize_conn_string(raw_conn_string)
            except AdminApiError as exc:
                logger.exception("admin_api_error payment_buy")
                await message.answer(f"Оплата прошла, но ошибка Admin API: {exc}")
                return
            except ValueError as exc:
                logger.exception("conn_string_sanitize_error payment_buy")
                await message.answer(f"Оплата прошла, но conn_string отклонен: {exc}")
                return
            await message.answer(
                f"Подписка создана: `{client_name}`\n"
                f"Действует до: {_fmt_dt(expires_at)}",
                parse_mode="Markdown",
            )
            await message.answer(f"`{conn_string}`", parse_mode="Markdown")
            await message.answer_photo(
                BufferedInputFile(_qr_png(conn_string), filename=f"{client_name}.png"),
                caption="QR для подключения",
            )
            return

        if payload.action == "extend" and payload.product == "vless":
            await _handle_extend_vless(message, ctx, repo, payload, payment)
            return

        if payload.action == "extend":
            if not payload.server_id or not payload.client_name:
                await message.answer("Не указан server_id/client_name для продления.")
                return
            try:
                result = await ctx.admin.extend_subscription(
                    payload.client_name,
                    payload.days,
                    server_id=payload.server_id,
                )
                await repo.upsert_client_binding(message.from_user.id, payload.server_id, payload.client_name)
                await repo.add_subscription_event(
                    f"{payload.server_id}:{payload.client_name}",
                    "extended_via_payment",
                    {"days": payload.days, "charge_id": payment.telegram_payment_charge_id},
                )
            except AdminApiError as exc:
                logger.exception("admin_api_error payment_extend")
                await message.answer(f"Оплата прошла, но ошибка продления в Admin API: {exc}")
                return
            await message.answer(
                f"Подписка `{payload.client_name}` продлена на {payload.days} дней.\n"
                f"Новый срок: {_format_expires(result.get('expires_at'))}",
                parse_mode="Markdown",
            )
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
    await message.answer(
        "Используйте кнопки меню ниже.",
        reply_markup=main_menu_keyboard(is_admin=_is_admin(ctx, message.from_user.id)),
    )


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
        await message.answer(f"Некорректное имя: {error}\nПопробуйте ещё раз:")
        return True
    if ctx.xui is not None:
        existing = await ctx.xui.get_vless_user_info(name)
        if existing is not None:
            await message.answer("Это имя уже занято. Выберите другое:")
            return True
    draft["name"] = name
    draft["step"] = "plan"
    await message.answer(
        f"Имя: `{name}`\nВыберите тариф:",
        reply_markup=plan_keyboard("buy_vless_plan"),
        parse_mode="Markdown",
    )
    return True


def _format_expires(value: object) -> str:
    if isinstance(value, (int, float)):
        dt = datetime.fromtimestamp(float(value), tz=timezone.utc)
        return dt.strftime("%Y-%m-%d %H:%M UTC")
    return "∞"



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
            await message.answer("Имя пустое. Введи имя клиента.")
            return True
        if draft.get("product") == "vl":
            error = _validate_vless_name(text)
            if error:
                await message.answer(f"Некорректное имя: {error}")
                return True
        draft["name"] = text
        draft["step"] = "days"
        await message.answer("Срок? Отправь число дней (30/90/180) или 0 для бессрочно.")
        return True
    if step == "days":
        try:
            days = int(text)
        except ValueError:
            await message.answer("Нужно число дней. Пример: 30")
            return True
        name = draft.get("name", "")
        product = draft.get("product", "gs")
        server_id = draft.get("server_id") or _selected_server_id(ctx, message.from_user.id)
        ctx.admin_create_draft.pop(message.from_user.id, None)
        if product == "vl":
            if ctx.xui is None:
                await message.answer("VLESS не настроен.")
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
                await message.answer(f"Ошибка 3x-ui: {exc}")
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
        try:
            result = await ctx.admin.create_client(name, None if days == 0 else days, server_id=server_id)
            async with ctx.db.session() as session:
                repo = BotRepository(session)
                await repo.upsert_client_binding(message.from_user.id, server_id, name)
        except AdminApiError as exc:
            await message.answer(f"Ошибка Admin API: {exc}")
            return True
        conn = result.get("conn_string")
        await message.answer(
            f"GS клиент создан: `{result.get('name', name)}`\n"
            f"TUN: `{result.get('tun_addr', '-')}`",
            parse_mode="Markdown",
        )
        if conn:
            conn_string = _sanitize_conn_string(str(conn))
            await message.answer(f"`{conn_string}`", parse_mode="Markdown")
            await message.answer_photo(
                BufferedInputFile(_qr_png(conn_string), filename=f"{name}.png"),
                caption="QR для подключения",
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
    client_name = payload.client_name or f"tg_{message.from_user.id}_{uuid.uuid4().hex[:8]}"
    try:
        vless_user = await ctx.xui.create_vless_user(client_name, message.from_user.id, payload.days)
        await repo.upsert_client_binding(message.from_user.id, "vless", vless_user.email, product_type="vless")
        await repo.add_subscription_event(
            f"vless:{vless_user.email}",
            "created_via_payment",
            {"days": payload.days, "charge_id": payment.telegram_payment_charge_id},
        )
    except XuiApiError as exc:
        logger.exception("xui_api_error payment_buy_vless")
        await message.answer(f"Оплата прошла, но ошибка 3x-ui: {exc}")
        return
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


async def _append_vless_binding_info(lines: list[str], ctx: BotContext, binding: Any) -> None:
    if ctx.xui is None:
        lines.append(f"- {binding.client_name} [VLESS] | сервер не настроен")
        return
    try:
        info = await ctx.xui.get_vless_user_info(binding.client_name)
    except XuiApiError:
        info = None
    if info is None:
        lines.append(f"- {binding.client_name} [VLESS] | not found")
        return
    exp = _format_expires_ms(info.get("expiryTime", 0))
    enabled = "on" if info.get("enable") else "off"
    online = "online" if info.get("online") else "offline"
    lines.append(f"- {binding.client_name} [VLESS] | {enabled}/{online} | до: {exp}")


async def _get_vless_expiry_str(ctx: BotContext, email: str) -> str:
    if ctx.xui is None:
        return "N/A"
    try:
        info = await ctx.xui.get_vless_user_info(email)
    except XuiApiError:
        return "error"
    if info is None:
        return "not found"
    return _format_expires_ms(info.get("expiryTime", 0))


def _format_expires_ms(ms: int | None) -> str:
    """Format expiry time in milliseconds to a human-readable string."""
    if ms is None or ms == 0:
        return "∞"
    from datetime import datetime, timezone
    dt = datetime.fromtimestamp(ms / 1000, tz=timezone.utc)
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

