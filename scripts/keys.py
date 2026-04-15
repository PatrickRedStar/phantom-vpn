#!/usr/bin/env python3
"""PhantomVPN client certificate manager — mTLS (TLS client certs signed by CA).

Usage (on the server):
  python3 /opt/phantom-vpn/keys.py
  python3 /opt/phantom-vpn/keys.py --server-config /opt/phantom-vpn/config/server.toml \
      --keyring /opt/phantom-vpn/config/clients.json \
      --server-ip 89.110.109.128 \
      --server-name nl2.bikini-bottom.com
"""
import argparse
import base64
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None


# ─── TOML helpers ────────────────────────────────────────────────────────────

def _parse_toml_minimal(content):
    """Минимальный парсер TOML без зависимостей (fallback для Python < 3.11)."""
    result = {}
    section = ""
    for raw in content.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]") and not line.startswith("[["):
            section = line[1:-1].strip()
            if section not in result:
                result[section] = {}
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.split("#", 1)[0].strip()
        # strip quotes
        if (v.startswith('"') and v.endswith('"')) or \
           (v.startswith("'") and v.endswith("'")):
            v = v[1:-1]
        elif v.lower() == "true":
            v = True
        elif v.lower() == "false":
            v = False
        if section:
            result.setdefault(section, {})[k] = v
        else:
            result[k] = v
    return result


def load_toml(path):
    content = Path(path).read_text(encoding="utf-8")
    if tomllib is not None:
        return tomllib.loads(content)
    return _parse_toml_minimal(content)


# ─── Server config reader ────────────────────────────────────────────────────

def load_admin_values(server_toml_path):
    """Читает [admin] секцию из server.toml. Возвращает (admin_addr, admin_token) или (None, None)."""
    try:
        data = load_toml(server_toml_path)
    except Exception:
        return None, None
    admin = data.get("admin", {})
    if not isinstance(admin, dict):
        return None, None
    addr  = admin.get("listen_addr") or None
    token = admin.get("token") or None
    return addr, token


def _split_host_port(addr: str, default_port: str):
    """Split host:port safely for IPv4/IPv6, returning (host, port)."""
    value = (addr or "").strip()
    if not value:
        return "", default_port

    # Bracketed IPv6: [::1]:443
    if value.startswith("["):
        end = value.find("]")
        if end != -1:
            host = value[1:end]
            rest = value[end + 1 :]
            if rest.startswith(":") and rest[1:].isdigit():
                return host, rest[1:]
            return host, default_port

    # Single ':' => host:port (IPv4/hostname)
    if value.count(":") == 1:
        host, port = value.rsplit(":", 1)
        if port.isdigit():
            return host, port
        return host, default_port

    # Raw IPv6 without brackets or host without port
    return value, default_port


def load_server_values(server_toml_path, server_ip_override=None, server_name_override=None):
    """Возвращает:
    (server_ip, quic_port, h2_port, connect_host, server_name, ca_cert_path, ca_key_path).
    """
    data = load_toml(server_toml_path)

    network = data.get("network", {}) if isinstance(data.get("network"), dict) else {}
    quic    = data.get("quic",    {}) if isinstance(data.get("quic"),    dict) else {}
    h2      = data.get("h2",      {}) if isinstance(data.get("h2"),      dict) else {}

    listen_addr = network.get("listen_addr", "0.0.0.0:443")
    raw_ip, quic_port = _split_host_port(listen_addr, "443")

    h2_listen_addr = h2.get("listen_addr", "0.0.0.0:9443")
    _h2_host, h2_port = _split_host_port(h2_listen_addr, "9443")

    # Resolve server IP
    if server_ip_override:
        server_ip = server_ip_override
    elif raw_ip in ("0.0.0.0", "[::]", "::"):
        print(f"[!] listen_addr = {raw_ip!r} — нужен реальный публичный IP")
        server_ip = input("Введите публичный IP сервера: ").strip()
        if not server_ip:
            raise RuntimeError("IP сервера не задан")
    else:
        server_ip = raw_ip

    # Resolve server name (SNI)
    if server_name_override:
        server_name = server_name_override
    else:
        cert_path = quic.get("cert_path", "")
        # Try to extract domain from LE cert path like
        # /etc/letsencrypt/live/nl2.bikini-bottom.com/fullchain.pem
        m = re.search(r"/live/([^/]+)/", cert_path)
        if m:
            server_name = m.group(1)
        else:
            server_name = input("Введите SNI сервера (e.g. nl2.bikini-bottom.com): ").strip()
            if not server_name:
                server_name = server_ip

    # Host used in generated client config / connection string:
    # prefer explicit public_addr host, fallback to resolved public IP.
    public_addr = network.get("public_addr")
    if isinstance(public_addr, str) and public_addr.strip():
        connect_host, _public_port = _split_host_port(public_addr, quic_port)
        if not connect_host:
            connect_host = server_ip
    else:
        connect_host = server_ip

    # CA cert/key paths
    ca_cert_path = quic.get("ca_cert_path", "")
    if not ca_cert_path:
        raise RuntimeError(
            "server.toml не содержит [quic].ca_cert_path\n"
            "Убедитесь что сервер использует mTLS и задан путь к CA сертификату.\n"
            "Если вы только что мигрировали с Noise IK — запустите phantom-keygen\n"
            "для генерации CA и клиентских сертификатов."
        )

    ca_cert_path = Path(ca_cert_path)
    ca_key_path  = ca_cert_path.with_suffix(".key")

    if not ca_cert_path.exists():
        raise RuntimeError(f"CA cert не найден: {ca_cert_path}")
    if not ca_key_path.exists():
        raise RuntimeError(
            f"CA key не найден: {ca_key_path}\n"
            f"Ожидается рядом с сертификатом CA: {ca_cert_path.parent}/"
        )

    return (
        server_ip,
        quic_port,
        h2_port,
        connect_host,
        server_name,
        str(ca_cert_path),
        str(ca_key_path),
    )


# ─── Keyring ──────────────────────────────────────────────────────────────────

def load_keyring(path):
    p = Path(path)
    if not p.exists():
        return {"clients": {}}
    data = json.loads(p.read_text(encoding="utf-8"))
    if "clients" not in data or not isinstance(data["clients"], dict):
        raise RuntimeError(f"Некорректный формат keyring в {path}: отсутствует 'clients'")
    return data


def save_keyring(path, keyring):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(keyring, indent=2, sort_keys=True) + "\n", encoding="utf-8")


# ─── TUN address allocation ───────────────────────────────────────────────────

def next_tun_addr(clients):
    used = set()
    for item in clients.values():
        ip = item.get("tun_addr", "").split("/", 1)[0]
        octets = ip.split(".")
        if len(octets) == 4 and octets[0] == "10" and octets[1] == "7" and octets[2] == "0":
            try:
                used.add(int(octets[3]))
            except ValueError:
                pass
    # .1 = server, .2+ = clients (skip .1 and .255)
    for host in range(2, 255):
        if host not in used:
            return f"10.7.0.{host}/24"
    raise RuntimeError("Нет свободных адресов в 10.7.0.0/24")


# ─── Certificate generation ───────────────────────────────────────────────────

def _run(cmd, **kwargs):
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise RuntimeError(
            f"Команда завершилась с ошибкой: {' '.join(cmd)}\n"
            f"stderr: {result.stderr.strip()}"
        )
    return result.stdout


def generate_client_cert(name, ca_cert_path, ca_key_path, out_dir):
    """Генерирует EC клиентский сертификат, подписанный CA.

    Создаёт файлы:
      out_dir/client.crt   — PEM сертификат
      out_dir/client.key   — PEM приватный ключ

    Возвращает fingerprint сертификата (SHA-256).
    """
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    key_path  = out_dir / "client.key"
    cert_path = out_dir / "client.crt"
    csr_path  = out_dir / "client.csr"

    # 1. Генерация EC ключа (P-256)
    _run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout",
          "-out", str(key_path)])

    # 2. CSR
    subj = f"/CN={name}/O=PhantomVPN"
    _run(["openssl", "req", "-new", "-key", str(key_path),
          "-subj", subj, "-out", str(csr_path)])

    # 3. Подписываем CA (v3 с расширениями — rustls/webpki требует basicConstraints)
    ext_content = (
        "[v3_client]\n"
        "basicConstraints = CA:FALSE\n"
        "keyUsage = critical, digitalSignature\n"
        "extendedKeyUsage = clientAuth\n"
    )
    ext_file = out_dir / "client.ext"
    ext_file.write_text(ext_content)
    try:
        _run(["openssl", "x509", "-req",
              "-in",       str(csr_path),
              "-CA",       str(ca_cert_path),
              "-CAkey",    str(ca_key_path),
              "-CAcreateserial",
              "-days",     "3650",
              "-sha256",
              "-extfile",  str(ext_file),
              "-extensions", "v3_client",
              "-out",      str(cert_path)])
    finally:
        ext_file.unlink(missing_ok=True)

    # Удаляем CSR
    csr_path.unlink(missing_ok=True)

    # Fingerprint для хранения в keyring
    fp_out = _run(["openssl", "x509", "-fingerprint", "-sha256", "-noout",
                   "-in", str(cert_path)])
    fingerprint = fp_out.strip().split("=", 1)[-1].replace(":", "").lower()

    # Установить строгие права
    key_path.chmod(0o600)
    cert_path.chmod(0o644)

    return str(cert_path), str(key_path), fingerprint


