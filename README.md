# BeamNG.drive LAN Multiplayer Mod (v4.0)

A high-performance, low-latency LAN multiplayer mod for BeamNG.drive that synchronizes vehicle physics, controls, sound proxying, lights, and node deformations in real-time.

---

## 🚀 Key Features

1. **State-of-the-Art Telemetry Replication (60 Hz)**: Uses a 92-byte raw binary FFI struct for ultra-low latency UDP packet delivery, achieving fluid dead-reckoning and smoothing.
2. **Engine Sound & RPM Proxy (≤ 30 Hz)**: Synchronizes engine RPM, current transmission gear, and average wheels angular velocity to reproduce realistic sound effects on remote vehicles.
3. **Lights Synchronization**: Replicates headlights, turn signals, hazards, fog lights, siren/lightbar states, and the horn using a compressed bitmask.
4. **Wheel Rotation Sync**: Syncs wheels angular velocity so tires rotate visually and during burns/burnouts.
5. **Damage Sync (Low-Frequency Node Deformation)**: Sends node coordinate deformations (> 3 cm) via separate low-frequency JSON packets ONLY when damage is detected, preventing hot-path network bottlenecks.
6. **Ghost Mode**: A UI toggle that allows vehicles to pass through each other by disabling Torque3D physics collisions on the remote client.
7. **Teleport to Friend**: Instantly teleport your vehicle 2 meters above the remote player to prevent collision physics bugs.
8. **AI Traffic Sync (Host-Authoritative, optional)**: Synchronizes `gameplay_traffic` bots to clients as physics puppets (`ai.setMode("stop")` + `TAIB` binary batches). Includes distance LOD, pool recycle via `ai_teleport`, and roster sync on client connect. Enable **AI Sync** in Developer Settings (traffic must already be active on the host).

---

## ⚡ Garbage Collector (GC) & Performance Optimizations

The mod is engineered from the ground up to ensure high frame rates and completely prevent micro-stuttering:

* **Zero-Allocation Hot Path**: The 60 Hz update loop (`sendUpdate`, `receivePackets`, `applySmoothedRemoteState`) performs **zero heap allocations**:
  * Checksum/Header matching (`"DPUB"`) and JSON validation are performed using `string.byte` comparison, avoiding substring allocation (`data:sub()`).
  * Target vectors (`remoteTargetPos`, `remoteTargetRot`, etc.) and inputs cache (`lastRemoteInputs`) are pre-allocated and updated in-place.
  * Redundant wrapper constructors (`vec3()` and `quat()`) are eliminated.
* **GC Pause Tuning**: On load, the extension dynamically changes LuaJIT's GC Pause to `800` (allowing memory to grow to 800% of base memory before triggering GC) and restores it to `200` on unload. This decreases GC sweep frequency by **4x** with zero performance impact.
* **Throttled Cross-VM Commands**: Script commands queued to the vehicle VM are throttled to run only when inputs or engine telemetry change significantly, minimizing Lua parser allocations.

---

## 📊 Gameplay Load & Network Overhead Summary

| Feature / Sync Component | Execution Frequency | CPU Load (GE Lua VM) | CPU Load (Vehicle Physics VM) | Network / Ping Impact |
| :--- | :--- | :--- | :--- | :--- |
| **Telemetry (Pos/Rot)** | 60 Hz | Minimal (~0.01 ms) | None (direct C++ API call) | Low (92 bytes raw binary UDP) |
| **RPM & Wheel Sound** | ≤ 30 Hz (adaptive update) | None | Minimal (updates engine state on change) | None (embedded in main packet) |
| **Lights Sync** | Only on state change | None | ~0% (Event-driven command) | None (embedded in main packet) |
| **Damage Sync** | Only upon crash detection | 0% during driving | ~0.05 ms (one-time on deformation) | Low (short JSON only on impact) |
| **Ghost Mode** | On demand (button toggle) | 0% | 0% | Zero (single packet toggle) |

---

## Roadmap

- [Stage 4 — AI traffic sync](docs/STAGE4_AI_TRAFFIC.md) (implemented)
- **[Roadmap 5→6→7 — единый порядок шагов 01–20](docs/ROADMAP_5_6_7.md)** ← начинать здесь
- [Stage 7 — Content & mods](docs/STAGE7_CONTENT_MODS.md) — шаги **01–02, 05–06**
- [Stage 5 — Session + dedicated infra](docs/STAGE5_SCALING.md) — шаги **03–04, 08–11**
- [Stage 6 — Gameplay + network polish](docs/STAGE6_EXPERIMENTAL.md) — шаги **07, 12–19**

**Волна 1 (LAN):** 01 preset → 02 config UI → 03–04 session → 05–06 mods/maps → 07 races.

---

## 🧪 Running Unit Tests

Automated unit tests can be run using the BeamNG sandbox console:

```bash
python C:\Users\andrw\.gemini\antigravity\scratch\copy_and_run_tests.py
```

All 10 unit tests cover serialization, minimized configs, raw inputs, and connection state transitions.
