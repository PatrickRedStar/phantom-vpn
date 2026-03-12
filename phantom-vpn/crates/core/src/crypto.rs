//! Криптографический уровень: Noise_IK + ChaCha20-Poly1305.
//! Noise_IK — 0-RTT: клиент знает публичный ключ сервера заранее.

use crate::error::CryptoError;
use snow::{Builder, HandshakeState, TransportState};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

pub const NOISE_PATTERN: &str = "Noise_IK_25519_ChaChaPoly_BLAKE2s";
/// Максимум байт через одну Noise-сессию до ротации ключей
pub const REKEY_BYTES: u64 = 100 * 1024 * 1024; // 100 МБ
/// Максимальное время жизни сессии без ротации
pub const REKEY_SECS: u64 = 600; // 10 минут

// ─── Ключевые пары ──────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct KeyPair {
    pub private: Vec<u8>, // 32 байта
    pub public:  Vec<u8>, // 32 байта
}

impl KeyPair {
    /// Генерирует новую ключевую пару Curve25519
    pub fn generate() -> Result<Self, CryptoError> {
        let builder = Builder::new(NOISE_PATTERN.parse().map_err(|_| CryptoError::Hmac)?);
        let pair = builder.generate_keypair().map_err(CryptoError::Noise)?;
        Ok(KeyPair {
            private: pair.private,
            public:  pair.public,
        })
    }

    pub fn public_bytes(&self) -> [u8; 32] {
        let mut arr = [0u8; 32];
        arr.copy_from_slice(&self.public);
        arr
    }
}

// ─── Состояние Noise сессии ─────────────────────────────────────────────────

pub struct NoiseHandshake {
    state: HandshakeState,
}

impl NoiseHandshake {
    /// Инициатор (клиент): знает публичный ключ сервера
    pub fn initiate(
        client_keys: &KeyPair,
        server_public: &[u8; 32],
    ) -> Result<(Self, Vec<u8>), CryptoError> {
        let builder = Builder::new(NOISE_PATTERN.parse().map_err(|_| CryptoError::Hmac)?);
        let mut state = builder
            .local_private_key(&client_keys.private)
            .remote_public_key(server_public.as_ref())
            .build_initiator()
            .map_err(CryptoError::Noise)?;

        // 0-RTT: первое сообщение (-> e, es, s, ss) без payload (payload в transport mode)
        let mut msg = vec![0u8; 1024];
        let len = state.write_message(&[], &mut msg).map_err(CryptoError::Noise)?;
        msg.truncate(len);
        Ok((NoiseHandshake { state }, msg))
    }

    /// Responder (сервер): отвечает на инициацию
    pub fn respond(server_keys: &KeyPair) -> Result<Self, CryptoError> {
        let builder = Builder::new(NOISE_PATTERN.parse().map_err(|_| CryptoError::Hmac)?);
        let state = builder
            .local_private_key(&server_keys.private)
            .build_responder()
            .map_err(CryptoError::Noise)?;
        Ok(NoiseHandshake { state })
    }

    /// Сервер: принимает первое сообщение клиента
    pub fn read_initiator_message(&mut self, msg: &[u8]) -> Result<Vec<u8>, CryptoError> {
        let mut payload = vec![0u8; 1024];
        let len = self.state.read_message(msg, &mut payload).map_err(CryptoError::Noise)?;
        payload.truncate(len);
        Ok(payload)
    }

    /// Сервер: формирует ответ (<- e, ee, se)
    pub fn write_response(&mut self) -> Result<Vec<u8>, CryptoError> {
        let mut msg = vec![0u8; 1024];
        let len = self.state.write_message(&[], &mut msg).map_err(CryptoError::Noise)?;
        msg.truncate(len);
        Ok(msg)
    }

    /// Клиент: принимает ответ сервера
    pub fn read_response(&mut self, msg: &[u8]) -> Result<(), CryptoError> {
        let mut buf = vec![0u8; 1024];
        self.state.read_message(msg, &mut buf).map_err(CryptoError::Noise)?;
        Ok(())
    }

    /// Переходит в transport mode (шифрование/расшифровка данных)
    pub fn into_transport(self) -> Result<NoiseSession, CryptoError> {
        let transport = self.state.into_transport_mode().map_err(CryptoError::Noise)?;
        Ok(NoiseSession::new(transport))
    }
}

// ─── Транспортная сессия ─────────────────────────────────────────────────────

