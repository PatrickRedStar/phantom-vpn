#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone


class Colors:
    GREEN = "\033[92m"
    BLUE = "\033[94m"
    YELLOW = "\033[93m"
    RED = "\033[91m"
    RESET = "\033[0m"


SYSTEMD_UNIT = """[Unit]
Description=PhantomVPN Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/phantom-vpn
ExecStart=/opt/phantom-vpn/phantom-server -c /opt/phantom-vpn/config/server.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
"""


def print_step(msg):
    print(f"\n{Colors.BLUE}==>{Colors.RESET} {Colors.GREEN}{msg}{Colors.RESET}")


def fail(msg):
    print(f"{Colors.RED}{msg}{Colors.RESET}")
    sys.exit(1)


def run_cmd(cmd, dry_run=False, suppress_output=False):
    if dry_run:
        print(f"{Colors.YELLOW}[dry-run]{Colors.RESET} {cmd}")
        return
    try:
        if suppress_output:
            subprocess.run(
                cmd,
                shell=True,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        else:
            subprocess.run(cmd, shell=True, check=True)
    except subprocess.CalledProcessError:
        fail(f"Command failed: {cmd}")


def run_capture(cmd, dry_run=False, default=""):
    if dry_run:
        print(f"{Colors.YELLOW}[dry-run capture]{Colors.RESET} {cmd}")
        return default
    try:
        return subprocess.check_output(cmd, shell=True, text=True).strip()
    except subprocess.CalledProcessError:
        return default


def parse_keygen_output(output):
    keys = {
        "server_private_key": "",
        "server_public_key": "",
        "client_private_key": "",
        "client_public_key": "",
        "shared_secret": "",
    }
    for raw in output.splitlines():
        line = raw.strip()
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip().strip('"')
        if key in keys:
            keys[key] = val
    if any(not v for v in keys.values()):
        fail("Failed to parse one or more keys from phantom-keygen output.")
    return keys


def generate_client_toml(server_addr, keys):
    return f"""[network]
server_addr = "{server_addr}:3478"
tun_name    = "tun0"
tun_addr    = "10.7.0.2/24"
tun_mtu     = 1380
default_gw  = "10.7.0.1"

[keys]
client_private_key = "{keys['client_private_key']}"
client_public_key  = "{keys['client_public_key']}"
server_public_key  = "{keys['server_public_key']}"
shared_secret      = "{keys['shared_secret']}"
"""


def generate_server_toml(listen_ip, primary_iface, keys):
    return f"""[network]
listen_addr = "{listen_ip}:3478"
tun_name    = "tun0"
tun_addr    = "10.7.0.1/24"
tun_mtu     = 1380
wan_iface   = "{primary_iface}"

[keys]
server_private_key = "{keys['server_private_key']}"
server_public_key  = "{keys['server_public_key']}"
shared_secret      = "{keys['shared_secret']}"

[timeouts]
idle_timeout_secs  = 300
hard_timeout_secs  = 86400
"""


def write_clients_keyring(path, client_name, keys, tun_addr, dry_run=False):
    record = {
        "client_private_key": keys["client_private_key"],
        "client_public_key": keys["client_public_key"],
        "tun_addr": tun_addr,
        "created_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    }
    keyring = {"clients": {client_name: record}}
    if dry_run:
        print(f"{Colors.YELLOW}[dry-run]{Colors.RESET} write {path}")
        return
    with open(path, "w", encoding="utf-8") as f:
        json.dump(keyring, f, indent=2, sort_keys=True)
        f.write("\n")


def main():
    parser = argparse.ArgumentParser(
        description="Clean one-button deploy for PhantomVPN server."
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print deploy steps without changing the system.",
    )
    parser.add_argument(
        "--client-host",
        default="client-host",
        help="Client host label used in quick-start output (default: client-host).",
    )
    args = parser.parse_args()

    if not args.dry_run and os.geteuid() != 0:
        fail("This script must be run as root! (sudo ./scripts/install.py)")

    # Allow running cargo even when root's shell profile was not sourced.
    os.environ["PATH"] += f":{os.environ.get('HOME', '/root')}/.cargo/bin"

    print(f"{Colors.BLUE}=== PhantomVPN One-Button Clean Deploy ==={Colors.RESET}")
    server_host = run_capture("hostname -s", dry_run=args.dry_run, default="server-host")
    print(f"Target server host: {server_host}")

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    os.chdir(repo_root)
    print_step(f"Using repository root: {repo_root}")

    # 1. Install system dependencies
    print_step("Installing system dependencies...")
    run_cmd(
        "DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get update -qq",
        dry_run=args.dry_run,
    )
    run_cmd(
        "DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y -qq curl git build-essential pkg-config iproute2 iptables clang llvm libelf-dev",
        dry_run=args.dry_run,
    )
    run_cmd(
        "DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y -qq linux-headers-$(uname -r) || DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y -qq linux-headers-generic",
        dry_run=args.dry_run,
    )

    # 2. Ensure Rust
    print_step("Checking Rust installation...")
    cargo_in_path = shutil.which("cargo")
    if not cargo_in_path:
        print("Installing Rust (minimal profile stable)...")
        run_cmd(
            "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable",
            dry_run=args.dry_run,
        )
        os.environ["PATH"] += f":{os.environ.get('HOME', '/root')}/.cargo/bin"
    else:
        print("Rust is already installed.")

    # 3. Build artifacts
    print_step("Building phantom-server and phantom-keygen...")
    run_cmd("cargo build --release -p phantom-server", dry_run=args.dry_run)
    run_cmd(
        "cargo build --release -p phantom-server --bin phantom-keygen",
        dry_run=args.dry_run,
    )

    # 4. Generate fresh keys
    print_step("Generating fresh VPN keys...")
    if args.dry_run:
        keys = {
            "server_private_key": "DRYRUN_SERVER_PRIVATE_KEY_BASE64",
            "server_public_key": "DRYRUN_SERVER_PUBLIC_KEY_BASE64",
            "client_private_key": "DRYRUN_CLIENT_PRIVATE_KEY_BASE64",
            "client_public_key": "DRYRUN_CLIENT_PUBLIC_KEY_BASE64",
            "shared_secret": "DRYRUN_SHARED_SECRET_BASE64",
        }
    else:
        keygen_output = subprocess.check_output(["./target/release/phantom-keygen"], text=True)
        keys = parse_keygen_output(keygen_output)

    # 5. Resolve network params
    print_step("Detecting public IP and primary interface...")
    public_ip = run_capture("curl -4 -s --max-time 5 https://ifconfig.me", dry_run=args.dry_run, default="")
    if not public_ip:
        public_ip = run_capture("curl -4 -s --max-time 5 https://ipv4.icanhazip.com", dry_run=args.dry_run, default="0.0.0.0")
    primary_iface = run_capture(
        "ip route show default | awk '{print $5}' | head -n 1",
        dry_run=args.dry_run,
        default="eth0",
    )
    if not primary_iface:
        primary_iface = "eth0"
    print(f"Detected server public IP: {public_ip}")
    print(f"Detected WAN interface:   {primary_iface}")

    # 6. Clean deploy layout and write server config
    print_step("Preparing clean /opt/phantom-vpn layout...")
    run_cmd("systemctl stop phantom-vpn || true", dry_run=args.dry_run, suppress_output=True)
    run_cmd("pkill -x phantom-server || true", dry_run=args.dry_run, suppress_output=True)
    run_cmd("rm -rf /opt/phantom-vpn", dry_run=args.dry_run)
    run_cmd("mkdir -p /opt/phantom-vpn/config", dry_run=args.dry_run)

    server_toml = generate_server_toml(public_ip, primary_iface, keys)
    if args.dry_run:
        print(f"{Colors.YELLOW}[dry-run]{Colors.RESET} write /opt/phantom-vpn/config/server.toml")
    else:
        with open("/opt/phantom-vpn/config/server.toml", "w", encoding="utf-8") as f:
            f.write(server_toml)

    # 7. Install binary and systemd
    print_step("Installing phantom-server and configuring systemd...")
    run_cmd("install -m 0755 ./target/release/phantom-server /opt/phantom-vpn/phantom-server", dry_run=args.dry_run)
    if args.dry_run:
        print(f"{Colors.YELLOW}[dry-run]{Colors.RESET} write /etc/systemd/system/phantom-vpn.service")
    else:
        with open("/etc/systemd/system/phantom-vpn.service", "w", encoding="utf-8") as f:
            f.write(SYSTEMD_UNIT)
    run_cmd("ufw allow 3478/udp comment 'PhantomVPN' || true", dry_run=args.dry_run)
    run_cmd("systemctl daemon-reload", dry_run=args.dry_run)
    run_cmd("systemctl enable phantom-vpn", dry_run=args.dry_run)
    run_cmd("systemctl restart phantom-vpn", dry_run=args.dry_run)
    run_cmd("systemctl --no-pager --full status phantom-vpn", dry_run=args.dry_run)

    # 8. Print client quick-start
    print_step(f"Generating client config and quick-start for host '{args.client_host}'...")
    client_tun_addr = "10.7.0.2/24"
    client_toml = generate_client_toml(public_ip, keys)
    keyring_path = "/opt/phantom-vpn/config/clients.json"
    write_clients_keyring(
        keyring_path,
        args.client_host,
        keys,
        client_tun_addr,
        dry_run=args.dry_run,
    )

    print("\n" + "=" * 70)
    print(f"{Colors.GREEN}✅ CLEAN DEPLOY COMPLETED (server: {server_host}){Colors.RESET}")
    print("=" * 70)
    print(f"Server status check: {Colors.YELLOW}journalctl -fu phantom-vpn{Colors.RESET}")
    print(
        f"\nClient config for host '{args.client_host}' "
        "(save as /root/ghoststream/phantom-vpn/config/client.toml):\n"
    )
    print(f"{Colors.BLUE}{client_toml}{Colors.RESET}")
    print("=" * 70)
    print(f"Quick start on client host {args.client_host}:")
    print(
        f"""{Colors.YELLOW}ssh {args.client_host}
cd /root/ghoststream/phantom-vpn
cat > config/client.toml <<'EOF'
{client_toml}
EOF
source /root/.cargo/env
cargo build --release -p phantom-client-linux
pkill -x phantom-client-linux || true
ip link set tun0 down 2>/dev/null || true
ip tuntap del dev tun0 mode tun 2>/dev/null || true
./target/release/phantom-client-linux -c ./config/client.toml -vv{Colors.RESET}"""
    )
    print("\nIn a second client terminal:")
    print(
        f"{Colors.YELLOW}ping -c 3 10.7.0.1\nping -c 3 1.1.1.1\ncurl -4 https://ifconfig.me{Colors.RESET}"
    )
    print("=" * 70 + "\n")


if __name__ == "__main__":
    main()
