# Этап 6: Геймплей, сеть и полировка

> **Глобальный порядок:** [ROADMAP_5_6_7.md](./ROADMAP_5_6_7.md).  
> Этап 6: **шаг 07** (гонки, LAN) → после **08–11** → **шаги 12–19**.

Сессия: **03–04** ([STAGE5](./STAGE5_SCALING.md)). Контент: **01–02, 05–06** ([STAGE7](./STAGE7_CONTENT_MODS.md)). Relay: **08–09**. AI LOD: [STAGE4](./STAGE4_AI_TRAFFIC.md).

## Статус (порядок выполнения)

| Шаг | Фаза | Содержание | Статус |
|-----|------|------------|--------|
| **07** | **6.7** | Гонки, countdown, конвой, vote | Не начато |
| **12** | **6.3** | Interest grid на relay | Не начато |
| **13** | **6.4** | Bandwidth governor | Не начато |
| **14** | **6.1** | Proximity VoIP | Не начато |
| **15** | **6.5** | PTT / рация / mute | Не начато |
| **16** | **6.8** | Spectator | Backlog |
| **17** | **6.9** | i18n, privacy, police backlog | Не начато |
| **18** | **6.2** | NAT STUN/TURN | Отложено (*optional*) |
| **19** | **6.6** | DPUB delta | Backlog (*optional*) |

---

## Сводка: что реально нужно

```
                    ┌─────────────────────────────────────┐
                    │  Сценарий: LAN 1×1 (как сейчас)      │
                    │  6.1 VoIP — низкая ценность          │
                    │  6.2 NAT — нужен без проброса порта  │
                    │  6.3 Culling — почти не нужен        │
                    └─────────────────────────────────────┘

                    ┌─────────────────────────────────────┐
                    │  Сценарий: Dedicated 8–16 (Stage 5)  │
                    │  6.1 VoIP — высокая ценность         │
                    │  6.2 NAT — не нужен (outbound UDP)   │
                    │  6.3 Culling — высокая ценность      │
                    └─────────────────────────────────────┘
```

| Фича | Без Stage 5 | Со Stage 5 (relay) |
|------|-------------|-------------------|
| **6.1 VoIP** | 2 позиции (DPUB) — «рация» слабо ощущается | N позиций → полноценный proximity |
| **6.2 NAT** | Критично для интернет-P2P | **Можно не делать** |
| **6.3 Culling** | Уже есть LOD AI (100/500 m) | Interest set на relay для DPUB+TAIB+props |

---

## Зависимости от текущего кода

| Уже есть | Файл | Что даёт для Stage 6 |
|----------|------|----------------------|
| Позиция игрока 60 Hz | `lanMultiplayer` → `UpdatePacket` | Источник дистанции для VoIP |
| Текстовый чат | `type:"chat"` | Fallback, UI hook |
| AI distance LOD | `aiTrafficSync` зоны A/B/C | База для 6.3, не дублировать слепо |
| Props radius 200 m | `worldSync` | Аналог «interest radius» |
| Один remote vehicle | `remoteVehicleId` | **Блокер VoIP/culling для N игроков → Stage 5.0** |
| Референс VoIP | `KISS-multiplayer` (`voice_chat.rs`, `voicechat.lua`) | Архитектура bridge + Opus + spatial |

**CodeGraph:** `codegraph query voice --path scratch/KISS-multiplayer`

---

## Шаг 14 — 6.1 Proximity VoIP (рация)

### Нужен ли C++ плагин BeamNG?

| Подход | Плюсы | Минусы | Вердикт |
|--------|-------|--------|---------|
| **C++ плагин в движок** | Низкая задержка, прямой доступ к audio device | Сборка под версии BeamNG, подпись, поддержка | **Не v1** |
| **Внешний bridge** (как KISS) | cpal/miniaudio + Opus в отдельном процессе | Второй exe, IPC с игрой | **Рекомендуется v1** |
| **Lua + FFI Opus** только | Всё в моде | Захват микрофона в GE Lua **ненадёжен** | Только decode/play v1, capture в bridge |

