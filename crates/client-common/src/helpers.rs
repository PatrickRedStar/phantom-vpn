//! Общие хелперы клиента: загрузка конфига, ключей, connection string.

use std::path::Path;
use anyhow::Context;

use phantom_core::config::{ClientConfig, ClientNetworkConfig, TlsConfig};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};

// ─── CLI Args ────────────────────────────────────────────────────────────────

#[derive(clap::Parser, Debug)]
#[command(
    name  = "phantom-client",
    about = "PhantomVPN client — WebRTC/SRTP masquerade VPN"
)]
pub struct Args {
    /// Path to TOML config file
    #[arg(short, long, default_value = "config/client.toml")]
    pub config: String,

    /// Override server address (e.g. 1.2.3.4:3478)
    #[arg(short, long)]
    pub server: Option<String>,

    /// Base64url connection string (overrides config file)
    #[arg(long)]
    pub conn_string: Option<String>,

    /// File containing base64url connection string
    #[arg(long)]
    pub conn_string_file: Option<String>,

    /// Verbose logging
    #[arg(short, long, action = clap::ArgAction::Count)]
    pub verbose: u8,
}

// ─── Init logging ────────────────────────────────────────────────────────────

pub fn init_logging(verbose: u8) {
    let level = match verbose {
        0 => tracing::Level::INFO,
        1 => tracing::Level::DEBUG,
        _ => tracing::Level::TRACE,
    };
    tracing_subscriber::fmt()
        .with_max_level(level)
        .with_target(false)
        .compact()
        .init();
}

// ─── Load config ─────────────────────────────────────────────────────────────

pub fn load_config(path: &str) -> anyhow::Result<ClientConfig> {
    if std::path::Path::new(path).exists() {
        ClientConfig::from_file(path)
            .with_context(|| format!("Failed to load config: {}", path))
    } else {
        tracing::warn!("Config file not found ({}), using defaults", path);
        Ok(ClientConfig::default())
    }
}

// ─── Connection string ──────────────────────────────────────────────────────

/// New connection string format (v0.19+):
/// `ghs://<base64url(cert_pem + "\n" + key_pem)>@<host>:<port>?sni=<sni>&tun=<cidr>&v=1`
///
/// Legacy base64-JSON formats are rejected.
fn url_decode(input: &str) -> anyhow::Result<String> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => { out.push(b' '); i += 1; }
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i+1..i+3])
                    .map_err(|_| anyhow::anyhow!("invalid percent-encoding"))?;
                let v = u8::from_str_radix(hex, 16)
                    .map_err(|_| anyhow::anyhow!("invalid percent-encoding: %{}", hex))?;
                out.push(v);
                i += 3;
            }
            b => { out.push(b); i += 1; }
        }
    }
    String::from_utf8(out).context("URL-decoded value is not valid UTF-8")
}

