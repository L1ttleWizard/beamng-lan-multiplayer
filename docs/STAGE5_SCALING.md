# Этап 5: Масштабирование (выделенная инфраструктура)

План перехода от **P2P UDP (1×1)** к **клиент–серверной** архитектуре для публичных сессий и матчмейкинга.  
Составлен по **CodeGraph**-анализу `scratch/beamng_lan_multiplayer` (индекс antigravity root).

> **Глобальный порядок работ** — только [ROADMAP_5_6_7.md](./ROADMAP_5_6_7.md).  
> Этап 5 в цепочке: **шаги 03–04** (сессия) → затем **7** (контент) → **6.7** (гонки) → **08–11** (инфра) → **20** (опционально).

## Статус (фазы этапа 5 в порядке выполнения)

| Шаг | Фаза | Содержание | Статус |
|-----|------|------------|--------|
| **03** | **5.0.5.1–3** | Версии, reconnect, смена машины | Не начато |
| **04** | **5.0.5.4–6** | Прицепы, пароль, roster, nametag | Не начато |
| **08** | **5.0** | Протокол v2 + мультипир (`BREL`, `player_id`) | Не начато |
| **09** | **5.1** | C++ UDP Relay (headless) | Не начато |
| **10** | **5.2** | Matchmaking API + UI + онбординг | Не начато |
| **11** | **5.3** | Docker / CI + тесты + `PLAYER_GUIDE` | Не начато |
| **20** | **5.4** | Telemetry Web UI | Отложено (*optional*) |
| — | ~~**5.5**~~ | ~~Anti-cheat~~ | Исключено |

