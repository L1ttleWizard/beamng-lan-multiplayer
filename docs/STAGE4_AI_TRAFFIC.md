# Этап 4: Синхронизация ИИ-трафика (Host-Authoritative)

План и статус имплементации для мода `beamng_lan_multiplayer`.

## Статус

| Фаза | Содержание | Статус |
|------|------------|--------|
| **4a** | Registry + `ai_spawn`/`ai_despawn` + `ai.setMode("stop")` | Готово |
| **4b** | Kinematics через batch | Готово |
| **4c** | FFI batch + magic `TAIB` | Готово |
| **4d** | LOD 100/500 m | Готово |
| **4e** | `ai_teleport`, roster sync, метрики, PLC rot, тесты | Готово |

**Не входит (по решению):** автозапуск `gameplay_traffic` на хосте при connect — traffic должен быть включён вручную в сессии.

## Архитектура

```
Хост (Мастер)                          Клиент (Марионетки)
gameplay_traffic + ai traffic          ai.setMode("stop")
     │                                      ▲
     ▼                                      │
реестр netId → gameId ── ai_spawn ──────────┤ spawn + stop AI
     │         ai_teleport (pool recycle)    │
     ▼                                      │
сбор pos/rot/vel + LOD ── TAIB (UDP) ──────┘ applyBatch + PLC
```

При подключении клиента хост вызывает `syncRosterToClient()` — повторная отправка `ai_spawn` для всех активных traffic-машин.

## Сообщения

| Тип | Канал | Назначение |
|-----|-------|------------|
| `ai_spawn` | Reliable JSON | Создать марионетку на клиенте |
| `ai_despawn` | Reliable JSON | Удалить марионетку |
| `ai_teleport` | Reliable JSON | Телепорт при recycle пула (тот же `net_id`) |
| `TAIB` | UDP binary | Батч до 15× `AISnapshot` (30 B каждый) |

### Pool recycle (хост)

1. `gameId` исчез из `getTrafficList()`.
2. Если появился новый `gameId` с той же моделью в радиусе 800 m — **remap** + `ai_teleport` (стабильный `netId`).
3. Иначе grace 350 ms → `ai_despawn`.
4. Непарные новые машины → `ai_spawn`.

## LOD

| Зона | Дистанция | Частота |
|------|-----------|---------|
| A | 0–100 m | 60 Hz |
| B | 100–500 m | 10 Hz |
| C | > 500 m | не отправляется |

## Файлы

- `lua/ge/extensions/aiTrafficSync.lua` — основная логика
- `lua/ge/extensions/lanMultiplayer.lua` — хуки, флаги, метрики
- `ui/modules/apps/LanMultiplayer/` — toggles + AI metrics
- `tests/test_lanMultiplayer.lua` — unit-тесты FFI/LOD/batch/teleport

## UI

Developer Settings → **AI Traffic**:

- **AI Sync** — включить host-authoritative traffic
- **AI PLC** — экстраполяция марионеток (можно отключить отдельно)

Метрики (CONNECTED): **AI Puppets**, **AI TX/RX KB/s**.

## Критерии приёмки

1. Хост с активным traffic — клиент видит те же модели (зона A ±1 m).
2. Клиент не симулирует локальный traffic при включённом sync.
3. Recycle пула не вызывает despawn+spawn flicker (используется `ai_teleport`).
4. Reconnect клиента получает полный roster через `syncRosterToClient`.
5. Toggle OFF — `TAIB` и AI JSON игнорируются.
6. Unit-тесты: `testAiSnapshotSize`, `testAiQuatCompressRoundtrip`, `testAiLodZone`, `testAiBatchEncodeDecode`, `testAiTeleportPacket`, `testAiTrafficSyncToggle`.

## Backlog

- Автозапуск traffic на хосте при connect
- Парковочные машины, damage AI, police FSM
- Per-client LOD при N>2 игроков
