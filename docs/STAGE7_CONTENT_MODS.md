# Этап 7: Контент и моды

Совместимость **модов**, **карт** и **конфигов машин**. Первый блок roadmap после Stage 4 (AI).

> **Глобальный порядок:** [ROADMAP_5_6_7.md](./ROADMAP_5_6_7.md).  
> Этап 7: **шаги 01 → 02 → 05 → 06**, затем [STAGE5](./STAGE5_SCALING.md) **03–04**, [STAGE6](./STAGE6_EXPERIMENTAL.md) **07**.

## Статус (порядок выполнения)

| Шаг | Фаза | Содержание | Статус |
|-----|------|------------|--------|
| **01** | **7.4** | Shared garage preset | Не начато |
| **02** | **7.3** | `config_truncated` + UI | Частично (cap 1000 B) |
| **05** | **7.1** | `mods_hash` / warning automation | Не начато |
| **06** | **7.2** | Кастомные карты + preload | Частично (`mapPath`) |

**Следующий после 06:** шаг **03** (версии и reconnect) — [STAGE5 § 5.0.5](./STAGE5_SCALING.md#фаза-505--сессия-и-совместимость-интеграция-продуктового-слоя).

---

## Текущее состояние (as-is)

| Область | Код / поведение |
|---------|------------------|
| **Config cap** | `getSafeConfigPayload()` — JSON ≤ **1000 B** |
| **Карта** | `mapPath` в handshake; `checkAndLoadMap()` → `startLevel` |
| **Моды** | Не сравниваются |
| **Пресет** | Нет |

---

## Шаг 01 — 7.4 Shared garage preset

**Цель:** обмен **коротким пресетом** (модель + vars + paint), не полным `config`.

### 7.4.1 Формат `GaragePreset` v1

```json
{
  "v": 1,
  "model": "etk800",
  "vars": { "licenseText": "MP" },
  "paint": { },
  "label": "Drift build"
}
```

- [ ] Код: `BLMP-` + base32/base64url, target **< 400 B**
- [ ] Файл: `.blmpreset`

### 7.4.2 Протокол

| `type` | Описание |
|--------|----------|
| `garage_preset_offer` | `{ preset_code, from_nickname }` |
| `garage_preset_request` | запрос пресета |
| `garage_preset_apply` | локальное применение |

- [ ] UI: **Экспорт** → clipboard; **Вставить код** → preview → Apply
- [ ] Опционально: отправка кода в `chat`

### 7.4.3 Применение

- [ ] `contentSync.applyGaragePreset(preset)` → merge vars/paint → `spawn`
- [ ] После apply — обычный `spawn` + флаг **шага 02** при переполнении

### Критерии приёмки (шаг 01)

1. A экспортирует код → B применяет → та же модель и основной вид.
2. Код < 500 символов для типичного пресета.

---

## Шаг 02 — 7.3 Лимит config (UI и wire flag)

**As-is:** `getSafeConfigPayload()` в `lanMultiplayer.lua`.

### 7.3.1 Wire

- [ ] `config_truncated: true` + `config_truncated_reason` в `spawn` / `connect_ack`
- [ ] `getSafeConfigPayload` возвращает `{ config, truncated, reason }`

### 7.3.2 UI

- [ ] Отправитель: «Конфиг урезан (>1000 B). Друг видит stock.»
- [ ] Получатель: «Конфиг друга упрощён — возможен stock.»
- [ ] Подсказка: «Поделиться пресетом» → **шаг 01**

### Критерии приёмки (шаг 02)

1. Huge config → баннер у обоих; remote stock/vars-only.
2. Unit test на >1000 B проверяет флаг.

---

## Шаг 05 — 7.1 `mods_hash` и список модов

**После шага 03** (расширенный `connect`). Предупреждение про **automation** / traffic packs — не hard fail.

### 7.1.1 Fingerprint

- [ ] `contentSync.getModsFingerprint()` → `mods_hash`, `mods_count`, `mods_sample[]`

### 7.1.2 LAN handshake

```json
{
  "mods_hash": "sha256:…",
  "mods_count": 12,
  "mods_sample": ["automation_xyz"]
}
```

- [ ] Warning UI при несовпадении hash
- [ ] **Продолжить** / **Показать отличия**

### 7.1.3 Dedicated (шаг 10)

- [ ] `mods_hash` в register/list; колонка **Mods** ✓/⚠

### Критерии приёмки (шаг 05)

1. Разный traffic-mod → жёлтый баннер, сессия идёт.
2. Dedicated list показывает совместимость.

---

## Шаг 06 — 7.2 Кастомные карты

**После 05** (тот же handshake). Улучшение `checkAndLoadMap`.

### 7.2.1 Контракт

```json
{
  "mapPath": "levels/my_map/info.json",
  "map_title": "My Map",
  "map_preload_hint": "https://…"
}
```

### 7.2.2 Missing map UX

- [ ] Проверка exists **до** `startLevel`
- [ ] UI + ссылка, если карты нет
- [ ] `map_change` при смене карты host mid-session

### 7.2.3 Register (шаг 10)

- [ ] `map_title` в lobby / server list

### Критерии приёмки (шаг 06)

1. Client без карты — баннер, не silent fail.
2. Client с картой — auto load как сейчас.

---

## Модуль и файлы

```
lua/ge/extensions/contentSync.lua   # шаги 01, 02, 05, 06
ui/modules/apps/LanMultiplayer/    # баннеры, preset UI
tests/test_contentSync.lua
```

---

## Порядок внедрения (этап 7)

| Шаг | Делать | Не начинать до |
|-----|--------|----------------|
| **01** | 7.4 preset | — |
| **02** | 7.3 config UI | **01** |
| **05** | 7.1 mods | **03** (handshake) |
| **06** | 7.2 maps | **05** |

Полная цепочка: [ROADMAP_5_6_7.md](./ROADMAP_5_6_7.md).

---

## Связанные документы

- [ROADMAP_5_6_7.md](./ROADMAP_5_6_7.md)
- [STAGE5_SCALING.md](./STAGE5_SCALING.md) — шаги 03–04, 10
- [STAGE6_EXPERIMENTAL.md](./STAGE6_EXPERIMENTAL.md) — шаг 07
- [STAGE4_AI_TRAFFIC.md](./STAGE4_AI_TRAFFIC.md)