**Вывод:** цель «рация с затуханием по дистанции» достижима **без** C++ плагина в v1 — через **`beamng-voice-bridge`** (Rust или C++), по аналогии с `kissmp-bridge/src/voice_chat.rs` (cpal + audiopus).

### Протокол: `AUDI` (AUDIO_DATA)

Новый бинарный тип (не ломает DPUB 92 B):

```c
#pragma pack(push, 1)
typedef struct {
    uint32_t magic;      // 0x49445541 "AUDI"
    uint16_t version;    // 1
    uint32_t sender_id;  // из Stage 5.0
    uint16_t seq;
    uint16_t opus_len;   // ≤ 400
    // uint8_t opus[opus_len];
} AudioFrameHeader;  // 14 + opus_len
#pragma pack(pop)
```

- Кодек: **Opus** VOIP mode, **16–24 kbps**, frame 20 ms
- Частота отправки: **50 Hz max** при PTT; иначе 0
- Транспорт: через `BREL` envelope (Stage 5) или напрямую на relay

### Клиент (мод)

Новый модуль `lua/ge/extensions/voiceSync.lua`:

- [ ] IPC с bridge: JSON `{cmd:"start"|"stop"|"level"}` / бинарные Opus кадры
- [ ] `onUpdate`: для каждого `remotePlayers[id]` взять позицию из last DPUB
- [ ] **Attenuation:** `gain = clamp(1 - dist / R_MAX, 0, 1)`, `R_MAX` ≈ 40–80 m (настройка)
- [ ] **Pan:** вектор «игрок → слушатель» в плоскости XZ → stereo pan (упрощённо, без HRTF v1)
- [ ] UI: PTT клавиша, индикатор уровня, mute по игроку
- [ ] Toggle **Voice Enabled** в `LanMultiplayer` app

### Bridge (вне игры)

- [ ] Захват: **miniaudio** или **cpal** (как KISS)
- [ ] Encode Opus → UDP или pipe в мод
- [ ] Decode входящих → mix → output device
- [ ] Опционально: отправка **позиции ушей** (камера или кузов) — KISS шлёт `SpatialUpdate` для left/right ear

### Критерии приёмки 6.1

1. Два клиента на dedicated relay: при отъезде > 50 m голос заметно тише.
2. PTT: без зажатия клавиши uplink < 1 kb/s.
3. 8 игроков, все говорят PTT — CPU bridge < 15%, без клипов в mix.

### Не в v1

- C++ плагин внутри `BeamNG.exe`
- Шумоподавление RNNoise (backlog)
- Эхоподавление full-duplex без гарнитуры

---

## Шаг 18 — 6.2 NAT Traversal (STUN/TURN) (*optional*)

### Нужно ли?

| Режим подключения | STUN/TURN |
|-------------------|-----------|
| **Dedicated relay** (Stage 5.1) | **Не нужен** — клиент инициирует UDP на публичный IP |
| **LAN P2P** в одной подсети | **Не нужен** — discovery `:27019` |
| **Internet P2P** без relay | **Нужен** — иначе Hamachi/Tailscale/ручной проброс |

### Архитектура (только если сохраняем Internet P2P)

```
Client A ──STUN──► узнать reflexive (ip:port)
Client B ──STUN──► узнать reflexive
     └── signaling (через matchmaking API WebSocket или JSON hole-punch)
     └── если symmetric NAT ──► TURN на том же VPS что relay (coturn)
```

### Задачи (если включено)

- [ ] Signaling channel: `POST /api/p2p/signal` или WS room (короткий TTL)
- [ ] Интеграция **libjuice** / **libdatachannel** / готовый **coturn** — не писать STUN с нуля
- [ ] Fallback UI: «Не удалось пробить NAT → подключитесь к Dedicated серверу»

### Критерии приёмки 6.2

1. Два домашних роутера (разные провайдеры) — P2P connect без port forward **или** явная подсказка перейти на relay.

### Вердикт по продукту

**Отложить**, если основной путь — Stage 5 dedicated.  
**Оставить** только для режима `connectionMode = "LAN_P2P_WAN"`.

---

