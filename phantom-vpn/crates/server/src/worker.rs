//! Серверный worker: приём UDP → расшифровка → TUN; TUN → шифровка → UDP.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;

use tokio::net::UdpSocket;
use tokio::sync::{Mutex, mpsc};
use tokio::io::AsyncWriteExt;

use phantom_core::{
    crypto::{KeyPair, NoiseHandshake},
    mtu::clamp_tcp_mss,
    wire::{build_plaintext, extract_ip_packet, SrtpHeader, SRTP_HEADER_LEN, TUNNEL_MSS},
};

use crate::sessions::SessionMap;

// ─── Буферы ─────────────────────────────────────────────────────────────────

const BUF_SIZE: usize = 65536;

// ─── Handshake state tracker ─────────────────────────────────────────────────

/// Отслеживает незавершённые хэндшейки (до перехода в transport mode)
pub struct PendingHandshake {
    pub state: NoiseHandshake,
    pub client_addr: SocketAddr,
    pub expected_ssrc: u32,
}

// ─── Главный RX loop ────────────────────────────────────────────────────────

pub async fn rx_loop(
    socket:       Arc<UdpSocket>,
    tun_tx:       mpsc::Sender<Vec<u8>>,      // канал → tun writer
    sessions:     SessionMap,
    server_keys:  Arc<KeyPair>,
    shared_secret: Arc<[u8; 32]>,
) -> anyhow::Result<()> {
    let mut buf = vec![0u8; BUF_SIZE];
    let mut decrypt_buf = vec![0u8; BUF_SIZE];
    // Pending handshakes: addr -> PendingHandshake
    let mut pending: HashMap<SocketAddr, NoiseHandshake> = HashMap::new();

    tracing::info!("RX loop started");

    loop {
        let (len, src_addr) = match socket.recv_from(&mut buf).await {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!("recv_from error: {}", e);
                continue;
            }
        };
        let pkt = &buf[..len];
        tracing::trace!("UDP recv {} bytes from {}", len, src_addr);

        // Минимальная длина: SRTP header
        if pkt.len() < SRTP_HEADER_LEN {
            tracing::trace!("drop: too short ({} bytes) from {}", len, src_addr);
            continue;
        }

        let hdr = match SrtpHeader::parse(pkt) {
            Ok(h) => h,
            Err(e) => {
                tracing::trace!("drop: bad SRTP header from {}: {}", src_addr, e);
                continue;
            }
        };

        let payload = &pkt[SRTP_HEADER_LEN..];

        // Проверяем: есть ли уже активная сессия для этого SSRC?
        if let Some(session_ref) = sessions.get(&hdr.ssrc) {
            let session_arc = session_ref.value().clone();
            drop(session_ref);

            // Активная сессия — расшифровываем
            let mut session = session_arc.lock().await;

            // При смене UDP source (NAT rebinding/restart клиента) старая сессия невалидна.
            // Удаляем её и пробуем текущий пакет как новый handshake init.
            if session.client_addr != src_addr {
                let old_addr = session.client_addr;
                drop(session);
                sessions.remove(&hdr.ssrc);

                tracing::info!(
                    "session addr changed for ssrc={:#010x}: {} -> {}, resetting session",
                    hdr.ssrc,
                    old_addr,
                    src_addr
                );

                match try_handshake_respond(
                    payload,
                    src_addr,
                    hdr.ssrc,
                    &server_keys,
                    &shared_secret,
                    &socket,
                    &sessions,
                )
                .await
                {
                    Ok(()) => {
                        tracing::info!(
                            "Handshake completed after addr change for {} (ssrc={:#010x})",
                            src_addr,
                            hdr.ssrc
                        );
                    }
                    Err(e) => {
                        tracing::trace!("Handshake failed after addr change from {}: {}", src_addr, e);
                    }
                }
                continue;
            }
            session.touch();

            // Replay check
            let nonce = session.recv_nonce.reconstruct(hdr.seq_num);
            if let Err(e) = session.replay_win.check_and_update(nonce) {
                tracing::trace!("replay drop from {}: {}", src_addr, e);
                continue;
            }

            // Расшифровка (Noise transport mode)
            let pt_len = match session.noise.decrypt(nonce, payload, &mut decrypt_buf) {
                Ok(n) => n,
                Err(e) => {
                    tracing::trace!("decrypt failed from {}: {}", src_addr, e);
                    continue; // Blackhole — не отвечаем
                }
            };

            tracing::debug!("Decrypted {} bytes from {} (ssrc={:#010x})", pt_len, src_addr, hdr.ssrc);

            // Извлекаем IP пакет из plaintext
            let ip_data = match extract_ip_packet(&decrypt_buf[..pt_len]) {
                Ok(d) => d.to_vec(),
                Err(e) => {
                    tracing::debug!("extract_ip failed (pt_len={}): {}", pt_len, e);
                    continue;
                }
            };

            tracing::debug!("IP packet: {} bytes, proto={}, dst={}.{}.{}.{}",
                ip_data.len(),
                if ip_data.len() > 9 { ip_data[9] } else { 0 },
                if ip_data.len() > 19 { ip_data[16] } else { 0 },
                if ip_data.len() > 19 { ip_data[17] } else { 0 },
                if ip_data.len() > 19 { ip_data[18] } else { 0 },
                if ip_data.len() > 19 { ip_data[19] } else { 0 }
            );

            // MSS clamping на входящем пакете
            let mut ip_buf = ip_data;
            let _ = clamp_tcp_mss(&mut ip_buf, TUNNEL_MSS);

            // Отправляем в TUN
            if let Err(e) = tun_tx.send(ip_buf.clone()).await {
                tracing::error!("tun_tx send error: {}", e);
            } else {
                tracing::debug!("Sent {} bytes to TUN", ip_buf.len());
            }

        } else {
            // Неизвестный SSRC — пробуем как Noise handshake message
            // Проверяем: может это первый пакет хэндшейка от нового клиента?
            tracing::debug!("unknown SSRC {:#010x} from {} — trying handshake", hdr.ssrc, src_addr);

            // Noise IK responder
            match try_handshake_respond(
                payload, src_addr, hdr.ssrc,
                &server_keys, &shared_secret,
                &socket, &sessions
            ).await {
                Ok(()) => {
                    tracing::info!("Handshake completed for {} (ssrc={:#010x})", src_addr, hdr.ssrc);
                }
                Err(e) => {
                    tracing::trace!("Handshake failed from {}: {}", src_addr, e);
                    // Blackhole — не отвечаем на неизвестные пакеты
                }
            }
        }
    }
}

