#!/usr/bin/env python3
"""PhantomVPN client key manager — совместим с QUIC-транспортом (v2)."""
import argparse
import base64
import json
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None


def load_server_values(server_toml_path, server_ip_override=None):
    """Читает server.toml и возвращает (server_ip, server_port, server_public_key).

    server_ip_override позволяет задать IP явно — нужно, когда в server.toml
    прописан listen_addr = "0.0.0.0:443" вместо реального IP.
    """
    content = Path(server_toml_path).read_text(encoding="utf-8")
    if tomllib is not None:
        data = tomllib.loads(content)
        listen_addr = data.get("network", {}).get("listen_addr", "0.0.0.0:443")
        keys = data.get("keys", {}) or {}
        server_public_key = keys.get("server_public_key")
    else:
        listen_addr, server_public_key = _parse_server_toml_minimal(content)

    if not server_public_key:
        raise RuntimeError(
            "server.toml must contain [keys].server_public_key"
        )

    # Разбираем IP и порт из listen_addr
    parts = listen_addr.rsplit(":", 1)
    raw_ip = parts[0] if len(parts) == 2 else listen_addr
    server_port = parts[1] if len(parts) == 2 else "443"

    if server_ip_override:
        server_ip = server_ip_override
    elif raw_ip in ("0.0.0.0", "[::]", "::"):
        print(
            f"[!] listen_addr содержит {raw_ip!r} — задайте реальный IP через --server-ip"
        )
        server_ip = input("Введите публичный IP сервера: ").strip()
        if not server_ip:
            raise RuntimeError("IP сервера не задан")
    else:
        server_ip = raw_ip

    return server_ip, server_port, server_public_key


def _parse_server_toml_minimal(content):
    """Минимальный парсер TOML без зависимостей (fallback для Python < 3.11)."""
    section = ""
    listen_addr = "0.0.0.0:443"
    server_public_key = None

    for raw in content.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.split("#", 1)[0].strip().strip('"')
        if section == "network" and key == "listen_addr":
            listen_addr = value
        elif section == "keys" and key == "server_public_key":
            server_public_key = value

    return listen_addr, server_public_key


def load_keyring(path):
    p = Path(path)
    if not p.exists():
        return {"clients": {}}
    data = json.loads(p.read_text(encoding="utf-8"))
    if "clients" not in data or not isinstance(data["clients"], dict):
        raise RuntimeError(f"Invalid keyring format in {path}: missing 'clients' object")
    return data


