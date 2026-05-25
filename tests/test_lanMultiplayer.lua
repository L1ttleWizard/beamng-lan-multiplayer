-- Unit Tests for BeamNG LAN Multiplayer Lua Extension
local ffi = require("ffi")

local M = nil

-- Test assertions
local function assertEqual(expected, actual, msg)
    if expected ~= actual then
        error(string.format("Assertion failed: expected %s (%s), got %s (%s). %s", 
            tostring(expected), type(expected), tostring(actual), type(actual), msg or ""), 2)
    end
end

local function assertNear(expected, actual, tolerance, msg)
    if math.abs(expected - actual) > (tolerance or 0.0001) then
        error(string.format("Assertion failed: expected %f to be near %f (diff: %f, tolerance: %f). %s", 
            actual, expected, math.abs(expected - actual), tolerance or 0.0001, msg or ""), 2)
    end
end

local function assertTrue(condition, msg)
    if not condition then
        error(string.format("Assertion failed: expected true, got false. %s", msg or ""), 2)
    end
end

local function assertFalse(condition, msg)
    if condition then
        error(string.format("Assertion failed: expected false, got true. %s", msg or ""), 2)
    end
end

local function assertNotNil(val, msg)
    if val == nil then
        error(string.format("Assertion failed: expected value to be not nil. %s", msg or ""), 2)
    end
end

local function assertNil(val, msg)
    if val ~= nil then
        error(string.format("Assertion failed: expected value to be nil, got %s. %s", tostring(val), msg or ""), 2)
    end
end

-- Setup and Teardown
local function setup()
    be:reset()
    core_vehicles:reset()
    core_levels:reset()
    core_vehicleBridge:reset()
    guihooks:reset()
    debugDrawer:reset()
    
    -- Load clean extension
    package.loaded["lua/ge/extensions/lanMultiplayer"] = nil
    M = require("lua/ge/extensions/lanMultiplayer")
    M.onExtensionLoaded()
end

-- ============================================================================
-- TESTS
-- ============================================================================

tests = {}

-- 1. Configuration Minimizer Test
tests.testGetMinimizedConfig = function()
    local inputConfig = {
        parts = {
            engine = "stage1",
            spoiler = "none",
            lip = "",
            wheels = "sport"
        },
        vars = {
            camber = -0.5,
            toe = 0.0
        }
    }
    
    local minConfig = M.getMinimizedConfig(inputConfig)
    
    -- "none" and "" parts must be stripped
    assertEqual("stage1", minConfig.parts.engine)
    assertEqual("sport", minConfig.parts.wheels)
    assertNil(minConfig.parts.spoiler)
    assertNil(minConfig.parts.lip)
    
    -- vars must be retained
    assertEqual(-0.5, minConfig.vars.camber)
    assertEqual(0.0, minConfig.vars.toe)
end

-- 2. Configuration Safety Limit Test
tests.testGetSafeConfigPayload = function()
    -- Normal config
    local normalConfig = { parts = { engine = "stage1" } }
    local resNormal = M.getSafeConfigPayload(normalConfig)
    assertEqual("stage1", resNormal.parts.engine)
    
    -- Artificially huge configuration that would exceed 1000 characters
    local hugeConfig = { parts = {}, vars = { turboBoost = 2.5 } }
    for i = 1, 100 do
        hugeConfig.parts["custom_fender_slot_part_index_" .. i] = "very_long_custom_part_name_installed_on_chassis_" .. i
    end
    
    local resHuge = M.getSafeConfigPayload(hugeConfig)
    
    -- Config size exceeds 1000 bytes, parts must be dropped, but vars kept
    assertNil(resHuge.parts)
    assertNotNil(resHuge.vars)
    assertEqual(2.5, resHuge.vars.turboBoost)
end

-- 3. Configuration Comparison Test
tests.testAreConfigsEqual = function()
    local c1 = { parts = { a = "1", b = "2" } }
    local c2 = { parts = { b = "2", a = "1" } }
    local c3 = { parts = { a = "1", b = "3" } }
    
    assertTrue(M.areConfigsEqual(c1, c2), "Identical configs with different key orders should be equal")
    assertFalse(M.areConfigsEqual(c1, c3), "Configs with different values should not be equal")
    assertFalse(M.areConfigsEqual(c1, nil), "Comparing config to nil should be false")
end