## Шаг 12 — 6.3 Replication Graph / Grid Culling

### Что уже покрыто (не дублировать)

| Область | Уже реализовано | Файл |
|---------|-----------------|------|
| AI traffic | LOD 100 m @ 60 Hz, 100–500 m @ 10 Hz, >500 off | `aiTrafficSync.lua` |
| World props | Скан 200 m, batch 24 | `worldSync.lua` |
| Player telemetry | Всегда 1 peer → full rate | `lanMultiplayer.lua` |

### Когда 6.3 становится обязательным

- **≥ 8 игроков** на одной карте (после 5.0): 8 × 92 B × 60 Hz ≈ **44 KB/s** только DPUB — ещё терпимо, но с TAIB+props растёт
- **≥ 16 игроков** или **dense AI** (50+ TAIB entities): без interest management — перегруз

### Дизайн: единый Interest Manager

Один компонент на **relay** (предпочтительно) или на sim-host (если P2P):

```
Карта → сетка cell_size = 128 m (настраивается)
Каждый тик:
  player_cell = hash(px, pz)
  interest[player] = { entities в 3×3 соседних cells }
  forward packet только если (sender, receiver) в mutual interest
```

| Тип сущности | Ключ в grid | Примечание |
|--------------|-------------|------------|
| Player `DPUB` | `player_id` | Всегда в своей cell |
| AI `TAIB` net_id | `net_id` | Заменяет per-client LOD на relay при N>2 |
| `world_props` | prop id | Уже есть radius — объединить |
| `AUDI` | `sender_id` | Голос только в interest (см. 6.1) |

### Occlusion «за горой»

v1: **не делать** raycast (дорого на сервере без геометрии карты).

- Псевдо-occlusion: **2D grid + height layer** (опционально v2) — cell помечается «горный хребет» вручную в metadata карты
- v1 достаточно: **distance + cell** — «за 5 км» не в соседних cells → не реплицируется

### Клиент (Lua)

- [ ] `interestSync.lua` — тонкая обёртка: relay шлёт `interest_set` (список visible `player_id` + `net_id`) 2 Hz
- [ ] Скрывать/не спавнить puppets вне set (AI)
- [ ] Снизить приём DPUB для дальних игроков (не применять physics, только nametag?)

### Унификация с Stage 4 LOD

| | Stage 4 (host Lua) | Stage 6.3 (relay) |
|--|-------------------|-------------------|
| Кто решает | Host по дистанции до **своего** игрока | Relay по grid для **каждой пары** |
| Когда | 2 игрока, host authoritative AI | N игроков |

При переходе на dedicated: **отключить host-side LOD в `aiTrafficSync`** для публичных комнат, чтобы не конфликтовать — relay единственный источник truth.

### Критерии приёмки 6.3

1. 16× load_tester: без culling > X MB/s; с culling < 0.5× трафика при разбросе по карте 4 km².
2. Два игрока рядом видят друг друга 60 Hz; два игрока за 2 km — 0 DPUB между ними.
3. AI в соседней cell — TAIB идёт; AI за 10 cells — нет.

---

## Шаг 13 — 6.4 Bandwidth Governor

Единый лимитер на клиенте (и опционально relay):

| Класс трафика | Приоритет | Лимит (пример) |
|---------------|-----------|----------------|
| `connect` / `spawn` / reliable | Высший | без лимита |
| `DPUB` | Высокий | 60 Hz × visible players |
| `TAIB` | Средний | cap 200 KB/s |
| `AUDI` | Средний | 24 kbps × talkers |
| `world_props` | Низкий | 8 Hz, drop при переполнении |
| `damage` / chat | Низкий | best-effort |

- [ ] `bandwidthGovernor.lua` — token bucket per class
- [ ] Метрики в UI: «Network budget» % 
- [ ] При перегрузке: сначала режется TAIB zone B, потом дальние DPUB

---

## Шаг 15 — 6.5 UX голоса и рации