# ─── Client config renderer ───────────────────────────────────────────────────

def render_client_toml(server_host, server_port, server_name, tun_addr,
                       cert_path, key_path, transport="h2"):
    return f"""[network]
server_addr = "{server_host}:{server_port}"
server_name = "{server_name}"
insecure    = false
tun_addr    = "{tun_addr}"
tun_mtu     = 1350
default_gw  = "10.7.0.1"

[tls]
cert_path = "{cert_path}"
key_path  = "{key_path}"
"""


def print_android_instructions(name, local_cert, local_key):
    android_dir = "/sdcard/Android/data/com.ghoststream.vpn/files"
    print("\nДля Android (через adb):")
    print(f"  adb push {local_cert} {android_dir}/client.crt")
    print(f"  adb push {local_key}  {android_dir}/client.key")
    print(f"\nВ приложении GhostStream укажите пути:")
    print(f"  Cert: {android_dir}/client.crt")
    print(f"  Key:  {android_dir}/client.key")


# ─── Menu actions ─────────────────────────────────────────────────────────────

def list_clients(clients):
    if not clients:
        print("Клиентов нет.")
        return
    print(f"{'#':<4} {'Имя':<20} {'TUN адрес':<16} {'Создан':<22} Fingerprint")
    print("─" * 90)
    for idx, name in enumerate(sorted(clients.keys()), start=1):
        item = clients[name]
        fp = item.get("fingerprint", "?")
        fp_short = f"{fp[:8]}…{fp[-8:]}" if len(fp) > 16 else fp
        print(
            f"{idx:<4} {name:<20} {item.get('tun_addr', '?'):<16} "
            f"{item.get('created_at', '-'):<22} {fp_short}"
        )


