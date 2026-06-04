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
import re
import subprocess
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


def _detect_insecure_from_server_toml(quic_section: dict) -> bool:
    """Решает, нужен ли клиенту `insecure=1` для skip server cert verification.

    Logic:
      - cert_path указан и существует → LE/коммерческий cert → клиент verify
        через webpki_roots → insecure=False
      - cert_path не задан → phantom-server генерит self-signed по cert_subjects →
        клиент НЕ найдёт CA в webpki_roots → нужен insecure=True
    """
    cert_path_raw = quic_section.get("cert_path")
    if isinstance(cert_path_raw, str) and cert_path_raw.strip():
        try:
            if Path(cert_path_raw).is_file():
                return False  # имеется явный (LE) cert
        except OSError:
            pass
    return True  # self-signed fallback


def load_server_values(server_toml_path, server_ip_override=None, server_name_override=None):
    """Возвращает:
    (server_ip, quic_port, h2_port, connect_host, server_name, ca_cert_path, ca_key_path, insecure).
    """
    data = load_toml(server_toml_path)

    network = data.get("network", {}) if isinstance(data.get("network"), dict) else {}
    quic    = data.get("quic",    {}) if isinstance(data.get("quic"),    dict) else {}
    h2      = data.get("h2",      {}) if isinstance(data.get("h2"),      dict) else {}

    listen_addr = network.get("listen_addr", "0.0.0.0:443")
    raw_ip, quic_port = _split_host_port(listen_addr, "443")

    h2_listen_addr = h2.get("listen_addr", "0.0.0.0:9443")
    _h2_host, h2_port = _split_host_port(h2_listen_addr, "9443")

    # public_addr — авторитативный публичный адрес (entrypoint выставляет из env).
    # Используется и для server_ip, и для connect_host если listen_addr = 0.0.0.0.
    public_addr_raw = network.get("public_addr")
    public_host = None
    if isinstance(public_addr_raw, str) and public_addr_raw.strip():
        public_host, _ = _split_host_port(public_addr_raw, quic_port)

    # Resolve server IP
    if server_ip_override:
        server_ip = server_ip_override
    elif raw_ip in ("0.0.0.0", "[::]", "::"):
        if public_host:
            server_ip = public_host
        else:
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
        # 1) Self-signed bootstrap путь: cert_subjects = ["<host>"] в [quic].
        subjects = quic.get("cert_subjects")
        if isinstance(subjects, list) and subjects and isinstance(subjects[0], str):
            server_name = subjects[0].strip()
        else:
            # 2) Let's Encrypt путь: cert_path = ".../live/<host>/fullchain.pem"
            cert_path = quic.get("cert_path", "")
            m = re.search(r"/live/([^/]+)/", cert_path)
            if m:
                server_name = m.group(1)
            else:
                # 3) Интерактив как последняя надежда.
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

    insecure = _detect_insecure_from_server_toml(quic)

    return (
        server_ip,
        quic_port,
        h2_port,
        connect_host,
        server_name,
        str(ca_cert_path),
        str(ca_key_path),
        insecure,
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
               ca_cert_path, ca_key_path, keyring_path, insecure=True):
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

    try:
        cert_pem = Path(cert_path).read_text(encoding="utf-8")
        key_pem  = Path(key_path).read_text(encoding="utf-8")
    except OSError as e:
        print(f"[ОШИБКА] Не удалось прочитать сертификаты: {e}")
        return

    _print_conn_for_client(name, connect_host, h2_port, server_name, tun_addr, cert_pem, key_pem,
                          insecure=insecure)


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


def _build_ghs_url(connect_host: str, server_port: str, server_name: str,
                   tun_addr: str, cert_pem: str, key_pem: str,
                   insecure: bool = True) -> str:
    """Канонический формат `ghs://` (см. `crates/server/src/admin.rs::build_conn_string`).

    Layout: `ghs://<base64url(cert\\nkey)>@<host:port>?sni=<sni>&tun=<tun>&v=1[&insecure=1]`

    `insecure=True` по умолчанию: phantom-server в docker раскатывает self-signed
    CA, который НЕ в webpki_roots → стандартный rustls verify провалится с
    UnknownCA. mTLS client cert остаётся — server pin'ит клиента по fingerprint,
    идентичность не теряется. Если у тебя phantom-server за nginx с LE cert
    (как vdsina) — генерируй с `insecure=False`.
    """
    from urllib.parse import quote as _urlquote
    pem = cert_pem.rstrip() + "\n" + key_pem.strip()
    userinfo = base64.urlsafe_b64encode(pem.encode("utf-8")).decode("ascii").rstrip("=")
    url = (
        f"ghs://{userinfo}@{connect_host}:{server_port}"
        f"?sni={_urlquote(server_name, safe='')}"
        f"&tun={_urlquote(tun_addr, safe='')}"
        f"&v=1"
    )
    if insecure:
        url += "&insecure=1"
    return url