- [ ] **Push-to-talk** (default) + опция voice activation
- [ ] Канал **«Рация»** (слышно всю карту, низкий битрейт) vs **«Proximity»**
- [ ] Mute / block игрока
- [ ] Иконка «говорит» над машиной (как chat bubble)
- [ ] Привязка к `remoteNickname`

Зависит от 6.1; не требует отдельного протокола.

---

## Шаг 19 — 6.6 DPUB Delta Compression (*optional*)

Сейчас `UpdatePacket` = 92 B fixed. При 16 игроках × 60 Hz = много повторяющихся полей.

- [ ] Флаг пакета `DPUD` — delta от last state (pos quat vel + input bitmask)
- [ ] Full snapshot `DPUB` каждые 1 s
- [ ] Только после профилирования: выигрыш должен быть > 30% bandwidth

**Не начинать** до замеров на 6.3 + governor.

---

## Шаг 07 — 6.7 Геймплей и режимы сессии

Расширение `gameplaySync.lua` (уже есть `checkpoint`).  
**После шагов 01–06 и 03–04.** Работает в LAN 1×1 **до** relay (**08**).

### 6.7.1 Старт гонки (countdown)

- [ ] Host / sim-host шлёт `race_start`: `{ type, t0_unix, countdown_sec: 3 }`
- [ ] Все клиенты: UI 3-2-1-GO, блокировка газа до `t0` (опционально)
- [ ] Синхронизация с `gameplaySync` checkpoint timer (`_lapSessionStart`)

### 6.7.2 Режим «гонка»

- [ ] `session_mode: "race"` в join / lobby metadata
- [ ] Таблица кругов: checkpoint enter → `gameplaySync` → aggregate в UI
- [ ] Финиш: последний checkpoint / manual finish line trigger
- [ ] Результаты в overlay + опционально POST в matchmaking API (для 5.4 leaderboard)

### 6.7.3 Конвой / лидер

- [ ] `convoy_leader_id` — только его waypoint на карте (BeamNG mission API или manual marker)
- [ ] `convoy_ping` — маркер лидера для всех
- [ ] Ghost mode recommended в UI подсказке

### 6.7.4 Голосование карты / времени суток

- [ ] Перед стартом dedicated room: `vote_map`, `vote_time` (JSON reliable)
- [ ] Majority → `worldSync` host применяет env (или sim-host)
- [ ] В LAN — только host решает (без vote)

### 6.7.5 Режим «встреча» (meet)

- [ ] Preset: ghost on, damage off, AI sync off, низкий HUD
- [ ] Быстрый выбор в UI при создании LAN-сессии

### Новые JSON `type`

| `type` | Назначение |
|--------|------------|
| `race_start` | Синхронный старт |
| `race_result` | Время круга / финиш |
| `convoy_leader` | Смена лидера |
| `vote` | Голос игрока (map/time) |

### Критерии приёмки 6.7

1. LAN 1×1: host countdown — оба видят GO одновременно (±200 ms).
2. Checkpoint lap times совпадают в UI у обоих.
3. Dedicated: vote time → у всех одинаковое небо после majority.

---

## Шаг 16 — 6.8 Spectator

После **шага 08** (`remotePlayers` + multi-peer).

- [ ] `join` с флагом `spectator: true` — без spawn машины, без DPUB TX
- [ ] Камера: follow `player_id` / free cam (BeamNG camera API)
- [ ] Приём DPUB/TAIB всех игроков в радиусе interest (6.3)
- [ ] UI: список игроков → «Наблюдать»

**Зависимости:** 5.0 multi-peer, желательно 6.3 culling.

### Критерии приёмки 6.8

1. Игрок без машины видит двух других, переключение камеры работает.
2. Spectator не шлёт DPUB (нагрузка не растёт).

---

## Шаг 17 — 6.9 Полировка продукта

### 6.9.1 Локализация

- [ ] RU / EN строки в `app.html` / `app.js`
- [ ] Ключи ошибок `session_error.reason.*`

### 6.9.2 Privacy (VoIP)

- [ ] При первом включении Voice: «Микрофон передаётся другим игрокам…»
- [ ] Toggle off по умолчанию; ссылка на privacy в PLAYER_GUIDE