def add_client(keyring, server_ip, quic_port, h2_port, connect_host, server_name,
               ca_cert_path, ca_key_path, keyring_path):
    clients = keyring["clients"]
    name = input("Имя клиента (латиница, без пробелов): ").strip()
    if not name:
        print("Имя не может быть пустым.")
        return
    if not re.match(r"^[A-Za-z0-9_\-]+$", name):
        print("Имя должно содержать только латинские буквы, цифры, _ и -")
        return
    if name in clients:
        print(f"Клиент '{name}' уже существует. Удалите сначала старый.")
        return

    tun_addr = next_tun_addr(clients)
    out_dir  = Path(ca_cert_path).parent / "clients" / name

    print(f"Генерирую сертификат для {name!r} ({tun_addr})…")
    cert_path, key_path, fingerprint = generate_client_cert(
        name, ca_cert_path, ca_key_path, out_dir
    )
    print(f"Сертификат: {cert_path}")

    clients[name] = {
        "tun_addr":    tun_addr,
        "cert_path":   cert_path,
        "key_path":    key_path,
        "fingerprint": fingerprint,
        "created_at":  datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    }
    save_keyring(keyring_path, keyring)

    # Config for Linux/macOS (H2/TLS — единственный транспорт)
    linux_toml_h2 = render_client_toml(
        connect_host, h2_port, server_name, tun_addr,
        "/etc/phantom-vpn/client.crt",
        "/etc/phantom-vpn/client.key",
        transport="h2",
    )
    print(f"\nКонфиг Linux/macOS (/etc/phantom-vpn/client.toml) — HTTP/2:\n")
    print("─" * 60)
    print(linux_toml_h2)
    print("─" * 60)
    print(f"\nСкопировать сертификаты:")
    print(f"  scp root@{server_ip}:{cert_path} /etc/phantom-vpn/client.crt")
    print(f"  scp root@{server_ip}:{key_path}  /etc/phantom-vpn/client.key")

    print_android_instructions(name, cert_path, key_path)


