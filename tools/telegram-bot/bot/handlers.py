"""Telegram handlers: main menu, client CRUD, subscription, QR."""
from __future__ import annotations

import html
import logging
import time
from typing import Optional

from telegram import (
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    InputFile,
    Update,
)
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    ConversationHandler,
    MessageHandler,
    filters,
)

from .api import PhantomAPI, PhantomApiError
from .auth import admin_only
from .config import CONFIG
from .conn_string import strip_admin
from .qr import generate_qr
from .roles import RoleStore

log = logging.getLogger(__name__)

# ConversationHandler states
ADD_ROLE, ADD_NAME, ADD_EXPIRES = range(3)

# Globals wired by main.py
_api: Optional[PhantomAPI] = None
_roles: Optional[RoleStore] = None


def init(api: PhantomAPI, roles: RoleStore) -> None:
    global _api, _roles
    _api = api
    _roles = roles


# ─── Formatting helpers ────────────────────────────────────────────────────

def _fmt_bytes(n: int) -> str:
    if n < 1024:
        return f"{n} B"
    if n < 1024 * 1024:
        return f"{n / 1024:.1f} KB"
    if n < 1024 * 1024 * 1024:
        return f"{n / (1024 * 1024):.1f} MB"
    return f"{n / (1024 * 1024 * 1024):.2f} GB"


def _fmt_last_seen(secs: Optional[int]) -> str:
    if secs is None:
        return "never"
    if secs < 60:
        return f"{secs}s ago"
    if secs < 3600:
        return f"{secs // 60}m ago"
    if secs < 86400:
        return f"{secs // 3600}h ago"
    return f"{secs // 86400}d ago"


def _days_left(expires_at: Optional[int]) -> str:
    if expires_at is None:
        return "∞"
    now = int(time.time())
    d = (expires_at - now) // 86400
    if d < 0:
        return "истёк"
    return f"{d}д"


def _client_card(c: dict, role: str) -> str:
    name = html.escape(c["name"])
    role_tag = "👤 admin" if role == "admin" else "🙂 regular"
    connected = "🟢 подключён" if c.get("connected") else "⚪ offline"
    last_seen = _fmt_last_seen(c.get("last_seen_secs"))
    enabled = "✅ enabled" if c.get("enabled") else "❌ disabled"
    tun = html.escape(str(c.get("tun_addr", "-")))
    rx = _fmt_bytes(int(c.get("bytes_rx") or 0))
    tx = _fmt_bytes(int(c.get("bytes_tx") or 0))
    sub = _days_left(c.get("expires_at"))
    return (
        f"<b>Клиент:</b> {name}  [{role_tag}]\n"
        f"<b>Статус:</b> {connected} · {enabled}\n"
        f"<b>TUN:</b> <code>{tun}</code>\n"
        f"<b>Трафик:</b> ↓ {rx} / ↑ {tx}\n"
        f"<b>Last seen:</b> {last_seen}\n"
        f"<b>Подписка:</b> {sub}"
    )


# ─── Keyboards ─────────────────────────────────────────────────────────────

def _kb_main() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("👥 Клиенты", callback_data="list")],
        [InlineKeyboardButton("➕ Добавить", callback_data="add")],
    ])


def _kb_client_list(clients: list[dict]) -> InlineKeyboardMarkup:
    rows = []
    for c in sorted(clients, key=lambda x: x["name"]):
        mark = "✅" if c.get("enabled") else "❌"
        conn = "🟢" if c.get("connected") else ""
        dleft = _days_left(c.get("expires_at"))
        label = f"{mark}{conn} {c['name']} ({dleft})"
        rows.append([InlineKeyboardButton(label, callback_data=f"c:{c['name']}")])
    rows.append([InlineKeyboardButton("⬅ В меню", callback_data="main")])
    return InlineKeyboardMarkup(rows)


def _kb_client_detail(c: dict) -> InlineKeyboardMarkup:
    name = c["name"]
    toggle_label = "⏸ Disable" if c.get("enabled") else "▶ Enable"
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("📱 QR", callback_data=f"qr:{name}"),
            InlineKeyboardButton("🔗 Строка", callback_data=f"conn:{name}"),
        ],
        [
            InlineKeyboardButton(toggle_label, callback_data=f"tog:{name}"),
            InlineKeyboardButton("⏰ Подписка", callback_data=f"sub:{name}"),
        ],
        [InlineKeyboardButton("🗑 Удалить", callback_data=f"del:{name}")],
        [InlineKeyboardButton("⬅ Список", callback_data="list")],
    ])


