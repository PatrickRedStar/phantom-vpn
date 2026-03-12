#!/usr/bin/env python3
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
    import tomli as tomllib


def load_server_values(server_toml_path):
    content = Path(server_toml_path).read_text(encoding="utf-8")
    data = tomllib.loads(content)
    listen_addr = data.get("network", {}).get("listen_addr", "127.0.0.1:3478")
    server_ip = listen_addr.rsplit(":", 1)[0]
    keys = data.get("keys", {})
    server_public_key = keys.get("server_public_key")
    shared_secret = keys.get("shared_secret")
    if not server_public_key or not shared_secret:
        raise RuntimeError(
            "server.toml must contain [keys].server_public_key and [keys].shared_secret"
        )
    return server_ip, server_public_key, shared_secret


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
    except ModuleNotFoundError as e:
        return generate_from_phantom_keygen()  # fallback when cryptography is unavailable

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


def generate_from_phantom_keygen():
    candidates = [
        Path("./target/release/phantom-keygen"),
        Path("/opt/phantom-vpn/phantom-keygen"),
    ]
    path_from_env = Path(str(Path.cwd() / "target/release/phantom-keygen"))
    if path_from_env not in candidates:
        candidates.insert(0, path_from_env)
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
            "No keygen source found. Install python3-cryptography, or build "
            "phantom-keygen and place it in ./target/release/ or /opt/phantom-vpn/."
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
        raise RuntimeError("Failed to parse client keys from phantom-keygen output") from err


def render_client_toml(server_ip, tun_addr, client_private_key, client_public_key, server_public_key, shared_secret):
    return f"""[network]
server_addr = "{server_ip}:3478"
tun_name    = "tun0"
tun_addr    = "{tun_addr}"
tun_mtu     = 1380
default_gw  = "10.7.0.1"

[keys]
client_private_key = "{client_private_key}"
client_public_key  = "{client_public_key}"
server_public_key  = "{server_public_key}"
shared_secret      = "{shared_secret}"
"""


def short_hex_from_b64(value):
    raw = base64.b64decode(value)
    h = raw.hex()
    return f"{h[:16]}...{h[-8:]}"


def list_clients(clients):
    if not clients:
        print("No client keys found.")
        return
    print("Client keys:")
    for idx, name in enumerate(sorted(clients.keys()), start=1):
        item = clients[name]
        print(
            f"{idx:>2}. {name:<24} "
            f"tun={item.get('tun_addr', '?'):<12} "
            f"pub={short_hex_from_b64(item['client_public_key'])} "
            f"created={item.get('created_at', '-')}"
        )


def add_client(keyring, server_ip, server_public_key, shared_secret):
    clients = keyring["clients"]
    name = input("Enter client name: ").strip()
    if not name:
        print("Name cannot be empty.")
        return
    if name in clients:
        print(f"Client '{name}' already exists.")
        return

    tun_addr = next_tun_addr(clients)
    client_private_key, client_public_key = generate_x25519_keypair_b64()
    clients[name] = {
        "client_private_key": client_private_key,
        "client_public_key": client_public_key,
        "tun_addr": tun_addr,
        "created_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    }

    client_toml = render_client_toml(
        server_ip,
        tun_addr,
        client_private_key,
        client_public_key,
        server_public_key,
        shared_secret,
    )
    print("\nClient key created.")
    print("Copy and paste this client config:\n")
    print(client_toml)


def remove_client(keyring):
    clients = keyring["clients"]
    names = sorted(clients.keys())
    if not names:
        print("No client keys to remove.")
        return
    print("Select key to delete:")
    for idx, name in enumerate(names, start=1):
        print(f"{idx}) {name}")
    selected = input("> ").strip()
    try:
        index = int(selected)
    except ValueError:
        print("Invalid selection.")
        return
    if index < 1 or index > len(names):
        print("Invalid selection.")
        return
    name = names[index - 1]
    del clients[name]
    print(f"Removed client key: {name}")


def main():
    parser = argparse.ArgumentParser(description="PhantomVPN client key manager")
    parser.add_argument(
        "--server-config",
        default="/opt/phantom-vpn/config/server.toml",
        help="Path to server.toml",
    )
    parser.add_argument(
        "--keyring",
        default="/opt/phantom-vpn/config/clients.json",
        help="Path to clients keyring JSON",
    )
    args = parser.parse_args()

    server_ip, server_public_key, shared_secret = load_server_values(args.server_config)
    keyring = load_keyring(args.keyring)

    print("=== PhantomVPN Key Manager ===")
    print("1) Add client key")
    print("2) Remove client key")
    print("3) List client keys")
    choice = input("> ").strip()

    if choice == "1":
        add_client(keyring, server_ip, server_public_key, shared_secret)
        save_keyring(args.keyring, keyring)
    elif choice == "2":
        remove_client(keyring)
        save_keyring(args.keyring, keyring)
    elif choice == "3":
        list_clients(keyring["clients"])
    else:
        print("Unknown option.")


if __name__ == "__main__":
    main()
