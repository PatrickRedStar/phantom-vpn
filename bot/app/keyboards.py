from __future__ import annotations

from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup


def main_menu_keyboard(*, is_admin: bool) -> InlineKeyboardMarkup:
    rows = [[
        InlineKeyboardButton(text="🛒 Купить подписку", callback_data="main:buy"),
        InlineKeyboardButton(text="📁 Мои подписки", callback_data="main:subs"),
    ]]
    second_row = [InlineKeyboardButton(text="ℹ️ Помощь", callback_data="main:help")]
    if is_admin:
        second_row.append(InlineKeyboardButton(text="🔐 Админ-меню", callback_data="main:admin"))
    rows.append(second_row)
    return InlineKeyboardMarkup(inline_keyboard=rows)


def back_keyboard(callback_data: str, text: str = "⬅️ Назад") -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[[InlineKeyboardButton(text=text, callback_data=callback_data)]],
    )


def product_keyboard(prefix: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [InlineKeyboardButton(text="VLESS (iOS / любой клиент)", callback_data=f"{prefix}:vless")],
        ],
    )


def plan_keyboard(
    prefix: str,
    back_callback: str | None = None,
    back_text: str = "⬅️ Назад",
) -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton(text="🗓️ 30 дней", callback_data=f"{prefix}:30")],
        [InlineKeyboardButton(text="📅 90 дней", callback_data=f"{prefix}:90")],
        [InlineKeyboardButton(text="🧭 180 дней", callback_data=f"{prefix}:180")],
    ]
    if back_callback:
        rows.append([InlineKeyboardButton(text=back_text, callback_data=back_callback)])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def subscriptions_keyboard(subscriptions: list[tuple[str, str]], prefix: str) -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton(text=label, callback_data=f"{prefix}:{sub_id}")]
        for sub_id, label in subscriptions
    ]
    return InlineKeyboardMarkup(inline_keyboard=rows)


def server_select_keyboard(servers: list[tuple[str, str]], prefix: str) -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton(text=name, callback_data=f"{prefix}:{server_id}")]
        for server_id, name in servers
    ]
    return InlineKeyboardMarkup(inline_keyboard=rows)


def bindings_keyboard(
    bindings: list[tuple[str, str, str]],
    prefix: str,
    back_callback: str | None = None,
    back_text: str = "⬅️ Назад",
) -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton(text=label, callback_data=f"{prefix}:{server_id}:{client_name}")]
        for server_id, client_name, label in bindings
    ]
    if back_callback:
        rows.append([InlineKeyboardButton(text=back_text, callback_data=back_callback)])
    return InlineKeyboardMarkup(inline_keyboard=rows)


def admin_home_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [InlineKeyboardButton(text="Список клиентов", callback_data="adm:list")],
            [InlineKeyboardButton(text="Создать клиента", callback_data="adm:create:start")],
            [InlineKeyboardButton(text="Продлить клиента", callback_data="adm:extend:start")],
            [InlineKeyboardButton(text="⬅️ Назад", callback_data="main:home")],
        ],
    )
