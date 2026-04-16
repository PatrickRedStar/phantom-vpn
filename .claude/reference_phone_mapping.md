---
name: Phone-to-client mapping (2026-04-12)
description: Какой телефон какому VPN клиенту соответствует — 3 телефона, 5 клиентов
type: reference
originSessionId: 86cd0a63-4677-4164-83d8-fdbac6637377
---
| Телефон | adb serial | Клиент(ы) | TUN |
|---------|-----------|-----------|-----|
| Galaxy S21 (SM_G991B) | R5CR102X85M (USB) | spongebob2 + spongebob2-ru | 10.7.0.3, 10.7.0.5 |
| Galaxy S25 Ultra (SM_S938B) | 192.168.1.8:38583 (WiFi) | galaxy | 10.7.0.7 |
| Galaxy Z Flip 6 (SM_F741B) | 192.168.1.9:43333 (WiFi) | Polina (main) + Polina malina (Knox/Secure Folder) | 10.7.0.6, 10.7.0.8 |

Knox (Secure Folder) на Z Flip 6 = user 150. adb не может install/run-as в Knox — профиль нужно вводить вручную (QR scan conn string).

S25 Ultra тоже имеет user 150 (Knox), но приложение там не используется. При `run-as` нужен `--user 0`.