def _print_conn_for_client(name: str, connect_host: str, server_port: str,
                          server_name: str, tun_addr: str, cert_pem: str, key_pem: str,
                          insecure: bool = True) -> None:
    """Печать ghs:// строки для клиента.

    QR-код не рисуем: payload (cert+key в base64) >1 KB — ASCII QR размером с
    экран и нечитаемый сканером.
    """
    ghs = _build_ghs_url(connect_host, server_port, server_name, tun_addr,
                         cert_pem, key_pem, insecure=insecure)
    print()
    print(f"=== Подключение для {name!r} ===")
    print(f"  Адрес: {connect_host}:{server_port}")
    print(f"  SNI:   {server_name}")
    print(f"  TUN:   {tun_addr}")
    if insecure:
        print(f"  insecure: yes (self-signed CA — skip server cert verification)")
    else:
        print(f"  insecure: no (cert валиден через webpki_roots, e.g. Let's Encrypt)")
    print()
    print("Строка подключения (ghs://) — скопируй и вставь в Android/iOS приложение:")
    print()
    print(ghs)
    print()
    print(f"Длина: {len(ghs)} символов. Скопировать всю строку без пробелов.")
    print()


def export_conn_str(keyring, connect_host, quic_port, h2_port, server_name, insecure=True):
    """Печать ghs:// строки для выбранного клиента."""
    name, item = _pick_client(keyring["clients"])
    if name is None:
        return

    try:
        cert_pem = Path(item["cert_path"]).read_text(encoding="utf-8")
        key_pem  = Path(item["key_path"]).read_text(encoding="utf-8")
    except OSError as e:
        print(f"[ОШИБКА] Не удалось прочитать файлы сертификата: {e}")
        return

    _print_conn_for_client(name, connect_host, h2_port, server_name,
                          item["tun_addr"], cert_pem, key_pem, insecure=insecure)


def grant_admin(keyring, keyring_path):
    """Помечает клиента как админа (is_admin=true в clients.json).

    После рестарта phantom-server клиент получает доступ к /api/* endpoint'ам
    (через mTLS, не через токен). Android приложение после connect дёргает
    /api/whoami и если is_admin=true — открывает admin menu по long-press на
    профиле в Settings.
    """
    clients = keyring["clients"]
    names = sorted(clients.keys())
    if not names:
        print("Клиентов нет.")
        return

    print("Выберите клиента для grant/revoke admin:")
    for i, n in enumerate(names, 1):
        flag = " [admin]" if clients[n].get("is_admin") else ""
        print(f"  {i}) {n}{flag}")
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
    current = bool(clients[name].get("is_admin"))
    new_val = not current
    clients[name]["is_admin"] = new_val
    save_keyring(keyring_path, keyring)
    print(f"{name}: is_admin = {new_val}")
    print()
    print("ВАЖНО: перезапусти phantom-server чтобы новый флаг подхватился:")
    print("  docker compose restart phantom-server")
    print()
    print("После перезапуска и Android-reconnect: long-press на профиль в Settings → Admin menu.")


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
        server_ip, quic_port, h2_port, connect_host, server_name, ca_cert_path, ca_key_path, insecure = \
            load_server_values(
                args.server_config,
                server_ip_override=args.server_ip,
                server_name_override=args.server_name,
            )
    except RuntimeError as e:
        print(f"[ОШИБКА] {e}")
        raise SystemExit(1)

    while True:
        # Re-load keyring каждую итерацию — после add/remove счётчик клиентов актуальный.
        try:
            keyring = load_keyring(args.keyring)
        except RuntimeError as e:
            print(f"[ОШИБКА] {e}")
            raise SystemExit(1)

        admin_count = sum(1 for c in keyring["clients"].values() if c.get("is_admin"))

        print(f"\n=== PhantomVPN Client Manager ===")
        print(f"Сервер:    {connect_host}:{h2_port}   SNI: {server_name}")
        print(f"Keyring:   {args.keyring}  ({len(keyring['clients'])} клиентов, {admin_count} админ)")
        print()
        print("  1) Добавить клиента")
        print("  2) Удалить клиента")
        print("  3) Список клиентов")
        print("  4) Показать строку подключения клиента (ghs://)")
        print("  5) Toggle admin для клиента (is_admin в clients.json)")
        print("  0) Выход  (либо q, Ctrl-C)")
        try:
            choice = input("> ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print()
            return

        if choice in ("0", "q", "quit", "exit"):
            return
        elif choice == "1":
            add_client(keyring, server_ip, quic_port, h2_port, connect_host, server_name,
                       ca_cert_path, ca_key_path, args.keyring, insecure=insecure)
        elif choice == "2":
            remove_client(keyring, args.keyring)
        elif choice == "3":
            list_clients(keyring["clients"])
        elif choice == "4":
            export_conn_str(keyring, connect_host, quic_port, h2_port, server_name,
                            insecure=insecure)
        elif choice == "5":
            grant_admin(keyring, args.keyring)
        elif choice == "":
            continue
        else:
            print(f"Неизвестная опция: {choice!r}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
