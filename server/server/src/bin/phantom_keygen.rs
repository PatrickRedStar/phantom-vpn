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

    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(out)
            .with_context(|| format!("Failed to create output directory: {}", args.out))?;
    }

    // ─── CA cert ─────────────────────────────────────────────────────────────

    // Neutral names: the CA's name can surface in TLS handshakes, so it must
    // not name the product. Existing installations keep their CA — files are
    // never overwritten (see write_pem).
    let ca_key = KeyPair::generate()?;
    let mut ca_params = CertificateParams::default();
    ca_params.distinguished_name.push(DnType::CommonName, "Root CA");
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    // 10 years validity
    ca_params.not_after = time::OffsetDateTime::now_utc()
        + time::Duration::days(3650);
    let ca_cert = ca_params.self_signed(&ca_key)?;

    write_pem(out.join("ca.crt"), ca_cert.pem(), 0o644)?;
    write_pem(out.join("ca.key"), ca_key.serialize_pem(), 0o600)?;
    println!("CA:     {}/ca.crt  {}/ca.key", args.out, args.out);

    // ─── Server cert ─────────────────────────────────────────────────────────

    let server_key = KeyPair::generate()?;
    let mut srv_params = CertificateParams::default();
    srv_params.distinguished_name.push(DnType::CommonName, args.server_name.clone());
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

    write_pem(out.join("server.crt"), server_cert.pem(), 0o644)?;
    write_pem(out.join("server.key"), server_key.serialize_pem(), 0o600)?;
    println!("Server: {}/server.crt  {}/server.key", args.out, args.out);

    // ─── Client cert ─────────────────────────────────────────────────────────

    let client_key = KeyPair::generate()?;
    let mut cli_params = CertificateParams::default();
    cli_params.distinguished_name.push(DnType::CommonName, "client");
    cli_params.is_ca = IsCa::NoCa;
    cli_params.not_after = time::OffsetDateTime::now_utc()
        + time::Duration::days(3650);
    cli_params.subject_alt_names.push(SanType::DnsName("phantom-client".try_into()?));
    let client_cert = cli_params.signed_by(&client_key, &ca_cert, &ca_key)?;

    write_pem(out.join("client.crt"), client_cert.pem(), 0o644)?;
    write_pem(out.join("client.key"), client_key.serialize_pem(), 0o600)?;
    println!("Client: {}/client.crt  {}/client.key", args.out, args.out);

    println!("\nDone. Deploy:");
    println!("  Server: ca.crt + server.crt + server.key → /opt/phantom-vpn/config/");
    println!("  Client: ca.crt + client.crt + client.key → /etc/phantom-vpn/");
    println!("\nAdd to server.toml [tls]:");
    println!("  cert_path    = \"/opt/phantom-vpn/config/server.crt\"");
    println!("  key_path     = \"/opt/phantom-vpn/config/server.key\"");
    println!("  ca_cert_path = \"/opt/phantom-vpn/config/ca.crt\"");
    println!("\nAdd to client.toml [tls]:");
    println!("  cert_path    = \"/etc/phantom-vpn/client.crt\"");
    println!("  key_path     = \"/etc/phantom-vpn/client.key\"");
    println!("  ca_cert_path = \"/etc/phantom-vpn/ca.crt\"");

    Ok(())
}

/// Creates the file with `mode`; refuses to overwrite an existing one, so a
/// re-run can't replace a live CA and lock every client out.
fn write_pem(path: impl AsRef<Path>, pem: String, mode: u32) -> anyhow::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let path = path.as_ref();
    let mut f = std::fs::OpenOptions::new()
        .write(true).create_new(true).mode(mode)
        .open(path)
        .with_context(|| format!("Failed to create {} (already exists?)", path.display()))?;
    f.write_all(pem.as_bytes())
        .with_context(|| format!("Failed to write {}", path.display()))
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