### 6.9.3 Police / pursuit (backlog Stage 4)

- [ ] Синхрон FSM полиции / pursuit target — отдельный reliable channel
- [ ] Расширить `lights` bitmask при необходимости
- [ ] Только если sim-host запускает traffic police — иначе out of scope

### 6.9.4 Shared garage preset

Перенесено в **[STAGE7 — 7.4](./STAGE7_CONTENT_MODS.md#фаза-74--shared-garage-preset-p0)** (приоритет P0).

### Критерии приёмки 6.9

1. UI переключается RU/EN без перезагрузки мода.
2. Voice toggle показывает privacy notice один раз.

---

## Вне этапа 6 (см. roadmap)

| Тема | Шаг | Документ |
|------|-----|----------|
| Сессия, версии, reconnect | 03–04 | [STAGE5](./STAGE5_SCALING.md) |
| Контент, моды, карты | 01–02, 05–06 | [STAGE7](./STAGE7_CONTENT_MODS.md) |
| Relay, matchmaking | 08–11 | [STAGE5](./STAGE5_SCALING.md) |

---

## Порядок внедрения (этап 6 в общей цепочке)

Полная последовательность: [ROADMAP_5_6_7.md](./ROADMAP_5_6_7.md).

| Шаг | Фаза | Когда начинать |
|-----|------|----------------|
| **07** | 6.7 | После **01–06**, **03–04** |
| **12** | 6.3 | После **09** |
| **13** | 6.4 | После **08** (можно параллельно с 12) |
| **14** | 6.1 | После **08**; желательно **12** |
| **15** | 6.5 | После **14** |
| **16** | 6.8 | После **08** |
| **17** | 6.9 | После **14** (privacy) или вместе с **11** (i18n) |
| **18** | 6.2 | *Optional* — только WAN P2P без **09** |
| **19** | 6.6 | *Optional* — после **12–13** + метрики |

---

## Сравнение с исходным ТЗ (что изменили)

| Исходное | Решение в плане |
|----------|----------------|
| C++ плагин BeamNG для звука | **Отложено** → bridge v1 (как KISS) |
| libsoundio/miniaudio + Opus FFI в игре | Opus в **bridge**; в игре только позиции + `AUDI` relay |
| STUN/TURN обязательно | **Только LAN P2P WAN**; при dedicated **не делаем** |
| Grid culling на «сервере» | **Да**, на C++ relay + унификация с AI LOD |
| Anti-cheat | **Убран** (Stage 5.5 исключён) |

---

## Новые файлы (целевая структура)

```
beamng_lan_multiplayer/
  lua/ge/extensions/
    sessionSync.lua        # → Stage 5.0.5
    vehicleSync.lua        # → Stage 5.0.5 (trailer)
    voiceSync.lua          # 6.1
    bandwidthGovernor.lua  # 6.4
    interestSync.lua       # 6.3
    raceSync.lua           # 6.7 (или расширить gameplaySync)
  tools/
    beamng-voice-bridge/   # 6.1
  docs/
    PLAYER_GUIDE.md        # → Stage 5.3
    STAGE5_SCALING.md
    STAGE6_EXPERIMENTAL.md

server/
  src/interest_grid.cpp    # 6.3
```

---

## Критерии готовности (этап 6)

| Шаг | Критерий |
|-----|----------|
| **07** | Общий countdown и круги в LAN 1×1 |
| **12–13** | Трафик не растёт линейно с числом объектов на карте |
| **14–15** | Proximity voice на dedicated, можно выключить |
| **17** | RU/EN + privacy при первом включении voice |

---

## Связанные документы

- [ROADMAP_5_6_7.md](./ROADMAP_5_6_7.md) — единый порядок **01–20**
- [STAGE5_SCALING.md](./STAGE5_SCALING.md) — шаги 03–04, 08–11
- [STAGE7_CONTENT_MODS.md](./STAGE7_CONTENT_MODS.md) — шаги 01–02, 05–06
- [STAGE4_AI_TRAFFIC.md](./STAGE4_AI_TRAFFIC.md) — TAIB LOD (предшественник 6.3 для AI)
