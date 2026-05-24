# Stage 1: Foundation and Test Infrastructure Implementation

This Pull Request implements the Stage 1 milestones specified in the evolution plan, addressing physics interpolation precision, rotation stability, net emulator controls, and automated test orchestration.

## 🛠️ Key Changes

### 1. Physics & Motion Extrapolation (PLC)
- **Time-Based Dead Reckoning**: Moved position extrapolation calculation from cumulative frame-rate dependent `dtReal` to absolute time difference using `socket.gettime() - M._lastPacketTimestamp`. This guarantees smooth motion regardless of rendering frame drops.
- **UI Developer Settings**: Added checkboxes to toggle **PLC (Packet Loss Concealment)** and **Time-Based Extrapolation** dynamically in the Developer menu. Settings state is synchronized with the Lua back-end.

### 2. Rotation Stability (Quaternion Hemisphere Check)
- **360-Degree Flipping Fix**: Added a hemisphere verification check (dot product of current and target quaternions). If the dot product is negative, components of the target quaternion are negated, enforcing the shortest-path interpolation (NLerp).
- **Hemisphere Toggle**: Integrated a dedicated developer toggle switch in the UI.

### 3. Network Emulator & Profiling Metrics
- **Lua Net Emulator**: Implemented simulated packet drop and artificial jitter delay queueing (`_jitterQueue`) directly in the socket receive loop.
- **Developer Controls & Sliders**: Added a "Network Emulator" toggle and sliders for **Drop Rate** (0%-100%) and **Jitter Max** (0-500 ms) to dynamically modify network conditions.
- **Load Status Panel**: Real-time display of **Active UDP Sessions** and **Processing Frame Time** (in ms) directly in the UI.

### 4. Load Testing & Docker Orchestration
- **Load Tester**: Created a Python script `tests/load_tester.py` to emulate clients connecting and streaming binary circular-motion telemetry packets.
- **Docker Integration**: Added `tests/Dockerfile` and `tests/docker-compose.yml` to orchestrate 10-50 containerized client instances running in parallel for load-testing the Lua server.

### 5. Automated Unit Tests
- Updated `tests/test_lanMultiplayer.lua` with test cases:
  - `testPLCToggle`
  - `testQuaternionHemisphereCheck`
  - `testNetworkEmulator`
- **Verification**: Verified that all 21 unit tests pass successfully.

---
## 🧪 Verification & Output

1. **Lua Unit Tests**: Passed successfully on the BeamNG console.
```
==============================================
RUNNING BEAMNG MULTIPLAYER LUA UNIT TEST SUITE
==============================================
Running testAdaptiveHzToggle                ... [PASS]
Running testAdaptiveSendRate                ... [PASS]
...
RESULTS: Passed: 21 | Failed: 0 / 21
All tests passed successfully!
==============================================
```
2. **Mod Packaging**: Built the zip bundle successfully, ensuring proper forward-slashes formatting for BeamNG.