def _kb_sub_menu(name: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("+7д", callback_data=f"sa:{name}:extend:7"),
            InlineKeyboardButton("+30д", callback_data=f"sa:{name}:extend:30"),
            InlineKeyboardButton("+90д", callback_data=f"sa:{name}:extend:90"),
        ],
        [
            InlineKeyboardButton("=30д", callback_data=f"sa:{name}:set:30"),
            InlineKeyboardButton("=90д", callback_data=f"sa:{name}:set:90"),
            InlineKeyboardButton("=365д", callback_data=f"sa:{name}:set:365"),
        ],
        [
            InlineKeyboardButton("∞ Бессрочно", callback_data=f"sa:{name}:cancel:0"),
            InlineKeyboardButton("🚫 Отозвать", callback_data=f"sa:{name}:revoke:0"),
        ],
        [InlineKeyboardButton("⬅ Назад", callback_data=f"c:{name}")],
    ])


def _kb_delete_confirm(name: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("🗑 Удалить", callback_data=f"delok:{name}"),
            InlineKeyboardButton("❌ Отмена", callback_data=f"c:{name}"),
        ],
    ])


# ─── Handler: /start & main menu ──────────────────────────────────────────

@admin_only
async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    await update.effective_chat.send_message(
        "phantom-vpn admin bot. Выбери действие:",
        reply_markup=_kb_main(),
    )


async def _show_main(update: Update) -> None:
    q = update.callback_query
    if q is not None:
        await q.edit_message_text("Главное меню:", reply_markup=_kb_main())
    else:
        await update.effective_chat.send_message("Главное меню:", reply_markup=_kb_main())


# ─── Client list / detail ─────────────────────────────────────────────────

async def _show_list(update: Update) -> None:
    q = update.callback_query
    try:
        clients = await _api.list_clients()
    except PhantomApiError as e:
        await q.edit_message_text(f"❌ API error: {e}", reply_markup=_kb_main())
        return
    if not clients:
        await q.edit_message_text("Клиентов пока нет.", reply_markup=_kb_main())
        return
    await q.edit_message_text(
        f"Клиенты ({len(clients)}):",
        reply_markup=_kb_client_list(clients),
    )


async def _show_client(update: Update, name: str) -> None:
    q = update.callback_query
    try:
        clients = await _api.list_clients()
    except PhantomApiError as e:
        await q.edit_message_text(f"❌ API error: {e}", reply_markup=_kb_main())
        return
    c = next((x for x in clients if x["name"] == name), None)
    if c is None:
        await q.edit_message_text(f"Клиент {name!r} не найден.", reply_markup=_kb_main())
        return
    role = _roles.get(name)
    await q.edit_message_text(
        _client_card(c, role),
        reply_markup=_kb_client_detail(c),
        parse_mode=ParseMode.HTML,
    )


# ─── Conn string / QR ─────────────────────────────────────────────────────

async def _prepare_conn_string(name: str) -> str:
    """Fetch + strip if regular role."""
    raw = await _api.conn_string(name)
    role = _roles.get(name)
    if role == "regular":
        return strip_admin(raw)
    return raw


async def _send_qr(update: Update, ctx: ContextTypes.DEFAULT_TYPE, name: str) -> None:
    q = update.callback_query
    try:
        s = await _prepare_conn_string(name)
    except PhantomApiError as e:
        await q.message.reply_text(f"❌ API error: {e}")
        return
    role = _roles.get(name)
    tag = "admin" if role == "admin" else "regular"
    img = generate_qr(s)
    await q.message.reply_photo(
        photo=InputFile(img, filename=f"{name}.png"),
        caption=f"QR · {name} [{tag}]",
    )


async def _send_conn(update: Update, ctx: ContextTypes.DEFAULT_TYPE, name: str) -> None:
    q = update.callback_query
    try:
        s = await _prepare_conn_string(name)
    except PhantomApiError as e:
        await q.message.reply_text(f"❌ API error: {e}")
        return
    role = _roles.get(name)
    tag = "admin" if role == "admin" else "regular"
    await q.message.reply_text(
        f"<b>{html.escape(name)}</b> [{tag}]\n<code>{html.escape(s)}</code>",
        parse_mode=ParseMode.HTML,
    )


# ─── Enable/Disable / Delete / Subscription ──────────────────────────────