def save_keyring(path, keyring):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(keyring, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def next_tun_addr(clients):
    used = set()
    for item in clients.values():
        tun_addr = item.get("tun_addr", "")
        ip = tun_addr.split("/", 1)[0]
        octets = ip.split(".")
        if len(octets) == 4 and octets[0] == "10" and octets[1] == "7" and octets[2] == "0":
            try:
                used.add(int(octets[3]))
            except ValueError:
                pass
    for host in range(2, 255):
        if host not in used:
            return f"10.7.0.{host}/24"
    raise RuntimeError("No free tunnel addresses left in 10.7.0.0/24")


def generate_x25519_keypair_b64():
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    except ModuleNotFoundError:
        return _generate_from_phantom_keygen()

    private_key = X25519PrivateKey.generate()
    public_key = private_key.public_key()
    private_raw = private_key.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_raw = public_key.public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return (
        base64.b64encode(private_raw).decode(),
        base64.b64encode(public_raw).decode(),
    )


def _generate_from_phantom_keygen():
    candidates = [
        Path("./target/release/phantom-keygen"),
        Path("/opt/phantom-vpn/phantom-keygen"),
    ]
    which = shutil.which("phantom-keygen")
    if which:
        candidates.append(Path(which))

    keygen_path = None
    for candidate in candidates:
        if candidate.exists():
            keygen_path = str(candidate)
            break
    if not keygen_path:
        raise RuntimeError(
            "Не найден keygen. Установите python3-cryptography, или соберите "
            "phantom-keygen и положите его в ./target/release/ или /opt/phantom-vpn/."
        )

    output = subprocess.check_output([keygen_path], text=True)
    found = {}
    for raw in output.splitlines():
        line = raw.strip()
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        found[k.strip()] = v.strip().strip('"')

    try:
        return found["client_private_key"], found["client_public_key"]
    except KeyError as err:
        raise RuntimeError("Не удалось распарсить ключи из вывода phantom-keygen") from err


def render_client_toml(server_ip, server_port, tun_addr,
                       client_private_key, client_public_key, server_public_key):
    """Генерирует конфиг клиента в формате QUIC (PhantomVPN v2)."""
    return f"""[network]
server_addr = "{server_ip}:{server_port}"
server_name = "{server_ip}"
insecure    = true
tun_addr    = "{tun_addr}"
tun_mtu     = 1350
default_gw  = "10.7.0.1"

[keys]
client_private_key = "{client_private_key}"
client_public_key  = "{client_public_key}"
server_public_key  = "{server_public_key}"
"""


def _short_hex_from_b64(value):
    raw = base64.b64decode(value)
    h = raw.hex()
    return f"{h[:16]}...{h[-8:]}"


def list_clients(clients):
    if not clients:
        print("Нет клиентских ключей.")
        return
    print("Клиентские ключи:")
    for idx, name in enumerate(sorted(clients.keys()), start=1):
        item = clients[name]
        print(
            f"{idx:>2}. {name:<24} "
            f"tun={item.get('tun_addr', '?'):<12} "
            f"pub={_short_hex_from_b64(item['client_public_key'])} "
            f"created={item.get('created_at', '-')}"
        )


def add_client(keyring, server_ip, server_port, server_public_key):
    clients = keyring["clients"]
    name = input("Имя клиента: ").strip()
    if not name:
        print("Имя не может быть пустым.")
        return
    if name in clients:
        print(f"Клиент '{name}' уже существует.")
        return

    tun_addr = next_tun_addr(clients)
    client_private_key, client_public_key = generate_x25519_keypair_b64()
    clients[name] = {
        "client_private_key": client_private_key,
        "client_public_key":  client_public_key,
        "tun_addr":           tun_addr,
        "created_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    }

    client_toml = render_client_toml(
        server_ip,
        server_port,
        tun_addr,
        client_private_key,
        client_public_key,
        server_public_key,
    )
    print("\nКлюч клиента создан.")
    print("Скопируйте конфиг и поместите его в файл client.toml на устройстве:\n")
    print("─" * 60)
    print(client_toml)
    print("─" * 60)


def get_client_config(keyring, server_ip, server_port, server_public_key):
    """Показывает конфиг уже существующего клиента."""
    clients = keyring["clients"]
    names = sorted(clients.keys())
    if not names:
        print("Нет клиентских ключей.")
        return
    print("Выберите клиента:")
    for idx, name in enumerate(names, start=1):
        item = clients[name]
        print(f"  {idx}) {name}  (tun={item.get('tun_addr', '?')})")
    selected = input("> ").strip()
    try:
        index = int(selected)
    except ValueError:
        print("Неверный ввод.")
        return
    if index < 1 or index > len(names):
        print("Неверный выбор.")
        return
    name = names[index - 1]
    item = clients[name]
    client_toml = render_client_toml(
        server_ip,
        server_port,
        item["tun_addr"],
        item["client_private_key"],
        item["client_public_key"],
        server_public_key,
    )
    print(f"\nКонфиг для {name!r}:\n")
    print("─" * 60)
    print(client_toml)
    print("─" * 60)


def remove_client(keyring):
    clients = keyring["clients"]
    names = sorted(clients.keys())
    if not names:
        print("Нет клиентских ключей для удаления.")
        return
    print("Выберите ключ для удаления:")
    for idx, name in enumerate(names, start=1):
        print(f"  {idx}) {name}")
    selected = input("> ").strip()
    try:
        index = int(selected)
    except ValueError:
        print("Неверный ввод.")
        return
    if index < 1 or index > len(names):
        print("Неверный выбор.")
        return
    name = names[index - 1]
    del clients[name]
    print(f"Удалён клиент: {name}")


def main():
    parser = argparse.ArgumentParser(description="PhantomVPN client key manager (QUIC)")
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
        help="Публичный IP сервера (если в listen_addr стоит 0.0.0.0)",
    )
    args = parser.parse_args()

    server_ip, server_port, server_public_key = load_server_values(
        args.server_config, server_ip_override=args.server_ip
    )
    keyring = load_keyring(args.keyring)

    print(f"\n=== PhantomVPN Key Manager ===")
    print(f"Сервер: {server_ip}:{server_port}")
    print(f"Keyring: {args.keyring}")
    print(f"Клиентов: {len(keyring['clients'])}")
    print()
    print("1) Добавить клиентский ключ")
    print("2) Удалить клиентский ключ")
    print("3) Список клиентов")
    print("4) Показать конфиг клиента")
    choice = input("> ").strip()

    if choice == "1":
        add_client(keyring, server_ip, server_port, server_public_key)
        save_keyring(args.keyring, keyring)
    elif choice == "2":
        remove_client(keyring)
        save_keyring(args.keyring, keyring)
    elif choice == "3":
        list_clients(keyring["clients"])
    elif choice == "4":
        get_client_config(keyring, server_ip, server_port, server_public_key)
    else:
        print("Неизвестная опция.")


if __name__ == "__main__":
    main()
