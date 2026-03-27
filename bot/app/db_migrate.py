from __future__ import annotations

from pathlib import Path

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

from app.config import load_settings


async def apply_sql_migration() -> None:
    settings = load_settings()
    engine = create_async_engine(settings.database_url, future=True)
    migrations_dir = Path(__file__).parent / "migrations"
    sql_files = sorted(migrations_dir.glob("*.sql"))
    async with engine.begin() as conn:
        for sql_path in sql_files:
            sql = sql_path.read_text(encoding="utf-8")
            for statement in [part.strip() for part in sql.split(";") if part.strip()]:
                try:
                    await conn.execute(text(statement))
                except Exception:
                    # Ignore errors like "duplicate column" for idempotent migrations
                    pass
    await engine.dispose()

