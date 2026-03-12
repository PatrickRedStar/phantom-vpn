#!/usr/bin/env python3
import os
import subprocess
import sys
import shutil

class Colors:
    GREEN = '\033[92m'
    BLUE = '\033[94m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    RESET = '\033[0m'

def print_step(msg):
    print(f"\n{Colors.BLUE}==>{Colors.RESET} {Colors.GREEN}{msg}{Colors.RESET}")

def run_cmd(cmd, suppress_output=False):
    try:
        if suppress_output:
            subprocess.run(cmd, shell=True, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.run(cmd, shell=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"{Colors.RED}Command failed: {cmd}{Colors.RESET}")
        sys.exit(1)

def main():
    if os.geteuid() != 0:
        print(f"{Colors.RED}This script must be run as root! (sudo ./scripts/install.py){Colors.RESET}")
        sys.exit(1)

    print(f"{Colors.BLUE}=== PhantomVPN Auto-Installer ==={Colors.RESET}")

    # 1. Install dependencies
    print_step("Installing system dependencies...")
    run_cmd("apt-get update -qq")
    run_cmd("apt-get install -y -qq curl build-essential pkg-config iproute2 iptables clang llvm libelf-dev")
    run_cmd("apt-get install -y -qq linux-headers-$(uname -r) || apt-get install -y -qq linux-headers-generic")

    # 2. Install Rust
    print_step("Checking Rust installation...")
    if not shutil.which("cargo"):
        print("Installing Rust (minimal profile)...")
        run_cmd("curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable")
        os.environ["PATH"] += f":{os.environ.get('HOME', '/root')}/.cargo/bin"
    else:
        print("Rust is already installed.")

    # 3. Build server and keygen
    print_step("Building phantom-server and phantom-keygen...")
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    os.chdir(repo_root)
    run_cmd("cargo build --release -p phantom-server")
    run_cmd("cargo build --release -p phantom-server --bin phantom-keygen")

    # 4. Generate keys
    print_step("Generating VPN keys...")
    keygen_output = subprocess.check_output(["./target/release/phantom-keygen"], text=True)
    
    server_priv = ""
    server_pub = ""
    client_priv = ""
    client_pub = ""
    shared_secret = ""

    lines = keygen_output.splitlines()
    for line in lines:
        line = line.strip()
        if "=" not in line:
            continue
            
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip().strip('"')

        if key == "server_private_key":
            server_priv = val
        elif key == "server_public_key":
            server_pub = val
        elif key == "client_private_key":
            client_priv = val
        elif key == "client_public_key":
            client_pub = val
        elif key == "shared_secret":
            shared_secret = val

    # Get public IP
    public_ip = subprocess.check_output(["curl", "-s", "https://ifconfig.me"], text=True).strip()
    
    # Get primary interface
    primary_iface = subprocess.check_output("ip route | grep default | awk '{print $5}' | head -n 1", shell=True, text=True).strip()
    if not primary_iface:
        primary_iface = "eth0"

    # 5. Create Server Config
    print_step("Creating server configuration...")
    os.makedirs("/opt/phantom-vpn/config", exist_ok=True)
    
    server_toml = f"""[network]
listen_addr = "0.0.0.0:3478"
tun_name    = "tun0"
tun_addr    = "10.7.0.1/24"
tun_mtu     = 1380
wan_iface   = "{primary_iface}"

[keys]
server_private_key = "{server_priv}"
server_public_key  = "{server_pub}"
shared_secret      = "{shared_secret}"

[timeouts]
idle_timeout_secs  = 300
hard_timeout_secs  = 86400
"""
    with open("/opt/phantom-vpn/config/server.toml", "w") as f:
        f.write(server_toml)

    # 6. Install binaries
    print_step("Installing binaries to /opt/phantom-vpn...")
    shutil.copy("target/release/phantom-server", "/opt/phantom-vpn/")

    # 7. Create systemd service
    print_step("Configuring systemd service...")
    systemd_unit = """[Unit]
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
    with open("/etc/systemd/system/phantom-vpn.service", "w") as f:
        f.write(systemd_unit)

    run_cmd("systemctl daemon-reload")
    run_cmd("systemctl enable phantom-vpn")
    run_cmd("systemctl restart phantom-vpn")

    print_step("Server deployed and started successfully!")
    print(f"Check logs with: {Colors.YELLOW}journalctl -fu phantom-vpn{Colors.RESET}")

    # 8. Generate Client Config
    client_toml = f"""[network]
server_addr = "{public_ip}:3478"
tun_name    = "tun0"
tun_addr    = "10.7.0.2/24"
tun_mtu     = 1380
default_gw  = "10.7.0.1"

[keys]
client_private_key = "{client_priv}"
client_public_key  = "{client_pub}"
server_public_key  = "{server_pub}"
shared_secret      = "{shared_secret}"
"""
    
    print("\n" + "="*60)
    print(f"{Colors.GREEN}✅ INSTALLED SUCCESSFULLY!{Colors.RESET}")
    print("="*60)
    print("Copy the following configuration and save it as config/client.toml on your local PC (Mac/Linux):\n")
    print(f"{Colors.BLUE}{client_toml}{Colors.RESET}")
    print("="*60)
    print("To run the client on your PC (Linux or macOS):")
    print(f"\n{Colors.BLUE}For Linux:{Colors.RESET}")
    print(f"{Colors.YELLOW}sudo cargo run --release -p phantom-client-linux -- -c config/client.toml -vv{Colors.RESET}")
    print(f"\n{Colors.BLUE}For macOS:{Colors.RESET}")
    print(f"{Colors.YELLOW}sudo cargo run --release -p phantom-client-macos -- -c config/client.toml -vv{Colors.RESET}")
    print("="*60 + "\n")

if __name__ == "__main__":
    main()
