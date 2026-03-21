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
import tempfile
from datetime import datetime, timezone
from pathlib import Path

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

def load_server_values(server_toml_path, server_ip_override=None, server_name_override=None):
    """Возвращает (server_ip, server_port, server_name, ca_cert_path, ca_key_path)."""
    data = load_toml(server_toml_path)

    network = data.get("network", {}) if isinstance(data.get("network"), dict) else {}
    quic    = data.get("quic",    {}) if isinstance(data.get("quic"),    dict) else {}

    listen_addr = network.get("listen_addr", "0.0.0.0:8443")
    parts       = listen_addr.rsplit(":", 1)
    raw_ip      = parts[0] if len(parts) == 2 else listen_addr
    server_port = parts[1] if len(parts) == 2 else "8443"

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

    return server_ip, server_port, server_name, str(ca_cert_path), str(ca_key_path)


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

def render_client_toml(server_ip, server_port, server_name, tun_addr,
                       cert_path, key_path):
    return f"""[network]
server_addr = "{server_ip}:{server_port}"
server_name = "{server_name}"
insecure    = false
tun_addr    = "{tun_addr}"
tun_mtu     = 1350
default_gw  = "10.7.0.1"

[quic]
cert_path = "{cert_path}"
key_path  = "{key_path}"
"""


def print_android_instructions(name, local_cert, local_key):
    android_dir = "/sdcard/Android/data/com.phantom.vpn/files"
    print("\nДля Android (через adb):")
    print(f"  adb push {local_cert} {android_dir}/client.crt")
    print(f"  adb push {local_key}  {android_dir}/client.key")
    print(f"\nВ приложении PhantomVPN укажите пути:")
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


def add_client(keyring, server_ip, server_port, server_name,
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

    # Config for Linux/macOS
    linux_toml = render_client_toml(
        server_ip, server_port, server_name, tun_addr,
        "/etc/phantom-vpn/client.crt",
        "/etc/phantom-vpn/client.key",
    )
    print(f"\nКонфиг Linux/macOS (/etc/phantom-vpn/client.toml):\n")
    print("─" * 60)
    print(linux_toml)
    print("─" * 60)
    print(f"\nСкопировать сертификаты:")
    print(f"  scp root@{server_ip}:{cert_path} /etc/phantom-vpn/client.crt")
    print(f"  scp root@{server_ip}:{key_path}  /etc/phantom-vpn/client.key")

    print_android_instructions(name, cert_path, key_path)


def show_client(keyring, server_ip, server_port, server_name):
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

    linux_toml = render_client_toml(
        server_ip, server_port, server_name,
        item["tun_addr"],
        "/etc/phantom-vpn/client.crt",
        "/etc/phantom-vpn/client.key",
    )
    print(f"\nКонфиг {name!r} (Linux/macOS):\n")
    print("─" * 60)
    print(linux_toml)
    print("─" * 60)
    print(f"\nСкопировать сертификаты с сервера:")
    print(f"  scp root@{server_ip}:{item['cert_path']} /etc/phantom-vpn/client.crt")
    print(f"  scp root@{server_ip}:{item['key_path']}  /etc/phantom-vpn/client.key")

    print_android_instructions(name, item["cert_path"], item["key_path"])


def export_conn_str(keyring, server_ip, server_port, server_name):
    """Генерирует строку подключения (base64url JSON) для вставки в приложение."""
    clients = keyring["clients"]
    names   = sorted(clients.keys())
    if not names:
        print("Клиентов нет.")
        return

    print("Выберите клиента для экспорта:")
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

    try:
        cert_pem = Path(item["cert_path"]).read_text(encoding="utf-8")
        key_pem  = Path(item["key_path"]).read_text(encoding="utf-8")
    except OSError as e:
        print(f"[ОШИБКА] Не удалось прочитать файлы сертификата: {e}")
        return

    payload = {
        "v":    1,
        "addr": f"{server_name}:{server_port}",
        "sni":  server_name,
        "tun":  item["tun_addr"],
        "cert": cert_pem,
        "key":  key_pem,
    }

    json_bytes = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    conn_str   = base64.urlsafe_b64encode(json_bytes).decode().rstrip("=")

    print(f"\nСтрока подключения для {name!r}:")
    print("─" * 60)
    print(conn_str)
    print("─" * 60)
    print(f"\nИспользование:")
    print(f"  Android: вставьте в приложение → поле «Строка подключения» → Импортировать")
    print(f"  Linux:   sudo phantom-client-linux --conn-string '{conn_str}'")
    print(f"  macOS:   sudo phantom-client-macos --conn-string '{conn_str}'")


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
    args = parser.parse_args()

    try:
        server_ip, server_port, server_name, ca_cert_path, ca_key_path = \
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

    print(f"\n=== PhantomVPN Client Manager ===")
    print(f"Сервер:    {server_ip}:{server_port}  SNI: {server_name}")
    print(f"CA cert:   {ca_cert_path}")
    print(f"Keyring:   {args.keyring}  ({len(keyring['clients'])} клиентов)")
    print()
    print("1) Добавить клиента")
    print("2) Удалить клиента")
    print("3) Список клиентов")
    print("4) Показать конфиг клиента")
    print("5) Экспорт строки подключения (Android / Linux / macOS)")
    choice = input("> ").strip()

    if choice == "1":
        add_client(keyring, server_ip, server_port, server_name,
                   ca_cert_path, ca_key_path, args.keyring)
    elif choice == "2":
        remove_client(keyring, args.keyring)
    elif choice == "3":
        list_clients(keyring["clients"])
    elif choice == "4":
        show_client(keyring, server_ip, server_port, server_name)
    elif choice == "5":
        export_conn_str(keyring, server_ip, server_port, server_name)
    else:
        print("Неизвестная опция.")


if __name__ == "__main__":
    main()
