Посмотрел репозиторий и приложенное ТЗ. Главный вывод: потолок около 100 Мбит/с у вас, скорее всего, вызван не одной границей User/Kernel, а суммой нескольких оверхедов в текущем dataplane. ТЗ уже нацелено в правильную сторону — eBPF/XDP + AF_XDP + RSS + buffer pools — но активная реализация пока живёт в userspace как TUN -> async channels -> QUIC stream -> async channels -> TUN.

Сейчас горячий путь выглядит примерно так:

TUN read
  -> buf[..n].to_vec()
  -> mpsc<Vec<u8>>
  -> build_batch_plaintext()   // ещё одна копия
  -> encrypt() в ct_buf
  -> copy в frame_buf
  -> quinn::SendStream::write_all()

На обратном пути extract_batch_packets() снова делает Vec<Vec<u8>>, после чего каждый пакет отдельно пишется в TUN. То есть у вас проблема шире, чем просто “дорогие syscalls”: здесь ещё аллокации, копирования, wakeup’ы задач, atomics в mpsc, cache bouncing и частичная сериализация тракта.

Есть и важное уточнение к гипотезе: tokio::mpsc-handoff не равен полноценному kernel context switch на каждый пакет. Настоящие переходы User/Kernel у вас на TUN read/write и socket I/O. Но в вашем коде очень заметен и чисто user-space overhead — и похоже, он уже достаточно велик, чтобы первым упереться в стену.

Ещё один критичный момент: в серверном tun_to_quic_loop batching из общей очереди вынимает пакет, проверяет dst_ip, и если пакет относится к другой сессии, он не возвращается обратно. Это уже не микрооптимизация, а возможная причина потерь пакетов и лишних ретрансмов наверху. Я бы исправил это до любых новых замеров.

Отдельно видно архитектурное расхождение: README описывает WebRTC/SRTP-подобный UDP transport, а фактически активный режим сейчас — один надёжный bidirectional QUIC data stream. Для IP-туннеля это не лучшая семантика. QUIC DATAGRAM как раз стандартизован для ненадёжной передачи поверх QUIC, RFC 9221 прямо приводит VPN tunnel как типичный use case; DATAGRAM-фреймы не retransmit’ятся на transport-level, но всё ещё подчиняются congestion control QUIC. Это обычно лучше подходит для туннеля, чем один надёжный stream. У RFC есть и caveat: использование DATAGRAM может отличаться по поведению при loss, так что это улучшает семантику и производительность, а не делает трафик “магически невидимым”.

1. Как уменьшить overhead на переходы User/Kernel

Начал бы не с kernel bypass, а с устранения лишнего user-space мусора.

Первое — убрать Vec<u8> на пакет. В вашем ТЗ уже заложены BytesMut pools, и это правильно. Передавайте по пайплайну не “новый heap-объект с полным копированием”, а дескриптор/слот из пула. extract_batch_packets() должен возвращать слайсы или lightweight-дескрипторы, а не Vec<Vec<u8>>. Точно так же framing лучше собирать в одном буфере с заранее зарезервированным headroom, чтобы не гонять данные через pt_buf -> ct_buf -> frame_buf.

Второе — схлопнуть per-packet async-граф. Для control plane tokio хорош, для dataplane на 1–1.5 KB пакетах чаще выгоднее модель queue -> pinned worker -> run-to-completion, чем несколько async-задач и два-три mpsc hops на пакет. На сервере у вас сейчас есть явный serialization point: один tun_to_quic_loop на весь TUN→QUIC путь.

Третье — multiqueue TUN. Linux поддерживает multiqueue tuntap через IFF_MULTI_QUEUE, причём уже давно; одна и та же виртуальная карта может иметь несколько FD-очередей для параллельной обработки. В текущем коде у вас в TUN setup только IFF_TUN | IFF_NO_PI, без multiqueue. Это прямой кандидат на ускорение: queue == worker == CPU.

Четвёртое — batching syscalls. Если вы уйдёте от QUIC-stream к raw UDP-пути, используйте батчевые send/recv и короткий коалесцирующий таймер порядка десятков-сотен микросекунд. Сейчас у вас батчинг есть, но он построен уже после нескольких копирований и через общие очереди, поэтому выигрывает меньше, чем мог бы.

И ещё: если цифра 100 Мбит/с получена не на “голом” стенде, а на Xray-пайплайне из приложенных конфигов, это надо отделить от оценки протокола. В NL/RU-конфигах включены StatsService, metrics, dnsLog, sniffing, а в одном случае ещё и loglevel: "debug", так что такой стенд сам добавляет userspace work и плохо годится как чистый throughput baseline.

2. Насколько применимы eBPF/XDP и DPDK

Для вашей архитектуры я бы рассматривал AF_XDP как основной следующий шаг, а DPDK — как опцию только для dedicated bare metal и multi-gigabit цели.