pub fn parse_conn_string(input: &str) -> anyhow::Result<ClientConfig> {
    let trimmed = input.trim();

    let rest = trimmed.strip_prefix("ghs://")
        .ok_or_else(|| anyhow::anyhow!(
            "Unsupported conn_string format: expected 'ghs://…'. \
             Regenerate connection link via the bot."))?;

    // userinfo@authority?query
    let (userinfo, after_at) = rest.split_once('@')
        .ok_or_else(|| anyhow::anyhow!("Malformed ghs:// URL: missing '@'"))?;
    let (authority, query) = after_at.split_once('?')
        .ok_or_else(|| anyhow::anyhow!("Malformed ghs:// URL: missing query string"))?;

    if userinfo.is_empty() {
        anyhow::bail!("Malformed ghs:// URL: empty userinfo");
    }
    if authority.is_empty() {
        anyhow::bail!("Malformed ghs:// URL: empty host:port");
    }

    // Decode userinfo = base64url(cert_pem + "\n" + key_pem)
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    let pem_bytes = URL_SAFE_NO_PAD.decode(userinfo.as_bytes())
        .context("Invalid base64url userinfo in ghs:// URL")?;
    let pem_str = String::from_utf8(pem_bytes)
        .context("Userinfo is not valid UTF-8 after base64url decode")?;

    // Split on -----BEGIN marker: expect exactly two PEM blocks (cert + key)
    let mut begin_positions: Vec<usize> = pem_str.match_indices("-----BEGIN").map(|(i, _)| i).collect();
    if begin_positions.len() != 2 {
        anyhow::bail!(
            "Expected 2 PEM blocks in userinfo (cert + key), found {}",
            begin_positions.len()
        );
    }
    begin_positions.push(pem_str.len());
    let first  = pem_str[begin_positions[0]..begin_positions[1]].trim().to_string();
    let second = pem_str[begin_positions[1]..begin_positions[2]].trim().to_string();
    let (cert_pem, key_pem) = if first.contains("CERTIFICATE") {
        (first, second)
    } else {
        (second, first)
    };
    if !cert_pem.contains("CERTIFICATE") {
        anyhow::bail!("No CERTIFICATE PEM block found in userinfo");
    }
    if !key_pem.contains("PRIVATE KEY") {
        anyhow::bail!("No PRIVATE KEY PEM block found in userinfo");
    }

    // Parse query
    let mut sni: Option<String> = None;
    let mut tun: Option<String> = None;
    let mut version: Option<String> = None;
    for pair in query.split('&') {
        if pair.is_empty() { continue; }
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        let v = url_decode(v)?;
        match k {
            "sni"       => sni = Some(v),
            "tun"       => tun = Some(v),
            "v"         => version = Some(v),
            _           => {} // forward-compat: ignore unknown params (e.g. legacy "transport")
        }
    }

    let sni = sni.ok_or_else(|| anyhow::anyhow!("Missing 'sni' query param"))?;
    let tun = tun.ok_or_else(|| anyhow::anyhow!("Missing 'tun' query param"))?;
    if version.as_deref() != Some("1") {
        anyhow::bail!("Unsupported ghs:// version: {:?}", version);
    }

    let tls_cfg = TlsConfig {
        cert_pem: Some(cert_pem),
        key_pem:  Some(key_pem),
        ..Default::default()
    };

    let default_gw = tun.split('/').next()
        .and_then(|ip| {
            let parts: Vec<&str> = ip.split('.').collect();
            if parts.len() == 4 {
                Some(format!("{}.{}.{}.1", parts[0], parts[1], parts[2]))
            } else {
                None
            }
        });

    Ok(ClientConfig {
        network: ClientNetworkConfig {
            server_addr: authority.to_string(),
            server_name: Some(sni),
            insecure: false,
            tun_name: None,
            tun_addr: Some(tun),
            tun_mtu: Some(1350),
            default_gw,
        },
        keys: None,
        shaper: None,
        tls: Some(tls_cfg),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};

    fn sample_pem() -> String {
        "-----BEGIN CERTIFICATE-----\nMIIBcert\n-----END CERTIFICATE-----\n\
         -----BEGIN PRIVATE KEY-----\nMIIBkey\n-----END PRIVATE KEY-----\n".to_string()
    }

    #[test]
    fn parses_ghs_url() {
        let enc = URL_SAFE_NO_PAD.encode(sample_pem().as_bytes());
        let s = format!("ghs://{}@1.2.3.4:443?sni=tls.example.com&tun=10.7.0.5%2F24&v=1", enc);
        let cfg = parse_conn_string(&s).expect("parse");
        assert_eq!(cfg.network.server_addr, "1.2.3.4:443");
        assert_eq!(cfg.network.server_name.as_deref(), Some("tls.example.com"));
        assert_eq!(cfg.network.tun_addr.as_deref(), Some("10.7.0.5/24"));
        assert_eq!(cfg.network.default_gw.as_deref(), Some("10.7.0.1"));
    }

    #[test]
    fn rejects_legacy_base64_json() {
        let legacy = URL_SAFE_NO_PAD.encode(b"{\"addr\":\"x\"}");
        let err = parse_conn_string(&legacy).unwrap_err().to_string();
        assert!(err.contains("Unsupported conn_string format"), "got: {}", err);
    }

    #[test]
    fn rejects_missing_tun() {
        let enc = URL_SAFE_NO_PAD.encode(sample_pem().as_bytes());
        let s = format!("ghs://{}@1.2.3.4:443?sni=x&v=1", enc);
        assert!(parse_conn_string(&s).is_err());
    }
}

/// Load connection string from CLI args (--conn-string or --conn-string-file).
/// Returns None if neither is set.
pub fn load_conn_string(args: &Args) -> anyhow::Result<Option<ClientConfig>> {
    if let Some(ref cs) = args.conn_string {
        return Ok(Some(parse_conn_string(cs)?));
    }
    if let Some(ref path) = args.conn_string_file {
        let content = std::fs::read_to_string(path)
            .with_context(|| format!("Failed to read conn-string file: {}", path))?;
        return Ok(Some(parse_conn_string(&content)?));
    }
    Ok(None)
}

// ─── TLS identity loading ───────────────────────────────────────────────────

/// Load client TLS identity (cert + key) from config.
/// Checks inline PEM first, then file paths.
pub fn load_tls_identity(
    cfg: &ClientConfig,
) -> anyhow::Result<Option<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)>> {
    if let Some(ref tc) = cfg.tls {
        // Inline PEM has priority
        if let (Some(ref cert_pem), Some(ref key_pem)) = (&tc.cert_pem, &tc.key_pem) {
            tracing::info!("Loading client TLS certificate from inline PEM");
            let identity = phantom_core::tls::parse_pem_identity(
                cert_pem.as_bytes(), key_pem.as_bytes(),
            ).context("Failed to parse inline client TLS certificate")?;
            return Ok(Some(identity));
        }
        // Fallback to file paths
        if let (Some(ref cp), Some(ref kp)) = (&tc.cert_path, &tc.key_path) {
            tracing::info!("Loading client TLS certificate from {}", cp);
            let identity = phantom_core::tls::load_pem_certs(Path::new(cp), Path::new(kp))
                .context("Failed to load client TLS certificate")?;
            return Ok(Some(identity));
        }
    }
    Ok(None)
}

/// Load server CA cert from config.
/// Checks inline PEM first, then file path.
pub fn load_server_ca(
    cfg: &ClientConfig,
) -> anyhow::Result<Option<Vec<CertificateDer<'static>>>> {
    if let Some(ref tc) = cfg.tls {
        // Inline PEM has priority
        if let Some(ref ca_pem) = tc.ca_cert_pem {
            tracing::info!("Loading server CA cert from inline PEM");
            let certs = phantom_core::tls::parse_pem_cert_chain(ca_pem.as_bytes())
                .context("Failed to parse inline CA cert")?;
            return Ok(Some(certs));
        }
        // Fallback to file path
        if let Some(ref ca_path) = tc.ca_cert_path {
            let certs = phantom_core::tls::load_pem_cert_chain(Path::new(ca_path))
                .context("Failed to load server CA cert")?;
            return Ok(Some(certs));
        }
    }
    Ok(None)
}

