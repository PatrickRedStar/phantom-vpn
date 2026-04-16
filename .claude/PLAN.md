  Что можем сделать (по убыванию ROI)                                                                                                                     
                                                                                                                                                          
  🔥 Приоритет 1 — производительность (видимый эффект)
                                                                                                                                                          
  1. Batch TUN writes в tun_uring — сейчас 1 syscall/пакет, самый жирный bottleneck. Ожидаемо +20–40% RX.                                                 
  2. Parallel RX path — по аналогии с тем, что сделали на TX в v0.17.2 (138→625 Mbit/s). client_to_tun_loop сейчас serial, TX уже параллельный — есть
  ~3.2× разрыв per-CPU. Должно выровнять картину.                                                                                                         
                                                                  
  Эти две штуки закроют все измеренные bottleneck'и из reference_bottleneck_v0172.md. После этого wired потолок упрётся либо в NIC, либо в NAT, а не в наш
   код.                                                           
                                                                                                                                                          
  🔥 Приоритет 1 — стелс (закрываем оставшиеся векторы)                                                                                                   
  
  3. Detection vector 11 — timing jitter на frame interval. Сейчас фреймы идут ровно по мере появления пакетов в TUN, это детектируемый паттерн. Добавить 
  небольшой случайный jitter в дисперсии как у реального видео.   
  4. Detection vector 13 — connection migration. Периодически переоткрывать TLS-сокет (например через 10–30 мин) — имитация roaming mobile client.        
                                                                                                                                                          
  ⚙ Приоритет 2 — UX и инфра                                                                                                                             
                                                                                                                                                          
  5. Android «Clone profile» — пользователь жаловался (см. feedback_profile_ux.md), сейчас чтобы сделать второй профиль под другой адрес приходится       
  вручную копировать всё.                                         
  6. Rotated SNI pool — добавить несколько реально валидных SNI (tls.nl2, cdn.nl2, api.nl2), ротировать между коннектами. Закрывает detection vector 2    
  полностью.                                                                                                                                              
  7. Buffer pool (BytesMut slab) — -30K alloc/s на горячем пути. Низкая сложность, но и низкий эффект.
                                                                                                                                                          
  🧪 Приоритет 3 — исследовательское                                                                                                                      
                                                                                                                                                          
  8. iperf3-бенч server-side без телефона — уже есть рецепт в reference_server_side_bench.md (phantom-client-linux на hostkey + iperf3). Стоит            
  автоматизировать в скрипт — будет быстрый A/B для каждого перф-фикса.
  9. Telemetry endpoint — /api/perf возвращающий per-stream throughput/latency. Поможет диагностировать, какой CPU core утыкается при реальном трафике.   
                                                                                                                                                          
  ❌ Что НЕ делаем (пока)                                                                                                                                 
                                                                                                                                                          
  - Multi-hop / multi-origin sharding — крайняя мера, как ты сказал. Нужна разная AS, не просто +IP на одном VPS (см. reference_multi_origin_design.md).  
  Инфраструктурно дорого, эффект не гарантирован до того, как закроем внутренние bottleneck'и (батч TUN + parallel RX).
  - Kernel module / eBPF — риск kernel panic на проде слишком высок.                                                                                      
  - AmneziaWG / WG-in-QUIC — отвергнуто исторически, стелс слабее нашего.                                                                                 
                                                                                                                                                          
  ---                                                                                                                                                     
  Рекомендация на завтра                                                                                                                                  
                                                                                                                                                          
  Начать с пункта 1 (batch TUN writes) — это единственная оставшаяся вещь, которая точно даст измеримый прирост на wired-тесте через RU-relay. После неё
  сделать пункт 2 (parallel RX), и потом уже идти в стелс-векторы 11/13.                                                                                  
                                                                  
  Всё, спокойной ночи 👻                                                                                                                                  



  3. Detection vector 11 — timing jitter                          
                                                                                                                                                            
  Что сейчас: shaper.rs не существует как файл (удалён или переименован). H264 shaping упоминается в build_batch_plaintext через target_size параметр. На
  сервере stream_batch_loop вызывает build_batch_plaintext(&refs, 0, ...) с target_size=0 — шейпинг отключён. На клиенте tls_tx_loop тоже target_size=0.    
                                                                  
  Что делать: Добавить inter-batch jitter — после write_all в tls_tx_loop (tls_tunnel.rs:170) и tls_write_loop (h2_server.rs:476) ввести                    
  tokio::time::sleep(jitter) где jitter ~ LogNormal(μ=3.3, σ=1.2). Цена: 5-10% throughput.
                                                                                                                                                            
  Сложность: низкая. Но нужно аккуратно — jitter должен быть только при низком трафике (idle-like), при burst'е добавлять delay убьёт throughput. Решение:  
  jitter только если batch.len() < 3 (мало пакетов = user browsing, не bulk transfer).
                                                                                                                                                            
  ---                                                             
  4. Detection vector 13 — connection migration
                                                                                                                                                            
  Что делать: Периодически (10-30 мин, jittered) клиент закрывает один TLS stream и открывает новый к тому же серверу. Server-side уже поддерживает
  reconnect через attach_stream/detach_stream_gen. Нужен только клиентский timer.                                                                           
                                                                  
  Сложность: средняя. Файлы: crates/client-linux/src/main.rs, crates/client-android/src/lib.rs. Нужен per-stream migration timer + graceful stream rotation 
  (старый close после нового up).                                 
                                                                                                                                                            
  ---                                                             
  5. Android «Clone profile»
                                                                                                                                                            
  Что сейчас: ProfilesStore имеет addProfile, updateProfile, deleteProfile. Нет cloneProfile.
                                                                                                                                                            
  Что делать: Добавить fun cloneProfile(id: String) в ProfilesStore — копирует все поля кроме id (новый UUID) и name (+ " (копия)"), копирует cert/key файлы
   в новую директорию profiles/{newId}/. Кнопка в SettingsScreen рядом с Delete.                                                                            
                                                                                                                                                            
  Сложность: низкая. Файлы: ProfilesStore.kt, SettingsScreen.kt, SettingsViewModel.kt.                                                                      
  
  ---                                                                                                                                                       
  6. Rotated SNI pool                                             
                     
  Что делать: Клиент при каждом connect выбирает SNI из пула ["tls.nl2.bikini-bottom.com", "cdn.nl2.bikini-bottom.com", "api.nl2.bikini-bottom.com"].
  Server-side nginx ssl_preread уже роутит по prefix *.nl2.bikini-bottom.com. Нужно добавить все варианты в nginx.                                          
  
  Сложность: низкая. Config-level change + клиентский рандом.                                                                                               
                                                                  
  ---                                                                                                                                                       
  7. Buffer pool (BytesMut slab)                                  
                                                                                                                                                            
  Что сейчас: tun_uring.rs:98 — BytesMut::with_capacity(len) на каждый пакет. tls_tunnel.rs:97 — Bytes::copy_from_slice на каждый пакет.
                                                                                                                                                            
  Что делать: Slab allocator / object_pool crate. При 24K pkt/s это ~24K alloc/s. Выигрыш: -30K alloc/s, но реальный throughput impact <5%.                 
                                                                                                                                                            
  Сложность: средняя, низкий эффект.                                                                                                                        
                                 
