from __future__ import annotations

import json
import uuid
from datetime import datetime
from typing import Optional

from sqlalchemy import and_, delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import (
    ClientBinding,
    NotificationSend,
    Payment,
    Subscription,
    SubscriptionEvent,
    TgUser,
)


class BotRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def ensure_user(self, tg_user_id: int, username: Optional[str]) -> TgUser:
        result = await self.session.execute(select(TgUser).where(TgUser.tg_user_id == tg_user_id))
        user = result.scalar_one_or_none()
        if user is None:
            user = TgUser(tg_user_id=tg_user_id, username=username)
            self.session.add(user)
        else:
            user.username = username
        await self.session.commit()
        return user

    async def list_subscriptions(self, tg_user_id: int) -> list[Subscription]:
        result = await self.session.execute(
            select(Subscription)
            .where(Subscription.tg_user_id == tg_user_id)
            .order_by(Subscription.created_at.desc())
        )
        return list(result.scalars().all())

    async def get_subscription(self, tg_user_id: int, subscription_id: str) -> Optional[Subscription]:
        result = await self.session.execute(
            select(Subscription).where(
                Subscription.tg_user_id == tg_user_id,
                Subscription.id == subscription_id,
            ),
        )
        return result.scalar_one_or_none()

    async def create_subscription(
        self,
        tg_user_id: int,
        client_name: str,
        plan_days: int,
        expires_at: Optional[datetime],
    ) -> Subscription:
        subscription = Subscription(
            id=str(uuid.uuid4()),
            tg_user_id=tg_user_id,
            client_name=client_name,
            plan_days=plan_days,
            expires_at=expires_at,
            status="active",
        )
        self.session.add(subscription)
        await self.session.commit()
        return subscription

    async def update_subscription_expiry(
        self,
        subscription_id: str,
        expires_at: Optional[datetime],
        plan_days: int,
    ) -> None:
        result = await self.session.execute(select(Subscription).where(Subscription.id == subscription_id))
        subscription = result.scalar_one()
        subscription.expires_at = expires_at
        subscription.plan_days = plan_days
        await self.session.commit()

    async def mark_payment_if_new(
        self,
        telegram_charge_id: str,
        provider_charge_id: Optional[str],
        invoice_payload: str,
        amount_xtr: int,
        tg_user_id: int,
    ) -> bool:
        result = await self.session.execute(
            select(Payment).where(Payment.telegram_charge_id == telegram_charge_id),
        )
        existing = result.scalar_one_or_none()
        if existing is not None:
            return False
        payment = Payment(
            telegram_charge_id=telegram_charge_id,
            provider_charge_id=provider_charge_id,
            invoice_payload=invoice_payload,
            amount_xtr=amount_xtr,
            tg_user_id=tg_user_id,
            status="succeeded",
            currency="XTR",
        )
        self.session.add(payment)
        await self.session.commit()
        return True

    async def add_subscription_event(self, subscription_id: str, event_type: str, payload: dict) -> None:
        event = SubscriptionEvent(
            subscription_id=subscription_id,
            event_type=event_type,
            payload_json=json.dumps(payload, ensure_ascii=True),
        )
        self.session.add(event)
        await self.session.commit()

    async def upsert_client_binding(
        self,
        tg_user_id: int,
        server_id: str,
        client_name: str,
        product_type: str = "vless",
    ) -> ClientBinding:
        result = await self.session.execute(
            select(ClientBinding).where(
                and_(
                    ClientBinding.tg_user_id == tg_user_id,
                    ClientBinding.server_id == server_id,
                    ClientBinding.client_name == client_name,
                ),
            ),
        )
        binding = result.scalar_one_or_none()
        if binding is None:
            binding = ClientBinding(
                tg_user_id=tg_user_id,
                server_id=server_id,
                client_name=client_name,
                product_type=product_type,
            )
            self.session.add(binding)
            await self.session.commit()
        return binding

    async def list_client_bindings(self, tg_user_id: int) -> list[ClientBinding]:
        result = await self.session.execute(
            select(ClientBinding)
            .where(ClientBinding.tg_user_id == tg_user_id)
            .order_by(ClientBinding.created_at.desc()),
        )
        return list(result.scalars().all())

    async def list_all_client_bindings(self, product_type: Optional[str] = None) -> list[ClientBinding]:
        stmt = select(ClientBinding)
        if product_type is not None:
            stmt = stmt.where(ClientBinding.product_type == product_type)
        stmt = stmt.order_by(ClientBinding.created_at.desc())
        result = await self.session.execute(stmt)
        return list(result.scalars().all())

    async def list_payment_user_ids(self) -> set[int]:
        result = await self.session.execute(select(Payment.tg_user_id).distinct())
        return {int(tg_user_id) for tg_user_id in result.scalars().all() if tg_user_id is not None}

    async def was_notification_scope_sent(
        self,
        tg_user_id: int,
        notification_type: str,
        scope_key: str,
    ) -> bool:
        result = await self.session.execute(
            select(NotificationSend.id).where(
                NotificationSend.tg_user_id == tg_user_id,
                NotificationSend.notification_type == notification_type,
                NotificationSend.scope_key == scope_key,
            ),
        )
        return result.scalar_one_or_none() is not None

    async def was_notification_type_sent_since(
        self,
        tg_user_id: int,
        notification_type: str,
        since: datetime,
    ) -> bool:
        result = await self.session.execute(
            select(NotificationSend.id).where(
                NotificationSend.tg_user_id == tg_user_id,
                NotificationSend.notification_type == notification_type,
                NotificationSend.sent_at >= since,
            ),
        )
        return result.scalar_one_or_none() is not None

    async def record_notification_send(
        self,
        tg_user_id: int,
        notification_type: str,
        scope_key: str,
        client_name: Optional[str] = None,
    ) -> None:
        self.session.add(
            NotificationSend(
                tg_user_id=tg_user_id,
                notification_type=notification_type,
                scope_key=scope_key,
                client_name=client_name,
            ),
        )
        await self.session.commit()

    async def delete_client_binding_by_id(self, binding_id: int) -> None:
        await self.session.execute(delete(ClientBinding).where(ClientBinding.id == binding_id))
        await self.session.commit()

    async def backfill_bindings_from_legacy(self, default_server_id: str) -> int:
        result = await self.session.execute(select(Subscription))
        legacy_subs = list(result.scalars().all())
        created = 0
        for sub in legacy_subs:
            existing = await self.session.execute(
                select(ClientBinding).where(
                    and_(
                        ClientBinding.tg_user_id == sub.tg_user_id,
                        ClientBinding.server_id == default_server_id,
                        ClientBinding.client_name == sub.client_name,
                    ),
                ),
            )
            if existing.scalar_one_or_none() is not None:
                continue
            self.session.add(
                ClientBinding(
                    tg_user_id=sub.tg_user_id,
                    server_id=default_server_id,
                    client_name=sub.client_name,
                ),
            )
            created += 1
        if created > 0:
            await self.session.commit()
        return created