-- 4. Raw Inputs Getter Test
tests.testGetInputsRaw = function()
    -- Set mocked inputs
    input.state.throttle.val = 0.75
    input.state.steering.val = -0.4
    input.state.brake.val = 0.1
    input.state.clutch.val = 0.2
    input.state.handbrake.val = 1.0
    
    local t, s, b, c, hb = M.getInputsRaw()
    
    assertEqual(0.75, t)
    assertEqual(-0.4, s)
    assertEqual(0.1, b)
    assertEqual(0.2, c)
    assertEqual(1.0, hb)
end

-- 5. Connection State Machine: Hosting Test
tests.testHostingState = function()
    local success = M.host(27015)
    assertTrue(success, "Host binding should succeed")
    
    assertEqual("HOSTING", guihooks.triggered["lanMultiplayerStatus"].status)
    assertEqual("HOST", guihooks.triggered["lanMultiplayerStatus"].role)
    assertEqual(27015, guihooks.triggered["lanMultiplayerStatus"].activePort)
end

-- 6. Connection State Machine: Client Connecting Test
tests.testConnectingState = function()
    local success = M.connect("192.168.1.100", 27015, 0)
    assertTrue(success, "Client connect and binding should succeed")
    
    assertEqual("CONNECTING", guihooks.triggered["lanMultiplayerStatus"].status)
    assertEqual("CLIENT", guihooks.triggered["lanMultiplayerStatus"].role)
    assertEqual("192.168.1.100", guihooks.triggered["lanMultiplayerStatus"].activeIp)
    assertEqual(27015, guihooks.triggered["lanMultiplayerStatus"].activeTargetPort)
    -- Ephemeral client port (mocked to 55555)
    assertEqual(55555, guihooks.triggered["lanMultiplayerStatus"].activePort)
end

-- 7. Disconnection Clean Up Test
tests.testDisconnectState = function()
    -- Connect client
    M.connect("192.168.1.100", 27015, 0)
    
    -- Set remote vehicle state
    local mockRemoteVehId = 1234
    createMockVehicle(mockRemoteVehId, "covet", nil)
    M.setRemoteVehicleId(mockRemoteVehId)
    
    -- Disconnect
    M.disconnect()
    
    assertEqual("IDLE", guihooks.triggered["lanMultiplayerStatus"].status)
    assertEqual("NONE", guihooks.triggered["lanMultiplayerStatus"].role)
    assertNil(M.getRemoteVehicleId())
    assertNil(be:getObjectByID(mockRemoteVehId), "Remote vehicle should be deleted on disconnect")
end