def show_client(keyring, server_ip, quic_port, h2_port, connect_host, server_name):
    clients = keyring["clients"]
    names   = sorted(clients.keys())
    if not names:
        print("Клиентов нет.")
        return

    print("Выберите клиента:")
    for i, n in enumerate(names, 1):
        item = clients[n]
        print(f"  {i}) {n}  (tun={item.get('tun_addr', '?')})")
    raw = input("> ").strip()
    try:
        idx = int(raw) - 1
    except ValueError:
        print("Неверный ввод.")
        return
    if idx < 0 or idx >= len(names):
        print("Неверный выбор.")
        return

    name = names[idx]
    item = clients[name]

    linux_toml_h2 = render_client_toml(
        connect_host, h2_port, server_name,
        item["tun_addr"],
        "/etc/phantom-vpn/client.crt",
        "/etc/phantom-vpn/client.key",
        transport="h2",
    )
    print(f"\nКонфиг {name!r} (Linux/macOS) — HTTP/2:\n")
    print("─" * 60)
    print(linux_toml_h2)
    print("─" * 60)
    print(f"\nСкопировать сертификаты с сервера:")
    print(f"  scp root@{server_ip}:{item['cert_path']} /etc/phantom-vpn/client.crt")
    print(f"  scp root@{server_ip}:{item['key_path']}  /etc/phantom-vpn/client.key")

    print_android_instructions(name, item["cert_path"], item["key_path"])


def _pick_client(clients, prompt="Выберите клиента для экспорта:"):
    """Общий хелпер: выводит список клиентов и возвращает (name, item) или (None, None)."""
    names = sorted(clients.keys())
    if not names:
        print("Клиентов нет.")
        return None, None

    print(prompt)
    for i, n in enumerate(names, 1):
        item = clients[n]
        print(f"  {i}) {n}  (tun={item.get('tun_addr', '?')})")
    raw = input("> ").strip()
    try:
        idx = int(raw) - 1
    except ValueError:
        print("Неверный ввод.")
        return None, None
    if idx < 0 or idx >= len(names):
        print("Неверный выбор.")
        return None, None

    name = names[idx]
    return name, clients[name]


def _generate_conn_string(connect_host: str, server_name: str, server_port: str, tun_addr: str,
                          cert_pem: str, key_pem: str,
                          admin_url: Optional[str] = None, admin_token: Optional[str] = None) -> str:
    """Генерирует строку подключения (base64url JSON).

    Транспорт всегда H2/TLS — поле `transport` опущено (QUIC удалён в v0.19.x).
    Современный формат — `ghs://...` (см. CLAUDE.md), `build_conn_string` в
    `crates/server/src/admin.rs`. Этот скрипт оставлен для совместимости.
    """
    payload = {
        "v": 1,
        "addr": f"{connect_host}:{server_port}",
        "sni": server_name,
        "tun": tun_addr,
        "cert": cert_pem,
        "key": key_pem,
    }
    if admin_url and admin_token:
        payload["admin"] = {"url": admin_url, "token": admin_token}

    json_bytes = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return base64.urlsafe_b64encode(json_bytes).decode().rstrip("=")