AF_XDP в документации ядра прямо описан как механизм для high-performance packet processing: XDP-программа может через XSKMAP перенаправлять кадры в user-space XSK-сокеты, связанные с конкретной netdev queue. AF_XDP умеет работать и в copy mode, и в zero-copy; флаг XDP_ZEROCOPY заставляет использовать zero-copy или завершиться ошибкой, если драйвер/NIC не поддерживает этот режим.

Практически я бы вынес в XDP не “всю логику протокола”, а только дешёвый prefilter + steering:

разобрать внешний UDP/SRTP-like заголовок,

проверить дешёвый Magic Word/SSRC,

отправить “свои” пакеты в нужный XSK/queue,

всё остальное пустить через XDP_PASS в обычный стек.

Это как раз совпадает с вашим ТЗ: XDP хорош как быстрый classifier/dispatcher, а не как место для full crypto, таймерного shaping и сложного session state. XDP_REDIRECT работает с XSKMAP и CPUMAP; CPUMAP умеет уводить raw XDP frames на другой CPU, что полезно как software RSS, если аппаратное steering слабое.

Но есть важная оговорка: AF_XDP особенно хорошо стыкуется с собственным UDP-датаплейном. Если вы останетесь на quinn и reliable QUIC streams, XDP/AF_XDP не “ускорит QUIC магически” — у вас всё равно останется user-space QUIC stack, retransmission logic и stream semantics. Поэтому AF_XDP даёт максимальный ROI, когда outer dataplane — это ваш собственный UDP framing, а не текущий QUIC stream.

DPDK даст ещё больше headroom, но цена высокая. DPDK PMD работают, напрямую опрашивая RX/TX descriptors в userspace; там критичны привязка queue к core, NUMA-local memory и отсутствие совместного доступа нескольких логических ядер к одной RX/TX-очереди. Во многих случаях порты надо отвязывать от обычного Linux driver и биндинговать к vfio-pci; такие порты фактически уходят из обычного Linux control plane. Плюс hugepages — нормальная часть эксплуатации, и DPDK отдельно рекомендует 1 GB hugepages, где это поддерживается.

Поэтому мой выбор такой:

AF_XDP — да, как компромисс между перформансом и совместимостью с Linux networking.

DPDK — только если у вас dedicated NIC, bare metal и цель уже не “сотни мегабит”, а “стабильные гигабиты и выше”.

3. Какие Zero-copy подходы реально помогут

Самый большой выигрыш у вас, скорее всего, даст не “волшебный socket zerocopy”, а внутренний zero-copy / zero-allocation design.

Что даст быстрый эффект:

пул буферов (BytesMut, slab, фиксированные packet slots);

batch parser на слайсах, а не Vec<Vec<u8>>;

in-place framing;

переиспользование encryption/output buffers;

передача ownership не данных, а буферного дескриптора.

Для настоящего kernel/user zero-copy на серверном edge правильный кандидат — AF_XDP UMEM. Именно там смысл zero-copy максимален: вы убираете тяжёлый skb-path и, при поддержке драйвера, действительно получаете zero-copy между NIC и userspace.

MSG_ZEROCOPY и SO_ZEROCOPY я бы считал второстепенной опцией. Документация ядра прямо говорит, что они обычно эффективны на записях примерно от 10 KB и выше; для MTU-sized трафика выгода часто маленькая или отрицательная из-за page pinning и completion overhead. IORING_OP_SEND_ZC может помочь на socket send path, но zerocopy там не гарантирован и может quietly свалиться обратно в копирование. А zero-copy RX в io_uring требует специфических возможностей NIC, включая header/data split, flow steering и RSS, то есть это не “просто включить флаг”.

splice/vmsplice тоже не выглядят главным ответом на вашу задачу: вы не просто прокачиваете байты из A в B, вы на каждом пакете делаете framing, encryption, parsing и shaping.

В каком порядке я бы это делал

Исправить баг с потерей пакетов в серверном batching-loop и убрать глобальный serialization point.

Перевести hot path с Vec<u8> на buffer pool + дескрипторы.

Включить multiqueue TUN и шардировать workers по CPU.

Разделить control/data plane: control оставить на QUIC stream, data перевести на QUIC DATAGRAM или собственный UDP framing. QUIC DATAGRAM для туннеля семантически лучше, чем один reliable stream.

На серверной внешней стороне внедрить XDP + AF_XDP: минимальный prefilter в XDP, вся тяжёлая логика — в per-queue worker’ах.

Только если этого всё ещё мало, смотреть в сторону DPDK.

Если резюмировать одной фразой: ваш bottleneck сегодня — это не “ядро слишком медленное”, а то, что текущая реализация всё ещё делает слишком много работы на пакет в userspace, да ещё и на неидеальной транспортной семантике. AF_XDP/XDP — правильное направление, но самый быстрый выигрыш вы получите, сначала почистив сам dataplane.