/// Обрабатывает первое сообщение хэндшейка от клиента и завершает его
async fn try_handshake_respond(
    payload:       &[u8],
    src_addr:      SocketAddr,
    client_ssrc:   u32,
    server_keys:   &Arc<KeyPair>,
    shared_secret: &Arc<[u8; 32]>,
    socket:        &Arc<UdpSocket>,
    sessions:      &SessionMap,
) -> anyhow::Result<()> {
    use phantom_core::crypto::NoiseHandshake;

    // Создаём responder
    let mut responder = NoiseHandshake::respond(server_keys.as_ref())?;
    // Читаем первое сообщение клиента (-> e, es, s, ss)
    let _payload = responder.read_initiator_message(payload)?;
    // Формируем ответ (<- e, ee, se)
    let response = responder.write_response()?;

    // Отправляем ответ через UDP с фейковым SRTP заголовком
    let mut resp_pkt = vec![0u8; SRTP_HEADER_LEN + response.len()];
    let resp_hdr = SrtpHeader {
        seq_num:   rand::random(),
        timestamp: rand::random(),
        ssrc:      client_ssrc, // эхо SSRC клиента
        is_last:   false,
    };
    resp_hdr.write(&mut resp_pkt[..SRTP_HEADER_LEN]);
    resp_pkt[SRTP_HEADER_LEN..].copy_from_slice(&response);
    socket.send_to(&resp_pkt, src_addr).await?;

    // Переходим в transport mode
    let session_noise = responder.into_transport()?;

    // Регистрируем сессию
    crate::sessions::register_session(sessions, client_ssrc, src_addr, session_noise).await;

    Ok(())
}

// ─── TUN reader → UDP sender ─────────────────────────────────────────────────

pub async fn tun_to_udp_loop(
    mut tun_reader: tokio::io::ReadHalf<crate::tun_iface::AsyncTun>,
    socket:         Arc<UdpSocket>,
    sessions:       SessionMap,
) -> anyhow::Result<()> {
    let mut tun_buf  = vec![0u8; 65536];
    let mut pt_buf   = vec![0u8; 65536];
    let mut ct_buf   = vec![0u8; 65536];

    tracing::info!("TUN→UDP loop started");

    loop {
        // Читаем IP пакет из TUN
        let len = match read_tun_packet(&mut tun_reader, &mut tun_buf).await {
            Ok(n) if n == 0 => continue,
            Ok(n) => n,
            Err(e) => {
                tracing::error!("TUN read error: {}", e);
                tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
                continue;
            }
        };

        let ip_pkt = &tun_buf[..len];

        tracing::debug!("TUN read {} bytes, dst={}.{}.{}.{}",
            len,
            if len > 19 { ip_pkt[16] } else { 0 },
            if len > 19 { ip_pkt[17] } else { 0 },
            if len > 19 { ip_pkt[18] } else { 0 },
            if len > 19 { ip_pkt[19] } else { 0 }
        );

        for session_entry in sessions.iter() {
            let ssrc = *session_entry.key();
            let session_arc = session_entry.value().clone();
            let mut session = session_arc.lock().await;

            // Формируем plaintext с padding (имитация P-frame небольшого размера)
            let target = (ip_pkt.len() + 50).max(200);
            let pt_len = match build_plaintext(ip_pkt, target, &mut pt_buf) {
                Ok(n) => n,
                Err(e) => {
                    tracing::trace!("build_plaintext error: {}", e);
                    continue;
                }
            };

            // Шифруем
            let (seq, nonce) = session.send_nonce.next();
            let ct_len = match session.noise.encrypt(nonce, &pt_buf[..pt_len], &mut ct_buf) {
                Ok(n) => n,
                Err(e) => {
                    tracing::trace!("encrypt error for ssrc={:#010x}: {}", ssrc, e);
                    continue;
                }
            };

            // Фейковый SRTP заголовок
            let mut pkt = vec![0u8; SRTP_HEADER_LEN + ct_len];
            let hdr = SrtpHeader {
                seq_num:   seq,
                timestamp: rand::random(),
                ssrc,
                is_last:   true,
            };
            hdr.write(&mut pkt[..SRTP_HEADER_LEN]);
            pkt[SRTP_HEADER_LEN..].copy_from_slice(&ct_buf[..ct_len]);

            // Отправляем клиенту
            tracing::debug!("Sending {} encrypted bytes to {} (ssrc={:#010x})", pkt.len(), session.client_addr, ssrc);
            if let Err(e) = socket.send_to(&pkt, session.client_addr).await {
                tracing::warn!("send_to {} failed: {}", session.client_addr, e);
            }
        }
    }
}

async fn read_tun_packet(
    reader: &mut tokio::io::ReadHalf<crate::tun_iface::AsyncTun>,
    buf: &mut [u8],
) -> std::io::Result<usize> {
    use tokio::io::AsyncReadExt;
    reader.read(buf).await
}
