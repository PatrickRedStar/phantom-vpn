//! phantom-keygen binary entry point.

use phantom_core::crypto::KeyPair;
use base64::{Engine, engine::general_purpose::STANDARD};
use rand::RngCore;

fn main() -> anyhow::Result<()> {
    println!("# PhantomVPN Key Generator");
    println!("# Generated keys — copy into server.toml and client.toml\n");

    let server_keys = KeyPair::generate()?;
    let client_keys = KeyPair::generate()?;

    let mut shared_secret = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut shared_secret);

    println!("# ─── SERVER CONFIG (config/server.toml) ────────────────────────────");
    println!("[keys]");
    println!("server_private_key = \"{}\"", STANDARD.encode(&server_keys.private));
    println!("server_public_key  = \"{}\"", STANDARD.encode(&server_keys.public));
    println!("shared_secret      = \"{}\"", STANDARD.encode(&shared_secret));
    println!();

    println!("# ─── CLIENT CONFIG (config/client.toml) ────────────────────────────");
    println!("[keys]");
    println!("client_private_key = \"{}\"", STANDARD.encode(&client_keys.private));
    println!("client_public_key  = \"{}\"", STANDARD.encode(&client_keys.public));
    println!("server_public_key  = \"{}\"", STANDARD.encode(&server_keys.public));
    println!("shared_secret      = \"{}\"", STANDARD.encode(&shared_secret));
    println!();

    println!("# ─── KEY FINGERPRINTS ──────────────────────────────────────────────");
    println!("# Server public:  {}", hex::encode(&server_keys.public));
    println!("# Client public:  {}", hex::encode(&client_keys.public));
    println!("# Shared secret:  {}", hex::encode(&shared_secret));

    Ok(())
}