async def _toggle(update: Update, name: str) -> None:
    q = update.callback_query
    try:
        clients = await _api.list_clients()
        c = next((x for x in clients if x["name"] == name), None)
        if c is None:
            await q.message.reply_text(f"Клиент {name!r} не найден.")
            return
        if c.get("enabled"):
            await _api.disable_client(name)
        else:
            await _api.enable_client(name)
    except PhantomApiError as e:
        await q.message.reply_text(f"❌ API error: {e}")
        return
    await _show_client(update, name)


async def _sub_menu(update: Update, name: str) -> None:
    q = update.callback_query
    await q.edit_message_text(
        f"Подписка для <b>{html.escape(name)}</b>:",
        reply_markup=_kb_sub_menu(name),
        parse_mode=ParseMode.HTML,
    )


async def _sub_action(update: Update, name: str, action: str, days: int) -> None:
    q = update.callback_query
    try:
        if action in ("extend", "set"):
            await _api.subscription(name, action, days)
        else:
            await _api.subscription(name, action)
    except PhantomApiError as e:
        await q.message.reply_text(f"❌ API error: {e}")
        return
    await _show_client(update, name)


async def _del_confirm(update: Update, name: str) -> None:
    q = update.callback_query
    await q.edit_message_text(
        f"Точно удалить <b>{html.escape(name)}</b>?",
        reply_markup=_kb_delete_confirm(name),
        parse_mode=ParseMode.HTML,
    )


async def _del_exec(update: Update, name: str) -> None:
    q = update.callback_query
    try:
        await _api.delete_client(name)
    except PhantomApiError as e:
        await q.message.reply_text(f"❌ API error: {e}")
        return
    _roles.delete(name)
    await _show_list(update)


# ─── Root callback dispatcher ─────────────────────────────────────────────

