from __future__ import annotations

from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup, KeyboardButton, ReplyKeyboardMarkup


def main_menu_keyboard(*, is_admin: bool) -> ReplyKeyboardMarkup:
    rows = [
        [KeyboardButton(text="Мои подписки"), KeyboardButton(text="Купить подписку")],
        [KeyboardButton(text="Продлить подписку"), KeyboardButton(text="Подключение")],
        [KeyboardButton(text="Поддержка")],
    ]
    if is_admin:
        rows.append([KeyboardButton(text="Админка")])
    return ReplyKeyboardMarkup(
        keyboard=rows,
        resize_keyboard=True,
    )


def product_keyboard(prefix: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [InlineKeyboardButton(text="GhostStream VPN", callback_data=f"{prefix}:ghoststream")],
            [InlineKeyboardButton(text="VLESS (iOS / любой клиент)", callback_data=f"{prefix}:vless")],
        ],
    )


def plan_keyboard(prefix: str) -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton(text="30 дней", callback_data=f"{prefix}:30")],
        [InlineKeyboardButton(text="90 дней", callback_data=f"{prefix}:90")],
        [InlineKeyboardButton(text="180 дней", callback_data=f"{prefix}:180")],
    ]
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


def bindings_keyboard(bindings: list[tuple[str, str, str]], prefix: str) -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton(text=label, callback_data=f"{prefix}:{server_id}:{client_name}")]
        for server_id, client_name, label in bindings
    ]
    return InlineKeyboardMarkup(inline_keyboard=rows)


def admin_home_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[
            [InlineKeyboardButton(text="Список клиентов", callback_data="adm:list")],
            [InlineKeyboardButton(text="Создать клиента", callback_data="adm:create:start")],
            [InlineKeyboardButton(text="Продлить клиента", callback_data="adm:extend:start")],
        ],
    )