def export_conn_str(keyring, connect_host, quic_port, h2_port, server_name):
    """Генерирует строку подключения HTTP/2 (единственный транспорт в v0.19.x)."""
    name, item = _pick_client(keyring["clients"])
    if name is None:
        return

    try:
        cert_pem = Path(item["cert_path"]).read_text(encoding="utf-8")
        key_pem  = Path(item["key_path"]).read_text(encoding="utf-8")
    except OSError as e:
        print(f"[ОШИБКА] Не удалось прочитать файлы сертификата: {e}")
        return

    conn_str_h2 = _generate_conn_string(
        connect_host=connect_host,
        server_name=server_name,
        server_port=h2_port,
        tun_addr=item["tun_addr"],
        cert_pem=cert_pem,
        key_pem=key_pem,
    )

    print(f"\n=== Строка подключения для {name!r} — HTTP/2 (порт {h2_port}) ===")
    print("─" * 60)
    print(conn_str_h2)
    print("─" * 60)

    print(f"\nИспользование:")
    print(f"  Android: вставьте в приложение → поле «Строка подключения» → Импортировать")
    print(f"  Linux:   sudo phantom-client-linux --conn-string '{conn_str_h2}'")
    print(f"  macOS:   sudo phantom-client-macos --conn-string '{conn_str_h2}'")


def export_admin_conn_str(keyring, connect_host, quic_port, h2_port, server_name,
                          admin_addr, admin_token):
    """Генерирует строку подключения с admin правами (HTTP/2)."""
    name, item = _pick_client(keyring["clients"],
                               prompt="Выберите клиента для экспорта (admin):")
    if name is None:
        return

    try:
        cert_pem = Path(item["cert_path"]).read_text(encoding="utf-8")
        key_pem  = Path(item["key_path"]).read_text(encoding="utf-8")
    except OSError as e:
        print(f"[ОШИБКА] Не удалось прочитать файлы сертификата: {e}")
        return

    # Resolve admin_addr / admin_token interactively if not provided
    if not admin_addr:
        admin_addr = input("Admin URL (e.g. http://10.7.0.1:8080): ").strip()
        if not admin_addr:
            print("admin_addr не задан, отменено.")
            return
    if not admin_token:
        admin_token = input("Admin token: ").strip()
        if not admin_token:
            print("admin_token не задан, отменено.")
            return

    # Normalise: ensure http:// prefix
    if not admin_addr.startswith("http://") and not admin_addr.startswith("https://"):
        admin_addr = "http://" + admin_addr

    conn_str_h2 = _generate_conn_string(
        connect_host=connect_host,
        server_name=server_name,
        server_port=h2_port,
        tun_addr=item["tun_addr"],
        cert_pem=cert_pem,
        key_pem=key_pem,
        admin_url=admin_addr,
        admin_token=admin_token,
    )

    print(f"\n=== Admin-строка для {name!r} — HTTP/2 (порт {h2_port}) ===")
    print("─" * 60)
    print(conn_str_h2)
    print("─" * 60)

    print(f"\nИспользование:")
    print(f"  Android: вставьте в приложение → поле «Строка подключения» → Импортировать")
    print(f"  Linux:   sudo phantom-client-linux --conn-string '{conn_str_h2}'")
    print(f"  macOS:   sudo phantom-client-macos --conn-string '{conn_str_h2}'")
    print(f"\n[admin] url={admin_addr}  token={admin_token[:8]}…")


