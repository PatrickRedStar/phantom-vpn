//! phantom-keygen: generates mTLS certificates for PhantomVPN.
//!
//! Generates:
//!   - CA cert/key  (ca.crt / ca.key)
//!   - Server cert/key signed by CA  (server.crt / server.key)
//!   - Client cert/key signed by CA  (client.crt / client.key)

use std::path::Path;

use anyhow::Context;
use clap::Parser;
use rcgen::{
    BasicConstraints, CertificateParams, DnType, IsCa, KeyPair, SanType,
};

#[derive(Parser, Debug)]
#[command(
    name  = "phantom-keygen",
    about = "PhantomVPN mTLS certificate generator"
)]
struct Args {
    /// Output directory for certificate files
    #[arg(short, long, default_value = ".")]
    out: String,

    /// Server hostname / IP SAN (used in server cert)
    #[arg(short, long, default_value = "phantom-vpn")]
    server_name: String,
}

fn main() -> anyhow::Result<()> {
    let raw: Vec<String> = std::env::args().collect();
    if raw.get(1).map(|s| s.as_str()) == Some("admin-grant") {
        return admin_grant_cmd(&raw[2..]);
    }
    let args = Args::parse();
    let out = Path::new(&args.out);

    std::fs::create_dir_all(out)
        .with_context(|| format!("Failed to create output directory: {}", args.out))?;

    // ─── CA cert ─────────────────────────────────────────────────────────────

    let ca_key = KeyPair::generate()?;
    let mut ca_params = CertificateParams::default();
    ca_params.distinguished_name.push(DnType::CommonName, "PhantomVPN CA");
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    // 10 years validity
    ca_params.not_after = time::OffsetDateTime::now_utc()
        + time::Duration::days(3650);
    let ca_cert = ca_params.self_signed(&ca_key)?;

    write_pem(out.join("ca.crt"), ca_cert.pem())?;
    write_pem(out.join("ca.key"), ca_key.serialize_pem())?;
    println!("CA:     {}/ca.crt  {}/ca.key", args.out, args.out);

    // ─── Server cert ─────────────────────────────────────────────────────────

    let server_key = KeyPair::generate()?;
    let mut srv_params = CertificateParams::default();
    srv_params.distinguished_name.push(DnType::CommonName, "PhantomVPN Server");
    srv_params.is_ca = IsCa::NoCa;
    srv_params.not_after = time::OffsetDateTime::now_utc()
        + time::Duration::days(3650);
    // Add DNS or IP SAN
    if let Ok(ip) = args.server_name.parse::<std::net::IpAddr>() {
        srv_params.subject_alt_names.push(SanType::IpAddress(ip));
    } else {
        srv_params.subject_alt_names.push(SanType::DnsName(args.server_name.clone().try_into()?));
    }
    let server_cert = srv_params.signed_by(&server_key, &ca_cert, &ca_key)?;

    write_pem(out.join("server.crt"), server_cert.pem())?;
    write_pem(out.join("server.key"), server_key.serialize_pem())?;
    println!("Server: {}/server.crt  {}/server.key", args.out, args.out);

    // ─── Client cert ─────────────────────────────────────────────────────────

    let client_key = KeyPair::generate()?;
    let mut cli_params = CertificateParams::default();
    cli_params.distinguished_name.push(DnType::CommonName, "PhantomVPN Client");
    cli_params.is_ca = IsCa::NoCa;
    cli_params.not_after = time::OffsetDateTime::now_utc()
        + time::Duration::days(3650);
    cli_params.subject_alt_names.push(SanType::DnsName("phantom-client".try_into()?));
    let client_cert = cli_params.signed_by(&client_key, &ca_cert, &ca_key)?;

    write_pem(out.join("client.crt"), client_cert.pem())?;
    write_pem(out.join("client.key"), client_key.serialize_pem())?;
    println!("Client: {}/client.crt  {}/client.key", args.out, args.out);

    println!("\nDone. Deploy:");
    println!("  Server: ca.crt + server.crt + server.key → /opt/phantom-vpn/config/");
    println!("  Client: ca.crt + client.crt + client.key → /etc/phantom-vpn/");
    println!("\nAdd to server.toml [quic]:");
    println!("  cert_path    = \"/opt/phantom-vpn/config/server.crt\"");
    println!("  key_path     = \"/opt/phantom-vpn/config/server.key\"");
    println!("  ca_cert_path = \"/opt/phantom-vpn/config/ca.crt\"");
    println!("\nAdd to client.toml [quic]:");
    println!("  cert_path    = \"/etc/phantom-vpn/client.crt\"");
    println!("  key_path     = \"/etc/phantom-vpn/client.key\"");
    println!("  ca_cert_path = \"/etc/phantom-vpn/ca.crt\"");

    Ok(())
}

fn write_pem(path: impl AsRef<Path>, pem: String) -> anyhow::Result<()> {
    std::fs::write(&path, pem)
        .with_context(|| format!("Failed to write {}", path.as_ref().display()))
}

fn admin_grant_cmd(args: &[String]) -> anyhow::Result<()> {
    // Usage: phantom-keygen admin-grant --name NAME [--enable|--disable]
    //        [--clients /opt/phantom-vpn/config/clients.json]
    let mut name: Option<String> = None;
    let mut enable: Option<bool> = None;
    let mut clients_path =
        "/opt/phantom-vpn/config/clients.json".to_string();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--name"    => { name = args.get(i + 1).cloned(); i += 2; }
            "--enable"  => { enable = Some(true);  i += 1; }
            "--disable" => { enable = Some(false); i += 1; }
            "--clients" => { clients_path = args.get(i + 1).cloned().unwrap_or(clients_path); i += 2; }
            "--help" | "-h" => {
                println!("Usage: phantom-keygen admin-grant --name NAME [--enable|--disable] [--clients PATH]");
                return Ok(());
            }
            other => anyhow::bail!("Unknown arg: {}", other),
        }
    }
    let name = name.context("--name required")?;
    let enable = enable.unwrap_or(true);

    let content = std::fs::read_to_string(&clients_path)
        .with_context(|| format!("read {}", clients_path))?;
    let mut root: serde_json::Value = serde_json::from_str(&content)
        .with_context(|| format!("parse {}", clients_path))?;
    let clients = root.get_mut("clients").and_then(|c| c.as_object_mut())
        .context("'clients' object missing in keyring")?;
    let entry = clients.get_mut(&name)
        .with_context(|| format!("client '{}' not found", name))?;
    let obj = entry.as_object_mut().context("malformed client entry")?;
    obj.insert("is_admin".to_string(), serde_json::Value::Bool(enable));

    let tmp = format!("{}.tmp", clients_path);
    std::fs::write(&tmp, serde_json::to_string_pretty(&root)?)
        .with_context(|| format!("write {}", tmp))?;
    std::fs::rename(&tmp, &clients_path)
        .with_context(|| format!("rename {} -> {}", tmp, clients_path))?;
    println!("{}: is_admin = {}", name, enable);
    Ok(())
}