@admin_only
async def on_callback(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    q = update.callback_query
    data = q.data or ""
    await q.answer()

    try:
        if data == "main":
            await _show_main(update)
        elif data == "list":
            await _show_list(update)
        elif data.startswith("c:"):
            await _show_client(update, data[2:])
        elif data.startswith("qr:"):
            await _send_qr(update, ctx, data[3:])
        elif data.startswith("conn:"):
            await _send_conn(update, ctx, data[5:])
        elif data.startswith("tog:"):
            await _toggle(update, data[4:])
        elif data.startswith("sub:"):
            await _sub_menu(update, data[4:])
        elif data.startswith("sa:"):
            _, name, action, days_s = data.split(":", 3)
            await _sub_action(update, name, action, int(days_s))
        elif data.startswith("del:"):
            await _del_confirm(update, data[4:])
        elif data.startswith("delok:"):
            await _del_exec(update, data[6:])
        else:
            log.warning("unhandled callback data=%s", data)
    except Exception:
        log.exception("callback handler crashed")
        try:
            await q.message.reply_text("❌ Внутренняя ошибка")
        except Exception:
            pass


# ─── Add-client ConversationHandler ───────────────────────────────────────

@admin_only
async def add_entry(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> int:
    q = update.callback_query
    await q.answer()
    kb = InlineKeyboardMarkup([
        [
            InlineKeyboardButton("👤 Admin", callback_data="arole:admin"),
            InlineKeyboardButton("🙂 Regular", callback_data="arole:regular"),
        ],
        [InlineKeyboardButton("❌ Отмена", callback_data="acancel")],
    ])
    await q.edit_message_text("Роль нового клиента?", reply_markup=kb)
    return ADD_ROLE


async def add_role(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> int:
    q = update.callback_query
    await q.answer()
    role = q.data.split(":", 1)[1]
    ctx.user_data["add_role"] = role
    await q.edit_message_text(
        f"Роль: <b>{role}</b>\n\nВведи имя клиента (a-z, 0-9, _, -, 1..32 символа):",
        parse_mode=ParseMode.HTML,
    )
    return ADD_NAME


async def add_name(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> int:
    name = (update.message.text or "").strip()
    import re

    if not re.fullmatch(r"[a-zA-Z0-9_\-]{1,32}", name):
        await update.message.reply_text("Плохое имя. Попробуй ещё раз:")
        return ADD_NAME
    ctx.user_data["add_name"] = name
    kb = InlineKeyboardMarkup([
        [
            InlineKeyboardButton("7д", callback_data="aexp:7"),
            InlineKeyboardButton("30д", callback_data="aexp:30"),
            InlineKeyboardButton("90д", callback_data="aexp:90"),
            InlineKeyboardButton("365д", callback_data="aexp:365"),
        ],
        [InlineKeyboardButton("∞ Бессрочно", callback_data="aexp:-1")],
        [InlineKeyboardButton("❌ Отмена", callback_data="acancel")],
    ])
    await update.message.reply_text(
        f"Имя: <b>{html.escape(name)}</b>\nСрок подписки?",
        reply_markup=kb,
        parse_mode=ParseMode.HTML,
    )
    return ADD_EXPIRES


async def add_expires(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> int:
    q = update.callback_query
    await q.answer()
    days_s = q.data.split(":", 1)[1]
    days = int(days_s)
    name = ctx.user_data.get("add_name", "")
    role = ctx.user_data.get("add_role", "regular")

    await q.edit_message_text(f"Создаю <b>{html.escape(name)}</b>…", parse_mode=ParseMode.HTML)

    try:
        await _api.create_client(
            name,
            expires_days=(None if days < 0 else days),
        )
    except PhantomApiError as e:
        await q.message.reply_text(f"❌ API error: {e}")
        return ConversationHandler.END

    _roles.set(name, "admin" if role == "admin" else "regular")

    # Fetch conn_string + strip for regular
    try:
        raw = await _api.conn_string(name)
    except PhantomApiError as e:
        await q.message.reply_text(f"Клиент создан, но conn_string не получить: {e}")
        return ConversationHandler.END

    conn = strip_admin(raw) if role == "regular" else raw

    await q.message.reply_text(
        f"✅ Создан <b>{html.escape(name)}</b> [{role}]\n"
        f"Срок: {'∞' if days < 0 else str(days) + 'д'}",
        parse_mode=ParseMode.HTML,
    )
    img = generate_qr(conn)
    await q.message.reply_photo(
        photo=InputFile(img, filename=f"{name}.png"),
        caption=f"QR · {name} [{role}]",
    )
    await q.message.reply_text(
        f"<code>{html.escape(conn)}</code>",
        parse_mode=ParseMode.HTML,
    )
    # Back to main menu
    await q.message.reply_text("Меню:", reply_markup=_kb_main())
    ctx.user_data.pop("add_name", None)
    ctx.user_data.pop("add_role", None)
    return ConversationHandler.END


async def add_cancel(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> int:
    q = update.callback_query
    if q is not None:
        await q.answer()
        await q.edit_message_text("Отменено.", reply_markup=_kb_main())
    else:
        await update.message.reply_text("Отменено.", reply_markup=_kb_main())
    ctx.user_data.pop("add_name", None)
    ctx.user_data.pop("add_role", None)
    return ConversationHandler.END


async def _add_fallback_cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> int:
    """Catch-all fallback: any unrecognised callback while inside the add-client
    conversation ends the conversation and lets the main dispatcher handle it."""
    ctx.user_data.pop("add_name", None)
    ctx.user_data.pop("add_role", None)
    return ConversationHandler.END


def add_conversation() -> ConversationHandler:
    admin_filter = filters.User(user_id=CONFIG.admin_telegram_id)
    return ConversationHandler(
        entry_points=[CallbackQueryHandler(add_entry, pattern=r"^add$")],
        states={
            ADD_ROLE: [
                CallbackQueryHandler(add_role, pattern=r"^arole:(admin|regular)$"),
                CallbackQueryHandler(add_cancel, pattern=r"^acancel$"),
            ],
            ADD_NAME: [
                MessageHandler(filters.TEXT & ~filters.COMMAND & admin_filter, add_name),
                CallbackQueryHandler(add_cancel, pattern=r"^acancel$"),
            ],
            ADD_EXPIRES: [
                CallbackQueryHandler(add_expires, pattern=r"^aexp:(-?\d+)$"),
                CallbackQueryHandler(add_cancel, pattern=r"^acancel$"),
            ],
        },
        fallbacks=[
            CallbackQueryHandler(add_cancel, pattern=r"^acancel$"),
            CommandHandler("cancel", add_cancel),
            # Catch-all: end conversation on any other callback so it doesn't
            # get stuck and block future "add" attempts.
            CallbackQueryHandler(_add_fallback_cb),
        ],
        per_message=False,
        allow_reentry=True,
    )


# ─── Application wiring ───────────────────────────────────────────────────

def register(app: Application) -> None:
    admin_filter = filters.User(user_id=CONFIG.admin_telegram_id)
    app.add_handler(CommandHandler("start", cmd_start, filters=admin_filter))
    # ConversationHandler must be registered BEFORE the general CallbackQueryHandler
    # so its `add` entry point wins over the catch-all dispatcher.
    app.add_handler(add_conversation())
    app.add_handler(CallbackQueryHandler(on_callback))