**До шага 03** (этап 7): [7.4 preset](./STAGE7_CONTENT_MODS.md#шаг-01--74-shared-garage-preset), [7.3 config UI](./STAGE7_CONTENT_MODS.md#шаг-02--73-лимит-config-ui-и-wire-flag).

---

## Анализ необходимости (продуктовые решения)

| Цель пользователя | Шаги roadmap | Комментарий |
|-------------------|--------------|-------------|
| Играть по LAN 1×1 как сейчас | **01–07** | Без relay; улучшения контента и сессии |
| Публичный сервер 8–16 без хоста в BeamNG | **08–11** | 5.0 + 5.1 + 5.2 |
| Список серверов в UI | **10** | + LAN discovery `:27019` для локалки |
| Быстрый деплой на VPS | **11** | Docker / CI |
| VoIP / culling / гонки | **07, 12–17** | [STAGE6](./STAGE6_EXPERIMENTAL.md) |
| Моды, карты, preset, config UI | **01–02, 05–06** | [STAGE7](./STAGE7_CONTENT_MODS.md) |
| Античит | — | **Не планируется**; на relay только rate-limit (**09**) |

**Волна 2 (инфраструктура)** начинается только после **шага 07** (гонки) или явного skip 6.7, если нужен раньше dedicated — но **03–04** и **01–06** обязательны для качества join.

**NAT (STUN/TURN):** шаг **18** ([STAGE6.2](./STAGE6_EXPERIMENTAL.md)) — только WAN P2P без relay. При **09** клиенты шлют исходящий UDP на публичный IP.

---

## Текущая архитектура (as-is)

### Транспорт

```
┌─────────────┐     UDP :27015      ┌─────────────┐
│  HOST       │◄──────────────────►│  CLIENT     │
│  (игра)     │  sendto(1 peer)    │  (игра)     │
└─────────────┘                    └─────────────┘
       │                                   │
       └── broadcast :27019 "lobby" ───────┘ (LAN discovery, IDLE)
```

| Параметр | Значение | Где в коде |
|----------|----------|------------|
| Игровой порт | `27015` (default) | `lanMultiplayer.lua` — `savedPort` |
| Discovery | UDP `255.255.255.255:27019`, JSON `type:"lobby"` | `onUpdate` IDLE/HOSTING |
| Роли | `HOST` / `CLIENT` / `NONE` | `role`, `state` |
| Отправка | CLIENT: `udp:send()`; HOST: `udp:sendto(targetIp, targetPort)` | `sendRaw` :825 |
| Пиры | **Один** `targetIp`/`targetPort` на хосте | `connect` перезаписывает peer |

**Критическое ограничение для Stage 5:** сейчас это **не** «комната на N игроков», а **сессия 1+1**. Relay без **5.0** только пересылает трафик двух клиентов; для «массовых заездов» нужны `player_id`, несколько `remoteVehicleId` и fan-out.

### Горячий путь (CodeGraph)

| Символ | Роль | Callers / Callees |
|--------|------|-------------------|
| `sendUpdate` | 60 Hz telemetry | → `sendRaw` (92 B FFI) |
| `sendRaw` | единая точка TX | ← `sendUpdate`, `sendPacket`, `sendPing`, `sendPong`, `processPacket` (ack), `aiTrafficSync.hostSendBatch` |
| `receivePackets` | poll UDP, coalesce updates | → `processPacket` |
| `processPacket` | диспетчер | → `updateRemoteVehicleBinary`, submodules `worldSync` / `gameplaySync` / `aiTrafficSync`, handshake |

Submodules в `onUpdate` (параллельно с основным циклом):

- `worldSync.onUpdate` — env ~5 s, props ~8 Hz (host only)
- `gameplaySync.onUpdate` — wheels ~0.5 s
- `aiTrafficSync.onUpdate` — traffic scan 0.5 s, TAIB batches (host only)

### Бинарные пакеты (FFI, little-endian)

#### `UpdatePacket` — magic `DPUB` (`0x42555044`), **92 байта**

Должен **байт-в-байт** совпадать с `ffi.cdef` в `lanMultiplayer.lua` и тестами `test_lanMultiplayer.lua`.

```c
#pragma pack(push, 1)
typedef struct {
    uint32_t magic;      // 0x42555044 "DPUB"
    uint32_t seq;
    float    px, py, pz;
    float    rx, ry, rz, rw;
    float    vx, vy, vz;
    float    ax, ay, az;
    float    throttle, steering, brake, clutch, handbrake;
    float    rpm, wheelSpeed;
    int16_t  gear;
    uint8_t  lights;
    uint8_t  flags;      // bit0 = ghost
} UpdatePacket;
#pragma pack(pop)
// static_assert(sizeof(UpdatePacket) == 92);
```

#### `TAIB` — AI traffic batch (Stage 4)

| Поле | Размер |
|------|--------|
| Header | 12 B (`magic`, `version`, `count`, `seq`) |
| Snapshot × N | 30 B × до 15 |

Magic: `0x42414954` (`"TAIB"`). Спека: `docs/STAGE4_AI_TRAFFIC.md`, `aiTrafficSync.lua`.

Relay **не парсит** физику TAIB/DPUB на v1 — только маршрутизация и **rate-limit** (анти-флуд, не anti-cheat).

### JSON-сообщения (полный реестр)

| `type` | Reliable | Направление | Модуль |
|--------|----------|-------------|--------|
| `connect` / `connect_ack` | ack | handshake | `lanMultiplayer` |
| `spawn` / `despawn` | reliable | lifecycle | `lanMultiplayer` |
| `reset` | reliable | | `lanMultiplayer` |
| `damage` | reliable | | `lanMultiplayer` (+ `reportDamage`) |
| `backfire` / `recovery` | unreliable / reliable | | `lanMultiplayer` |
| `chat` | reliable | | `lanMultiplayer` |
| `ack` | — | reliable UDP layer | `lanMultiplayer` |
| `ping` / `pong` | — | RTT (`{"t":"ping"}`) | `lanMultiplayer` |
| `lobby` | — | discovery only | `lanMultiplayer` |
| `world_env` / `world_props` | mixed | host → client | `worldSync` |
| `wheel_state` / `checkpoint` | reliable | | `gameplaySync` |
| `ai_spawn` / `ai_despawn` / `ai_teleport` | reliable | host → clients | `aiTrafficSync` |
| `session_error` | ack | handshake reject | `lanMultiplayer` (**5.0.5**) |
| `trailer_attach` / `trailer_detach` | reliable | lifecycle | `vehicleSync` (**5.0.5**) |
| `player_roster` | reliable | join/leave snapshot | relay / host (**5.0.5**) |
| `room_password` | — | join (dedicated) | relay (**5.0.5**) |

Legacy: JSON `update` / `u` — fallback, не использовать в production relay.

**Поля handshake (расширение `connect` / `connect_ack` / `join`):**

```json
{
  "protocol_version": 2,
  "mod_version": "4.1.0",
  "game_version": "0.34.x",
  "mods_hash": "sha256:…",
  "session_password": "optional",
  "config_truncated": false
}
```

### Существующие активы для Stage 5

| Актив | Назначение |
|-------|------------|
| `tests/load_tester.py` | Нагрузочный клиент (DPUB 60 Hz, handshake) |
| `tests/docker-compose.yml` | Шаблон контейнера для load tester |
| `.github/workflows/deploy.yml` | CI релиза **мода** (zip) — расширить под relay/API |
| `scratch/KISS-multiplayer/kissmp-server` | Референс dedicated server (Rust, rooms, master heartbeat) — в индексе CodeGraph |
| `scratch/BeamMP/...` | Референс UI server list |

---

## Целевая архитектура (to-be)

```
                    ┌──────────────────┐
                    │  Matchmaking API │
                    │  (REST + Redis)  │
                    └────────┬─────────┘
                             │ register / list (TTL 60s)
┌──────────┐   UDP    ┌──────▼──────┐   UDP    ┌──────────┐
│ Client 1 │◄──────►│ C++ Relay   │◄──────►│ Client 2 │
└──────────┘         │ (rooms)     │         └──────────┘
┌──────────┐         │ no physics  │         ┌──────────┐
│ Client N │◄──────►│ fan-out     │◄──────►│ ...      │
└──────────┘         └──────┬──────┘         └──────────┘
                            │ metrics (WS/HTTP)
                     ┌──────▼──────┐
                     │ Telemetry UI │
                     └─────────────┘
```

---

## Шаг 08 — 5.0 Протокол и клиент (multi-peer)

Без этого relay даст только «прокси для двух игроков».

### 5.0.1 Идентификация игроков

- [ ] `player_id: uint32` — выдаёт relay при `join_ack`
- [ ] `room_id: uint16` — комната на relay
- [ ] Расширить `UpdatePacket` **или** обернуть в `RelayFrame` (предпочтительно envelope, чтобы не ломать 92 B wire format внутри payload)

**Вариант A — Envelope (рекомендуется для relay):**

```c
#pragma pack(push, 1)
typedef struct {
    uint32_t magic;       // 0x524C4542 "BREL"
    uint16_t version;     // 1
    uint16_t room_id;
    uint32_t sender_id;
    uint16_t payload_len;
    // uint8_t payload[payload_len];  // DPUB | TAIB | JSON
} RelayHeader;  // 14 bytes + payload
#pragma pack(pop)
```

Клиент: `networkTransport.lua` (новый) — `sendFramed(payload)` / `onFramedReceived`.

### 5.0.2 Мультипир на клиенте

Сейчас: один `remoteVehicleId`, один nickname.

- [ ] `remotePlayers[player_id] = { vehicleId, nickname, targets... }`
- [ ] `processPacket` маршрутизирует DPUB по `sender_id` (из envelope)
- [ ] `receivePackets` на «логическом хосте» убрать — все клиенты равны, relay = hub
- [ ] UI: список игроков в сессии (расширить `LanMultiplayer` app)

### 5.0.3 Режим подключения `DEDICATED`

- [ ] `M.connectionMode = "LAN" | "DEDICATED"` в settings
- [ ] `connectDedicated(relayHost, relayPort, roomToken?)` — без `host()` в игре
- [ ] Сохранить LAN P2P как fallback (текущий `host`/`connect`)

### 5.0.4 AI traffic на dedicated

- [ ] **Designated simulation host** (`room.sim_host_id`) — только он шлёт `TAIB` + `ai_*`
- [ ] Relay (опционально): отбрасывать `TAIB`/`ai_*` не от `sim_host_id` — простое правило маршрутизации, не античит
- [ ] Клиенты: puppets как в Stage 4

### Критерии приёмки 5.0

1. Два клиента через **локальный mock relay** (Python) видят друг друга без игры-хоста.
2. Unit-тесты: encode/decode `RelayHeader`, маршрутизация по `player_id`.
3. LAN 1×1 режим не сломан (регрессия `test_lanMultiplayer.lua`).

---

## Шаги 03–04 — 5.0.5 Сессия и совместимость

**Шаги 03–04** в [ROADMAP_5_6_7.md](./ROADMAP_5_6_7.md).  
**После** Stage 7 шагов **01–02**; **до** шагов **05–06** (mods/map) и **07** (гонки).  
Работает в LAN P2P и на dedicated.

### 5.0.5.1 Версии и отказ при несовместимости

- [ ] `protocol_version` (int) — ломается только при смене wire format
- [ ] `mod_version` + `game_version` в `connect` / `join`
- [ ] Ответ `session_error` с `reason`: `mod_mismatch` | `game_mismatch` | `protocol_mismatch`
- [ ] UI: модальное окно «У друга 4.1, у вас 4.0» + кнопка «Всё равно» только в dev

### 5.0.5.2 Reconnect и disconnect

- [ ] Состояния: `CONNECTING` → `CONNECTED` → `RECONNECTING` (таймаут 5 s без пакетов)
- [ ] При reconnect: повторный `connect`/`join` без зависшего `remoteVehicleId`
- [ ] UI: «Соединение потеряно…» / «Снова в сети»
- [ ] Сохранять `nickname` и последний IP/relay в `settings/lanMultiplayer.json`

### 5.0.5.3 Смена машины без ручного reconnect

- [ ] `onVehicleSpawned` / garage: `despawn` старой + `spawn` новой (debounce 300 ms)
- [ ] Уже есть `strictLifecycle` + `_peerToLocalVehicles` — довести до автоматического UX
- [ ] Remote видит смену модели без перезахода в сессию

### 5.0.5.4 Прицепы и буксировка

- [ ] JSON `trailer_attach`: `{ vehicle_id, trailer_id, node_id, pos, rot }`
- [ ] `trailer_detach` при отцепе
- [ ] UI-заглушка, если прицеп не поддержан на карте/моде

### 5.0.5.5 Ливрея и config

- [ ] Аудит `getSafeConfigPayload` / `onPartConfigChanged` — decals, paint, vars
- [ ] Wire-флаг `config_truncated` и UI-баннеры — **Этап 7.3** ([STAGE7](./STAGE7_CONTENT_MODS.md))
- [ ] Shared garage preset (обмен без полного config) — **Этап 7.4** (приоритетнее 7.3)

### 5.0.5.6 Пароль сессии и ростер

| Режим | Поведение |
|-------|-----------|
| **LAN host** | Host задаёт 4–6 цифр; `connect` без пароля → `session_error` |
| **Dedicated** | `room_password` в register API + проверка в relay `join` |
| **Оба** | `player_roster` при join/leave: `{ player_id, nickname, ping }` |

- [ ] Nametag над **каждым** `remotePlayers[id]` (задел под 5.0.2)
- [ ] Опционально: **kick** по `player_id` (модерация хоста, не античит)

### Новый модуль (предложение)

`lua/ge/extensions/sessionSync.lua` — handshake extensions, reconnect FSM, roster UI hooks.  
`lua/ge/extensions/vehicleSync.lua` — trailer attach/detach.

### Критерии приёмки 5.0.5

1. Разные `mod_version` → понятная ошибка, без silent desync.
2. Обрыв UDP 10 s → reconnect, машины снова видны.
3. Смена машины в garage → друг видит новую модель < 2 s.
4. LAN host с паролем — клиент без пароля не входит.

---

## Шаг 09 — 5.1 C++ Headless Relay Server

**Стек:** C++20, Asio (`asio::io_context` + `udp::socket`), CMake, `std::unordered_map` для комнат.

### Структура репозитория (предложение)

```
server/
  CMakeLists.txt
  include/
    protocol.hpp      # DPUB, TAIB, RelayHeader — packed structs
    room.hpp
    relay_server.hpp
  src/
    main.cpp
    relay_server.cpp
    room.cpp
  tests/
    test_protocol.cpp # sizeof, magic, roundtrip
```

### Функциональность v1

| Задача | Детали |
|--------|--------|
| UDP listen | `0.0.0.0:27015` (configurable) |
| Join | JSON `join` + `protocol_version`, `mod_version`, `session_password?` → `join_ack` / `session_error` |
| Room table | `room_id → { players, sim_host_id, password_hash?, map, mods_hash }` |
| Fan-out | Пакет от player A → всем в комнате кроме A |
| Roster | При join/leave → reliable `player_roster` всем в комнате |
| Kick | JSON `kick` от sim_host → relay удаляет endpoint (**модерация**, не AC) |
| Transparent relay mode | Опция: raw forward без envelope для совместимости с LAN (dev only) |
| TAIB/DPUB | Forward by size/magic; optional parse magic only |
| Idle timeout | Kick player / destroy room if no packets 30 s |
| Metrics | `packets_in/out`, `bytes`, `players` — Prometheus endpoint `:9090` |

### Производительность (цели)

| Метрика | Цель |
|---------|------|
| CPU (16 players, 60 Hz each) | < 5% одного ядра |
| RAM | < 64 MB |
| Latency added | < 0.5 ms LAN DC, < 2 ms regional |

### Интеграция с load tester

- [ ] Расширить `tests/load_tester.py`: `--mode dedicated`, envelope + `join`
- [ ] `docker-compose`: сервис `relay` + N × `load_tester`

### Критерии приёмки 5.1

1. Бинарник `beamng-relay` Linux x64 + Windows x64 в CI artifacts.
2. `sizeof(UpdatePacket) == 92` в `test_protocol.cpp` совпадает с Lua FFI.
3. 8× load_tester → relay → p95 relay CPU stable, zero crashes 10 min.

---

## Шаг 10 — 5.2 Matchmaking API

**Стек (рекомендация):** Node.js **Fastify** + **ioredis** (проще стыковка с существующим JS UI мода). Альтернатива: Go + redis.

### REST API

| Method | Path | Описание |
|--------|------|----------|
| `POST` | `/api/servers/register` | Relay/агент регистрирует сервер |
| `POST` | `/api/servers/heartbeat` | Продление TTL (или reuse register) |
| `GET` | `/api/servers/list` | Список для UI |
| `GET` | `/api/servers/:id` | Детали одной записи |
| `DELETE` | `/api/servers/:id` | Снятие (опционально) |

**Тело register (пример):**

```json
{
  "name": "EU Freeroam #1",
  "map": "levels/west_coast_usa/info.json",
  "players": 3,
  "max_players": 16,
  "relay_host": "203.0.113.10",
  "relay_port": 27015,
  "region": "eu-west",
  "mods_hash": "optional",
  "version": "4.0"
}
```

**Redis:** ключ `server:{id}`, TTL **60 s**, индекс `servers:live` (sorted set by players).

### Relay → API

- [ ] При старте relay: `POST register` + goroutine heartbeat каждые **30 s**
- [ ] `players` / `max_players` — atomic counter в relay, sync в heartbeat

### UI BeamNG (`LanMultiplayer`)

Текущее: LAN discovery `lobby` + ручной IP.

- [ ] Вкладка **«Онлайн»**: таблица серверов (name, map, players, ping)
- [ ] Кнопка **«Обновить»** → `GET /api/servers/list` (HTTP из GE — `extensions.http` или CEF fetch из `app.js`)
- [ ] **«Подключиться»** → `connectDedicated(relay_host, relay_port)`
- [ ] Показать ping до relay (ICMP недоступен — UDP echo или последний game RTT)
- [ ] Фильтр: версия мода, регион, неполные серверы
- [ ] **Онбординг (первый запуск):** Host / Join / Discovery / Dedicated, порты, ссылка на `docs/PLAYER_GUIDE.md`
- [ ] Вкладка **«Игроки в сессии»** — roster из 5.0.5 (ник, ping, mute задел под 6.1)
- [ ] Поле **пароль сессии** для LAN host и dedicated join
- [ ] Баннер при `config_truncated` / version mismatch

### Критерии приёмки 5.2

1. Локально: `docker compose up` → API + Redis + relay → сервер виден в UI < 60 s.
2. TTL: без heartbeat сервер исчезает из list.
3. Два relay на разных портах — оба в list.

---

## Шаг 11 — 5.3 IaC и CI/CD

### Docker

```yaml
# deploy/docker-compose.prod.yml (новый)
services:
  redis:
    image: redis:7-alpine
  matchmaking:
    build: ./services/matchmaking
    environment:
      REDIS_URL: redis://redis:6379
  relay:
    build: ./server
    ports: ["27015:27015/udp", "9090:9090"]
    environment:
      MATCHMAKING_URL: http://matchmaking:3000
  telemetry:          # фаза 5.4
    build: ./services/telemetry
```

### Ansible (VPS bootstrap)

- [ ] `ansible/playbooks/deploy.yml` — Docker, ufw (27015/udp, 443/tcp), compose pull/up
- [ ] `inventory/production.yml` — хосты по регионам
- [ ] Secrets: `MATCHMAKING_API_KEY` для register (relay only)

### GitHub Actions (расширить `.github/workflows/`)

| Workflow | Триггер | Jobs |
|----------|---------|------|
| `mod-release.yml` | push `main` | zip мода (текущий deploy.yml) |
| `mod-test.yml` | PR / push | Lua unit tests + `load_tester` smoke |
| `server-ci.yml` | push `server/**` | cmake build, unit tests, artifacts |
| `api-ci.yml` | push `services/matchmaking/**` | lint, test, docker build |
| `deploy-staging.yml` | tag `v*` | push images, ansible staging |

### Тесты и документация (часть 5.0.5 / 5.3)

- [ ] Починить harness: `extensions.load` в sandbox → прямой `require` путей мода
- [ ] Тесты: `session_error`, `protocol_version`, `trailer_attach` roundtrip
- [ ] `docs/PLAYER_GUIDE.md` — firewall, порты 27015/27019, troubleshooting NAT → «используйте Dedicated»
- [ ] README: таблица совместимости версий BeamNG.drive

### Критерии приёмки 5.3

1. Чистый Ubuntu 22.04: одна команда `ansible-playbook` → рабочий relay + list API.
2. PR в `server/` запускает CI < 10 min.
3. `mod-test.yml` зелёный на PR (Lua + load_tester 2 clients).

---

## Шаг 20 — 5.4 Telemetry Web UI (*optional*)

> **Приоритет: низкий.** Делать только если нужны турниры/мониторинг без захода в игру.

**Стек:** React/Vite или Svelte + Leaflet (карта) + WebSocket.

### Источники данных

| Событие | Откуда | Частота |
|---------|--------|---------|
| Player position | Relay: parse DPUB `px,py,pz` + `sender_id` | 5–10 Hz aggregated |
| Room stats | Relay HTTP `/metrics` | 1 Hz |
| Session history | Matchmaking / TimescaleDB (опционально v2) | on end |

### Экраны

1. **Live map** — маркеры игроков, фильтр по `room_id`
2. **Session board** — история: длительность, пик игроков, карта
3. **Leaderboard** (v2) — lap/checkpoint из `gameplaySync` events, если публикуются в API

### Приватность

- [ ] Opt-in на relay (`telemetry_enabled` в register)
- [ ] Не логировать nickname по умолчанию в публичный dashboard (hash id)

### Критерии приёмки 5.4

1. 4 игрока на тестовой карте — маркеры двигаются на карте < 2 s задержки.
2. После disconnect сессия появляется в history.

---

## Исключено из scope: Anti-cheat (бывш. 5.5)

По решению продукта **не реализуем:** speedhack/teleport checks, матрицу прав на `damage`, kick за «читы».

**Оставляем только в relay (5.1):**

- лимит пакетов/сек на endpoint (DoS);
- max payload size;
- опционально: forward только пакеты с корректным `BREL` envelope и известным `player_id`.

Доверие к физике — на клиентах (как в BeamMP/KISS без authoritative server).

---

## Порядок внедрения (этап 5 в общей цепочке)

Полная последовательность **01–20**: [ROADMAP_5_6_7.md](./ROADMAP_5_6_7.md).

Фазы **только Stage 5** (не начинать 08, пока не закрыты 03–04 и шаги 01–02, 05–06 из Stage 7):

| Шаг | Фаза | Зависит от |
|-----|------|------------|
| **03** | 5.0.5.1–3 | **01–02** (Stage 7) |
| **04** | 5.0.5.4–6 | **03** |
| **08** | 5.0 | **04**, **05–06**, желательно **07** |
| **09** | 5.1 | **08** |
| **10** | 5.2 | **09**, **05–06** (mods/map в list) |
| **11** | 5.3 | **09** (параллельно с 10 после старта relay) |
| **20** | 5.4 | **10** (*optional*) |

---

## Миграция с LAN (чеклист для разработчика)

1. Не удалять `host()` / LAN discovery — отдельный режим.
2. Все новые вызовы TX/RX — через `networkTransport` (тонкая обёртка над `sendRaw`/`processPacket`).
3. Тесты: `tests/test_relay_protocol.lua`, `tests/test_session_sync.lua` + C++ gtest.
4. Документировать порты: `27015` game, `27019` LAN discovery (остаётся LAN-only), `3000` API, `9090` metrics.
5. Новые пакеты — через `networkTransport` + регистрация в таблице JSON выше.

---

## Риски и открытые вопросы

| Риск | Митигация |
|------|-----------|
| NAT у игроков | Dedicated relay на публичном IP; клиенты только outbound UDP |
| Мод-совместимость | `mods_hash` — **Этап 7.1**; `version` — **5.0.5** |
| Нагрузка AI TAIB | Rate-limit TAIB per room; sim_host один; interest mgmt — Этап 6.3 |
| BeamNG HTTP из Lua | Предпочесть fetch из CEF (`app.js`) для matchmaking list |

---

## Связанные документы

- [ROADMAP_5_6_7.md](./ROADMAP_5_6_7.md) — **единый порядок шагов 01–20**
- [STAGE4_AI_TRAFFIC.md](./STAGE4_AI_TRAFFIC.md) — TAIB, host-authoritative AI
- [STAGE6_EXPERIMENTAL.md](./STAGE6_EXPERIMENTAL.md) — шаги 07, 12–19
- [STAGE7_CONTENT_MODS.md](./STAGE7_CONTENT_MODS.md) — шаги 01–02, 05–06
- [README.md](../README.md) — обзор мода v4.0

---

## CodeGraph — ключевые символы для навигации

```bash
# из корня antigravity
codegraph query sendRaw --path scratch/beamng_lan_multiplayer
codegraph callers sendRaw
codegraph callees processPacket
codegraph impact sendUpdate
```

Файлы мода под индексом: `lua/ge/extensions/lanMultiplayer.lua`, `aiTrafficSync.lua`, `worldSync.lua`, `gameplaySync.lua`, `ui/modules/apps/LanMultiplayer/`.