def remove_client(keyring, keyring_path):
    clients = keyring["clients"]
    names   = sorted(clients.keys())
    if not names:
        print("Клиентов нет.")
        return
    print("Выберите клиента для удаления:")
    for i, n in enumerate(names, 1):
        item = clients[n]
        print(f"  {i}) {n}  (tun={item.get('tun_addr', '?')})")
    raw = input("> ").strip()
    try:
        idx = int(raw) - 1
    except ValueError:
        print("Неверный ввод.")
        return
    if idx < 0 or idx >= len(names):
        print("Неверный выбор.")
        return

    name = names[idx]
    item = clients[name]
    confirm = input(f"Удалить клиента {name!r}? (y/N): ").strip().lower()
    if confirm != "y":
        print("Отменено.")
        return

    # Optionally remove cert files
    for fpath in [item.get("cert_path"), item.get("key_path")]:
        if fpath and Path(fpath).exists():
            Path(fpath).unlink()
            print(f"Удалён файл: {fpath}")
    # Remove client dir if empty
    cert_dir = Path(item.get("cert_path", "")).parent
    try:
        cert_dir.rmdir()
    except OSError:
        pass

    del clients[name]
    save_keyring(keyring_path, keyring)
    print(f"Клиент '{name}' удалён из keyring.")


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="PhantomVPN client certificate manager (mTLS)"
    )
    parser.add_argument(
        "--server-config",
        default="/opt/phantom-vpn/config/server.toml",
        help="Путь к server.toml (default: /opt/phantom-vpn/config/server.toml)",
    )
    parser.add_argument(
        "--keyring",
        default="/opt/phantom-vpn/config/clients.json",
        help="Путь к keyring JSON (default: /opt/phantom-vpn/config/clients.json)",
    )
    parser.add_argument(
        "--server-ip",
        default=None,
        help="Публичный IP сервера (если listen_addr = 0.0.0.0)",
    )
    parser.add_argument(
        "--server-name",
        default=None,
        help="SNI сервера (e.g. nl2.bikini-bottom.com)",
    )
    parser.add_argument(
        "--admin-addr",
        default=None,
        help="Admin panel listen addr (e.g. 10.7.0.1:8080 or http://10.7.0.1:8080)",
    )
    parser.add_argument(
        "--admin-token",
        default=None,
        help="Admin panel bearer token",
    )
    args = parser.parse_args()

    try:
        server_ip, quic_port, h2_port, connect_host, server_name, ca_cert_path, ca_key_path = \
            load_server_values(
                args.server_config,
                server_ip_override=args.server_ip,
                server_name_override=args.server_name,
            )
    except RuntimeError as e:
        print(f"[ОШИБКА] {e}")
        raise SystemExit(1)

    try:
        keyring = load_keyring(args.keyring)
    except RuntimeError as e:
        print(f"[ОШИБКА] {e}")
        raise SystemExit(1)

    # Load admin values: CLI args take priority, then server.toml, then interactive
    admin_addr  = args.admin_addr
    admin_token = args.admin_token
    if not admin_addr or not admin_token:
        toml_admin_addr, toml_admin_token = load_admin_values(args.server_config)
        if not admin_addr:
            admin_addr  = toml_admin_addr
        if not admin_token:
            admin_token = toml_admin_token

    admin_configured = bool(admin_addr and admin_token)

    print(f"\n=== PhantomVPN Client Manager ===")
    print(f"Сервер:    connect_host={connect_host}  QUIC={quic_port}  H2={h2_port}  SNI={server_name}")
    print(f"SCP host:  {server_ip}")
    print(f"CA cert:   {ca_cert_path}")
    print(f"Keyring:   {args.keyring}  ({len(keyring['clients'])} клиентов)")
    if admin_configured:
        print(f"Admin:     {admin_addr}")
    print()
    print("1) Добавить клиента")
    print("2) Удалить клиента")
    print("3) Список клиентов")
    print("4) Показать конфиг клиента")
    print("5) Экспорт строки подключения (Android / Linux / macOS)")
    print("6) Экспорт строки подключения (с правами администратора)")
    choice = input("> ").strip()

    if choice == "1":
        add_client(keyring, server_ip, quic_port, h2_port, connect_host, server_name,
                   ca_cert_path, ca_key_path, args.keyring)
    elif choice == "2":
        remove_client(keyring, args.keyring)
    elif choice == "3":
        list_clients(keyring["clients"])
    elif choice == "4":
        show_client(keyring, server_ip, quic_port, h2_port, connect_host, server_name)
    elif choice == "5":
        export_conn_str(keyring, connect_host, quic_port, h2_port, server_name)
    elif choice == "6":
        export_admin_conn_str(keyring, connect_host, quic_port, h2_port, server_name,
                              admin_addr, admin_token)
    else:
        print("Неизвестная опция.")


if __name__ == "__main__":
    main()