pub struct NoiseSession {
    transport:   TransportState,
    bytes_sent:  AtomicU64,
    bytes_recv:  AtomicU64,
    created_at:  Instant,
}

impl NoiseSession {
    fn new(transport: TransportState) -> Self {
        Self {
            transport,
            bytes_sent:  AtomicU64::new(0),
            bytes_recv:  AtomicU64::new(0),
            created_at:  Instant::now(),
        }
    }

    /// Шифрует plaintext в out, возвращает длину зашифрованного сообщения
    pub fn encrypt(&mut self, plaintext: &[u8], out: &mut [u8]) -> Result<usize, CryptoError> {
        let len = self.transport
            .write_message(plaintext, out)
            .map_err(CryptoError::Noise)?;
        self.bytes_sent.fetch_add(len as u64, Ordering::Relaxed);
        Ok(len)
    }

    /// Расшифровывает ciphertext в out, возвращает длину plaintext
    pub fn decrypt(&mut self, ciphertext: &[u8], out: &mut [u8]) -> Result<usize, CryptoError> {
        let len = self.transport
            .read_message(ciphertext, out)
            .map_err(CryptoError::Noise)?;
        self.bytes_recv.fetch_add(ciphertext.len() as u64, Ordering::Relaxed);
        Ok(len)
    }

    /// Проверяет, нужна ли ротация ключей
    pub fn needs_rekey(&self) -> bool {
        let total = self.bytes_sent.load(Ordering::Relaxed)
            + self.bytes_recv.load(Ordering::Relaxed);
        total >= REKEY_BYTES || self.created_at.elapsed().as_secs() >= REKEY_SECS
    }

    pub fn bytes_total(&self) -> u64 {
        self.bytes_sent.load(Ordering::Relaxed) + self.bytes_recv.load(Ordering::Relaxed)
    }
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_noise_ik_full_handshake() {
        let client_keys = KeyPair::generate().unwrap();
        let server_keys = KeyPair::generate().unwrap();
        let server_pub = server_keys.public_bytes();

        // Клиент инициирует
        let (mut client_hs, msg1) = NoiseHandshake::initiate(&client_keys, &server_pub).unwrap();
        // Сервер отвечает
        let mut server_hs = NoiseHandshake::respond(&server_keys).unwrap();
        server_hs.read_initiator_message(&msg1).unwrap();
        let msg2 = server_hs.write_response().unwrap();
        // Клиент принимает ответ
        client_hs.read_response(&msg2).unwrap();
        // Оба переходят в transport mode
        let mut client_session = client_hs.into_transport().unwrap();
        let mut server_session = server_hs.into_transport().unwrap();

        // Клиент -> Сервер
        let plaintext = b"Hello, World! This is a test payload.";
        let mut ciphertext = vec![0u8; plaintext.len() + 100];
        let ct_len = client_session.encrypt(plaintext, &mut ciphertext).unwrap();
        let mut decrypted = vec![0u8; plaintext.len() + 100];
        let pt_len = server_session.decrypt(&ciphertext[..ct_len], &mut decrypted).unwrap();
        assert_eq!(&decrypted[..pt_len], plaintext.as_ref());

        // Сервер -> Клиент
        let reply = b"Server reply data 12345";
        let mut ct2 = vec![0u8; reply.len() + 100];
        let ct2_len = server_session.encrypt(reply, &mut ct2).unwrap();
        let mut dec2 = vec![0u8; reply.len() + 100];
        let pt2_len = client_session.decrypt(&ct2[..ct2_len], &mut dec2).unwrap();
        assert_eq!(&dec2[..pt2_len], reply.as_ref());
    }

    #[test]
    fn test_rekey_detection() {
        // Тест логики обнаружения необходимости ротации ключей
        let client_keys = KeyPair::generate().unwrap();
        let server_keys = KeyPair::generate().unwrap();
        let server_pub = server_keys.public_bytes();
        let (mut client_hs, msg1) = NoiseHandshake::initiate(&client_keys, &server_pub).unwrap();
        let mut server_hs = NoiseHandshake::respond(&server_keys).unwrap();
        server_hs.read_initiator_message(&msg1).unwrap();
        let msg2 = server_hs.write_response().unwrap();
        client_hs.read_response(&msg2).unwrap();
        let session = client_hs.into_transport().unwrap();
        // Новая сессия не нуждается в rekey
        assert!(!session.needs_rekey());
    }
}