-- 8. FFI Binary Protocol: Serialization & Deserialization
tests.testFFIBinarySerialization = function()
    -- Establish active connection
    M.connect("127.0.0.1", 27015, 0)
    M.setState("CONNECTED")
    
    -- Get mock socket and clear previously sent packets
    local sock = package.loaded["socket"].getLastSocket()
    sock:clearSent()
    
    -- 1. Mock player vehicle
    local myVeh = createMockVehicle(1, "pickup", nil)
    myVeh.position = vec3(100.5, 200.75, 300.2)
    myVeh.rotation = quat(0.1, 0.2, 0.3, 0.9)
    myVeh.velocity = vec3(5.5, -6.2, 1.1)
    myVeh.angularVelocity = vec3(0.05, -0.02, 0.1)
    
    be.playerVehicle = myVeh
    M.inputExtrapEnabled = false
    
    -- Mock cached electrics for vehicle 1
    core_vehicleBridge.cachedData[1] = {
        rpm = 1500,
        wheelspeed = 25.5,
        gearIndex = 3,
        lights_state = 1,
        signal_L = true,
        signal_R = false,
        hazard = false,
        fog = true,
        lightbar = 0,
        horn = false
    }
    
    -- Mock driver inputs
    input.state.throttle.val = 0.9
    input.state.steering.val = 0.15
    input.state.brake.val = 0.0
    input.state.clutch.val = 0.0
    input.state.handbrake.val = 0.0
    
    -- 2. Trigger sendUpdate (serializes and sends raw packet)
    local startSeq = M.getTxSeq()
    M.sendUpdate()
    
    -- Validate packet structure
    assertEqual(1, #sock._sent)
    local sentPacket = sock._sent[1].data
    assertEqual(92, #sentPacket, "FFI update packet must be exactly 92 bytes")
    
    -- Validate FFI packet contents
    local ptr = ffi.cast("const uint32_t*", ffi.cast("const char*", sentPacket))
    assertEqual(0x42555044, ptr[0], "Magic number must be 0x42555044 ('BUPD')")
    assertEqual(startSeq + 1, ptr[1], "Sequence number must increment")
    
    -- 3. Receive and deserialize packet on remote side
    -- Set up remote vehicle mock
    local mockRemoteVehId = 4321
    local remoteVeh = createMockVehicle(mockRemoteVehId, "pickup", nil)
    M.setRemoteVehicleId(mockRemoteVehId)
    
    -- Queue the sent binary packet in the socket receive queue
    sock:queuePacket(sentPacket)
    
    -- Run receive loop (decodes packet and applies target states)
    M.receivePackets()
    
    -- Validate deserialized remote target values
    local targetPos = M.getRemoteTargetPos()
    local targetRot = M.getRemoteTargetRot()
    local targetVel = M.getRemoteTargetVel()
    local targetAngVel = M.getRemoteTargetAngVel()
    
    assertNotNil(targetPos)
    assertNear(100.5, targetPos.x)
    assertNear(200.75, targetPos.y)
    assertNear(300.2, targetPos.z)
    
    assertNotNil(targetRot)
    assertNear(0.1, targetRot.x)
    assertNear(0.2, targetRot.y)
    assertNear(0.3, targetRot.z)
    assertNear(0.9, targetRot.w)
    
    assertNotNil(targetVel)
    assertNear(5.5, targetVel.x)
    assertNear(-6.2, targetVel.y)
    assertNear(1.1, targetVel.z)
    
    assertNotNil(targetAngVel)
    assertNear(0.05, targetAngVel.x)
    assertNear(-0.02, targetAngVel.y)
    assertNear(0.1, targetAngVel.z)
    
    -- Trigger onUpdate to apply decoupled states and queue VM commands
    M.onUpdate(0.016, 0.016)
    
    -- Validate control inputs applied to remote vehicle Lua VM via globalSyncVeh helper
    assertEqual(1, #remoteVeh.queuedCommands)
    local cmd = remoteVeh.queuedCommands[1]
    assertTrue(cmd:find("globalSyncVeh") ~= nil, "Remote vehicle VM call should be globalSyncVeh")
    assertTrue(cmd:find("0.900000,0.150000") ~= nil, "Inputs must be passed to globalSyncVeh")
    assertTrue(cmd:find("1500") ~= nil, "RPM must be passed to globalSyncVeh")
    assertTrue(cmd:find("25.5") ~= nil, "Wheel speed must be passed to globalSyncVeh")
    assertTrue(cmd:find("3") ~= nil, "Gear must be passed to globalSyncVeh")
    assertTrue(cmd:find("19") ~= nil, "Lights bitmask (19) must be passed to globalSyncVeh")
end

-- 9. Adaptive Telemetry Rate Logic Test
tests.testAdaptiveSendRate = function()
    M.resetMetrics()
    local baseRate = M.getSendRate()
    
    -- High jitter/loss: rate should throttle down (interval increases)
    M.setPacketLoss(5.0) -- > 3%
    M.setJitter(60.0)    -- > 50ms
    M.adaptSendRate()
    
    local throttledRate = M.getSendRate()
    assertTrue(throttledRate > baseRate, "Rate should decrease (larger send interval) under network strain")
    
    -- Perfect network: rate should speed up again (interval decreases)
    M.setPacketLoss(0.0)
    M.setJitter(5.0)
    M.adaptSendRate()
    
    local recoveryRate = M.getSendRate()
    assertTrue(recoveryRate < throttledRate, "Rate should increase (smaller send interval) when network recovers")
end

-- 10. Update Loop and Debug Drawing Test
tests.testOnUpdateDrawing = function()
    -- Set up connected state
    M.connect("127.0.0.1", 27015, 0)
    M.setState("CONNECTED")
    
    -- Mock remote vehicle
    local mockRemoteVehId = 4321
    local remoteVeh = createMockVehicle(mockRemoteVehId, "pickup", nil)
    remoteVeh.position = vec3(10, 20, 30)
    M.setRemoteVehicleId(mockRemoteVehId)
    M.plcEnabled = false
    
    -- Set target state
    M.updateRemoteVehicle({
        t = "u",
        s = 1,
        p = { 10, 20, 30 },
        r = { 0, 0, 0, 1 },
        v = { 10, 0, 0 },  -- 10 m/s = 36 km/h
        a = { 0, 0, 0 },
        i = { 0, 0, 0, 0, 0 }
    })
    
    -- Call onUpdate to trigger drawing
    M.onUpdate(0.016, 0.016)
    
    -- Verify that drawings were added to debugDrawer
    assertEqual(2, #debugDrawer.drawnTexts, "Should draw exactly nickname and speed text")
    
    -- Check nickname drawing
    local draw1 = debugDrawer.drawnTexts[1]
    assertEqual("Friend", draw1.text)
    assertNear(10, draw1.pos.x)
    assertNear(20, draw1.pos.y)
    assertNear(32, draw1.pos.z) -- pos.z + 2.0
    
    -- Check speed drawing
    local draw2 = debugDrawer.drawnTexts[2]
    assertEqual("36 km/h", draw2.text)
    assertNear(10, draw2.pos.x)
    assertNear(20, draw2.pos.y)
    assertNear(31.5, draw2.pos.z) -- pos.z - 0.5 (from 32.0)
end

-- 11. Feature Toggles & Synchronization Decoupling Test
tests.testFeatureToggles = function()
    -- Set up connection
    M.connect("127.0.0.1", 27015, 0)
    M.setState("CONNECTED")
    
    -- Mock remote vehicle
    local mockRemoteVehId = 7777
    local remoteVeh = createMockVehicle(mockRemoteVehId, "covet", nil)
    M.setRemoteVehicleId(mockRemoteVehId)
    
    -- Test with all features enabled
    M.soundSyncEnabled = true
    M.wheelSyncEnabled = true
    M.lightsSyncEnabled = true
    M.damageSyncEnabled = true
    
    -- Build a mock FFI data packet
    local packet = ffi.new("UpdatePacket")
    packet.seq = 100
    packet.px, packet.py, packet.pz = 10, 20, 30
    packet.rpm = 2000
    packet.wheelSpeed = 30.0
    packet.gear = 4
    packet.lights = 7
    
    remoteVeh.queuedCommands = {}
    M.updateRemoteVehicleBinary(packet)
    M.onUpdate(0.016, 0.016)
    
    assertEqual(1, #remoteVeh.queuedCommands)
    local cmd = remoteVeh.queuedCommands[1]
    assertTrue(cmd:find("globalSyncVeh") ~= nil)
    assertTrue(cmd:find("2000.000000,4,30.000000,7") ~= nil, "Should pass RPM, gear, wheelSpeed, lights when enabled")
    
    -- Test with features disabled
    M.soundSyncEnabled = false
    M.wheelSyncEnabled = false
    M.lightsSyncEnabled = false
    
    -- Force update execution by setting updateCounter to 15 (heartbeat override)
    M._updateCounter = 15
    remoteVeh.queuedCommands = {}
    M.updateRemoteVehicleBinary(packet)
    M.onUpdate(0.016, 0.016)
    
    assertEqual(1, #remoteVeh.queuedCommands)
    local cmd2 = remoteVeh.queuedCommands[1]
    assertTrue(cmd2:find(",0,0,0") ~= nil, "Should pass 0 for sync parameters when disabled")
    
    -- Test damage sync toggle
    M.damageSyncEnabled = false
    local damageReported = false
    remoteVeh.queuedCommands = {}
    M.processPacket(jsonEncode({
        type = "damage",
        nodes = { ["1"] = { 0, 0, 0 } }
    }), "127.0.0.1", 27015)
    for _, c in ipairs(remoteVeh.queuedCommands) do
        if c:find("globalApplyDeformedNodes") then
            damageReported = true
        end
    end
    assertFalse(damageReported, "Damage should not be applied when damageSync is disabled")
end

-- 12. Dead Reckoning / Packet Skipping Test
tests.testDeadReckoning = function()
    M.resetMetrics()
    M.connect("127.0.0.1", 27015, 0)
    M.setState("CONNECTED")
    
    local sock = package.loaded["socket"].getLastSocket()
    sock:clearSent()
    
    -- Set up player vehicle mock
    local myVeh = createMockVehicle(1, "covet", nil)
    myVeh.position = vec3(0, 0, 0)
    myVeh.rotation = quat(0, 0, 0, 1)
    myVeh.velocity = vec3(10, 0, 0) -- 10 m/s along X
    be.playerVehicle = myVeh
    
    -- Enable network optimization
    M.networkOptimizationEnabled = true
    
    -- Send first update to initialize lastSentPos
    M.sendUpdate()
    assertEqual(1, #sock._sent, "First update should always be sent")
    sock:clearSent()
    
    -- Mock small elapsed time (0.016s) and exact matching movement (10 m/s * 0.016s = 0.16m along X)
    local originalClock = os.clock
    local timeOffset = 0.016
    os.clock = function() return originalClock() + timeOffset end
    
    myVeh.position = vec3(0.16, 0, 0)
    M.sendUpdate()
    assertEqual(0, #sock._sent, "Update should be skipped since error is 0 and inputs are unchanged")
    
    -- Mock deviation (actual position drifts from prediction by 0.1m, which is > 0.05m threshold)
    timeOffset = 0.032
    myVeh.position = vec3(0.32 + 0.1, 0, 0)
    M.sendUpdate()
    assertEqual(1, #sock._sent, "Update should be sent because prediction drift exceeds threshold")
    sock:clearSent()
    
    -- Restore clock
    os.clock = originalClock
end

-- 13. Adaptive Hz Toggle Test
tests.testAdaptiveHzToggle = function()
    M.resetMetrics()
    M.adaptiveHzEnabled = false
    
    -- Network stressed (would normally trigger rate change)
    M.setPacketLoss(10.0)
    M.setJitter(100.0)
    M.adaptSendRate()
    
    assertEqual(0.0166, M.getSendRate(), "sendRate should be locked to minSendRate when adaptiveHzEnabled is false")
    
    -- Network healthy (would normally trigger rate change)
    M.setPacketLoss(0.0)
    M.setJitter(0.0)
    M.adaptSendRate()
    
    assertEqual(0.0166, M.getSendRate(), "sendRate should remain minSendRate when adaptiveHzEnabled is false")
end

-- 14. Jitter Buffer Toggle Test
tests.testJitterBufferToggle = function()
    M.connect("127.0.0.1", 27015, 0)
    M.setState("CONNECTED")
    
    local mockRemoteVehId = 9999
    local remoteVeh = createMockVehicle(mockRemoteVehId, "covet", { parts = {} })
    remoteVeh.position = vec3(0, 0, 0)
    M.setRemoteVehicleId(mockRemoteVehId)
    
    -- Setup remote target pos and hasRemoteState = true
    M.updateRemoteVehicle({
        t = "u",
        p = { 10, 0, 0 },
        r = { 0, 0, 0, 1 },
        v = { 0, 0, 0 },
        a = { 0, 0, 0 },
        i = { 0, 0, 0, 0, 0 }
    })
    
    -- High jitter and packet loss
    M.setJitter(50.0)
    M.setPacketLoss(10.0)
    M.setState("CONNECTED")
    
    -- 1. Test with jitter buffer enabled (slower interpolation)
    M.jitterBufferEnabled = true
    remoteVeh.position = vec3(0, 0, 0)
    M.applySmoothedRemoteState(0.016)
    local posXWithBuffer = remoteVeh.position.x
    
    -- 2. Test with jitter buffer disabled (faster interpolation)
    M.jitterBufferEnabled = false
    remoteVeh.position = vec3(0, 0, 0)
    M.applySmoothedRemoteState(0.016)
    local posXWithoutBuffer = remoteVeh.position.x
    
    assertTrue(posXWithoutBuffer > posXWithBuffer, "Should converge faster (move further) when jitter buffer is disabled under network strain")
end

-- 15. PLC (DR) Toggle Test
tests.testPLCToggle = function()
    M.resetMetrics()
    M.connect("127.0.0.1", 27015, 0)
    M.setState("CONNECTED")
    
    -- Setup remote vehicle
    local mockRemoteVehId = 8888
    local remoteVeh = createMockVehicle(mockRemoteVehId, "covet", { parts = {} })
    M.setRemoteVehicleId(mockRemoteVehId)
    
    -- Set initial target state with velocity
    M.updateRemoteVehicle({
        t = "u",
        p = { 10, 0, 0 },
        r = { 0, 0, 0, 1 },
        v = { 5.0, 0, 0 },
        a = { 0, 0, 0 },
        i = { 0, 0, 0, 0, 0 }
    })
    
    -- 1. Test with PLC enabled (should extrapolate target position)
    M.plcEnabled = true
    remoteVeh.position = vec3(0, 0, 0)
    M.applySmoothedRemoteState(0.1)
    assertNear(9.9772, remoteVeh.position.x, 0.01, "Vehicle pos should converge towards the extrapolated position 10.5")
    
    -- 2. Test with PLC disabled (should NOT extrapolate)
    M.plcEnabled = false
    remoteVeh.position = vec3(0, 0, 0)
    M.applySmoothedRemoteState(0.1)
    assertNear(9.5021, remoteVeh.position.x, 0.01, "Vehicle pos should converge towards the non-extrapolated position 10.0")
end

-- 16. Tandem Scorer Test
tests.testTandemScorer = function()
    M.resetMetrics()
    M.connect("127.0.0.1", 27015, 0)
    M.setState("CONNECTED")
    
    -- Mock remote vehicle position/rotation/velocity
    local mockRemoteVehId = 1111
    local remoteVeh = createMockVehicle(mockRemoteVehId, "covet", { parts = {} })
    M.setRemoteVehicleId(mockRemoteVehId)
    
    -- Disable PLC extrapolation for scorer test so distance doesn't drift
    M.plcEnabled = false
    
    -- Update remote vehicle to drift at 15 degrees:
    -- Z rotation quaternion for -75 degrees to rotate (0,1,0) into (cos 15, sin 15, 0)
    M.updateRemoteVehicle({
        t = "u",
        p = { 5.0, 0.0, 0.0 },
        r = { 0, 0, 0.6087614, 0.7933533 },
        v = { 10.0, 0, 0 },
        a = { 0, 0, 0 },
        i = { 0, 0, 0, 0, 0 }
    })
    
    -- Mock player vehicle
    local myVeh = createMockVehicle(2, "covet", { parts = {} })
    myVeh.position = vec3(0, 0, 0)
    myVeh.velocity = vec3(10.0, 0, 0)
    be.playerVehicle = myVeh
    
    -- Trigger onUpdate to calculate tandem metrics. Both vehicles drift at 15 degrees.
    myVeh.getDirectionVector = function() return vec3(0.9659258, 0.258819, 0) end
    
    -- Trigger 10Hz tick in onUpdate (we set uiTelemetryTimer to 0.1 to force the tick)
    M._uiTelemetryTimer = 0.1
    M.onUpdate(0.1, 0.1)
    
    local tandemData = guihooks.triggered["lanMultiplayerTandemUpdate"]
    assertNotNil(tandemData)
    assertEqual(5.0, tandemData.dist)
    assertNear(0.0, tandemData.speedDiff, 0.01)
    assertNear(0.0, tandemData.angleDiff, 0.01)
    assertTrue(tandemData.score > 0, "Tandem score should accumulate when drifting in close proximity")
end

-- 17. Recovery Sync Test
tests.testRecoverySync = function()
    M.resetMetrics()
    M.connect("127.0.0.1", 27015, 0)
    M.setState("CONNECTED")
    
    local sock = package.loaded["socket"].getLastSocket()
    sock:clearSent()
    
    local myVeh = createMockVehicle(2, "covet", { parts = {} })
    myVeh.position = vec3(0, 0, 0)
    be.playerVehicle = myVeh
    
    -- Initialize prevLocalPos
    M.onUpdate(0.02, 0.02)
    sock:clearSent()
    
    -- 1. Test sender-side recovery detection
    M.recoverySyncEnabled = true
    myVeh.position = vec3(15.0, 0, 0) -- massive snap (> 10m)
    myVeh.velocity = vec3(0, 0, 0)
    
    -- Force sendUpdate by setting sendTimer
    M.onUpdate(0.02, 0.02)
    
    local sentRecovery = false
    for _, packet in ipairs(sock._sent) do
        if #packet.data ~= 92 then
            local msg = jsonDecode(packet.data)
            if msg and msg.type == "recovery" then
                sentRecovery = true
                assertEqual(15.0, msg.pos.x)
            end
        end
    end
    assertTrue(sentRecovery, "Recovery packet should be transmitted upon local positional snap")
    
    -- 2. Test receiver-side recovery application
    local mockRemoteVehId = 7777
    local remoteVeh = createMockVehicle(mockRemoteVehId, "covet", { parts = {} })
    M.setRemoteVehicleId(mockRemoteVehId)
    
    remoteVeh.position = vec3(0, 0, 0)
    M.processPacket(jsonEncode({
        type = "recovery",
        pos = { x = 25.0, y = 0.0, z = 0.0 },
        rot = { x = 0, y = 0, z = 0, w = 1 }
    }), "127.0.0.1", 27015)
    
    assertEqual(25.0, remoteVeh.position.x, "Remote vehicle should instantly snap to recovery coordinates")
end

-- 18. Exhaust Backfire Sync Test
tests.testExhaustBackfireSync = function()
    M.resetMetrics()
    M.connect("127.0.0.1", 27015, 0)
    M.setState("CONNECTED")
    
    local sock = package.loaded["socket"].getLastSocket()
    sock:clearSent()
    
    local myVeh = createMockVehicle(2, "covet", { parts = {} })
    be.playerVehicle = myVeh
    
    -- Mock cached backfire value
    core_vehicleBridge.cachedData[2] = { backfire = 1 }
    
    M.backfireSyncEnabled = true
    M.onUpdate(0.02, 0.02)
    
    local sentBackfire = false
    for _, packet in ipairs(sock._sent) do
        if #packet.data ~= 92 then
            local msg = jsonDecode(packet.data)
            if msg and msg.type == "backfire" then
                sentBackfire = true
            end
        end
    end
    assertTrue(sentBackfire, "Backfire sync packet should be sent when local vehicle registers backfire")
    
    -- 2. Test receiver-side backfire trigger
    local mockRemoteVehId = 7777
    local remoteVeh = createMockVehicle(mockRemoteVehId, "covet", { parts = {} })
    M.setRemoteVehicleId(mockRemoteVehId)
    
    remoteVeh.queuedCommands = {}
    M.processPacket(jsonEncode({ type = "backfire" }), "127.0.0.1", 27015)
    
    assertEqual(1, #remoteVeh.queuedCommands)
    assertTrue(remoteVeh.queuedCommands[1]:find("exhaust.backfire") ~= nil, "Should trigger backfire in remote vehicle VM")
end

-- 19. Part Config Change Sync Test
tests.testPartConfigChangeSync = function()
    M.resetMetrics()
    M.connect("127.0.0.1", 27015, 0)
    M.setState("CONNECTED")
    
    local sock = package.loaded["socket"].getLastSocket()
    sock:clearSent()
    
    local myVeh = createMockVehicle(2, "covet", { parts = { engine = "stage1" } })
    be.playerVehicle = myVeh
    
    M.tuningSyncEnabled = true
    M.onPartConfigChanged(2)
    
    local sentSpawn = false
    for _, packet in ipairs(sock._sent) do
        local msg = jsonDecode(packet.data)
        if msg and msg.type == "spawn" then
            sentSpawn = true
            assertEqual("stage1", msg.config.parts.engine)
        end
    end
    assertTrue(sentSpawn, "Spawn packet should be sent on part configuration change")
end

-- ============================================================================
-- TEST RUNNER ENGINE
-- ============================================================================

local function runSuite()
    print("\n==============================================")
    print("RUNNING BEAMNG MULTIPLAYER LUA UNIT TEST SUITE")
    print("==============================================\n")
    
    local passed = 0
    local failed = 0
    local failedNames = {}
    
    local sortedNames = {}
    for name, _ in pairs(tests) do
        table.insert(sortedNames, name)
    end
    table.sort(sortedNames)
    
    for _, name in ipairs(sortedNames) do
        local func = tests[name]
        io.write(string.format("Running %-35s ... ", name))
        
        setup()
        
        local ok, err = pcall(func)
        if ok then
            passed = passed + 1
            print("\27[32m[PASS]\27[0m")
        else
            failed = failed + 1
            table.insert(failedNames, name)
            print("\27[31m[FAIL]\27[0m")
            print("  Error: " .. tostring(err) .. "\n")
        end
    end
    
    print("\n----------------------------------------------")
    print(string.format("RESULTS: Passed: %d | Failed: %d / %d", passed, failed, passed + failed))
    print("----------------------------------------------")
    
    if failed > 0 then
        print("\nFailed Tests:")
        for _, name in ipairs(failedNames) do
            print("  - " .. name)
        end
        print("\n==============================================\n")
        os.exit(1)
    else
        print("\nAll tests passed successfully!")
        print("==============================================\n")
        os.exit(0)
    end
end

runSuite()
