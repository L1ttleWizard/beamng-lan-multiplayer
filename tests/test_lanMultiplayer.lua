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

local function quatDot(a, b)
    return math.abs(a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w)
end

local function assertQuatSameOrientation(expected, actual, msg)
    local dot = quatDot(expected, actual)
    if dot < 0.99 then
        error(string.format(
            "Assertion failed: quaternions differ (dot=%f, need >= 0.99). expected (%f,%f,%f,%f) actual (%f,%f,%f,%f). %s",
            dot, expected.x, expected.y, expected.z, expected.w,
            actual.x, actual.y, actual.z, actual.w, msg or ""), 2)
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
    package.loaded["lua/ge/extensions/worldSync"] = nil
    package.loaded["lua/ge/extensions/gameplaySync"] = nil
    package.loaded["lua/ge/extensions/aiTrafficSync"] = nil
    M = require("lua/ge/extensions/lanMultiplayer")
    extensions = extensions or {}
    extensions.load = function(name)
        if name == "worldSync" then
            extensions.worldSync = require("lua/ge/extensions/worldSync")
        elseif name == "gameplaySync" then
            extensions.gameplaySync = require("lua/ge/extensions/gameplaySync")
        elseif name == "aiTrafficSync" then
            extensions.aiTrafficSync = require("lua/ge/extensions/aiTrafficSync")
        end
    end
    extensions.lanMultiplayer = M
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
    -- Same encoding as sendUpdate: quatFromDir(-direction, up), not raw getRotation()
    local expectedRot = quatFromDir(-myVeh:getDirectionVector(), myVeh:getDirectionVectorUp())
    assertQuatSameOrientation(expectedRot, targetRot, "FFI rotation must match direction-vector encoding")
    
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

-- 20. JBeam Rotation Alignment Test
tests.testJBeamRotationAlignment = function()
    M.resetMetrics()
    M.connect("127.0.0.1", 27015, 0)
    M.setState("CONNECTED")
    
    local mockRemoteVehId = 7777
    local remoteVeh = createMockVehicle(mockRemoteVehId, "covet", { parts = {} })
    M.setRemoteVehicleId(mockRemoteVehId)
    
    -- Mock JBeam method suite
    remoteVeh.getRefNodeId = function() return 1 end
    remoteVeh.getClusterRotationSlow = function(self, refId)
        return self.rotation.x, self.rotation.y, self.rotation.z, self.rotation.w
    end
    
    local lastClusterPos = nil
    local lastClusterRot = nil
    remoteVeh.setClusterPosRelRot = function(self, refId, x, y, z, rx, ry, rz, rw)
        lastClusterPos = vec3(x, y, z)
        lastClusterRot = quat(rx, ry, rz, rw)
        self.position = vec3(x, y, z)
    end
    remoteVeh.setPositionNoPhysicsReset = function(self, pos)
        lastClusterPos = vec3(pos)
        self.position = vec3(pos)
    end
    
    local lastOriginalPos = nil
    local lastOriginalRot = nil
    remoteVeh.setOriginalTransform = function(self, x, y, z, rx, ry, rz, rw)
        lastOriginalPos = vec3(x, y, z)
        lastOriginalRot = quat(rx, ry, rz, rw)
        self.rotation = quat(rx, ry, rz, rw)
        lastClusterRot = quat(rx, ry, rz, rw)
    end
    
    remoteVeh.applyClusterVelocityScaleAdd = function(self, refId, vx, vy, vz, scale)
        -- no-op
    end
    
    -- Set target state (90 degrees around Z axis)
    M.updateRemoteVehicle({
        t = "u",
        p = { 10.0, 20.0, 30.0 },
        r = { 0.0, 0.0, 0.7071068, 0.7071068 },
        v = { 0.0, 0.0, 0.0 },
        a = { 0.0, 0.0, 0.0 },
        i = { 0, 0, 0, 0, 0 }
    })
    
    M.forceFallback = false
    M.plcEnabled = false
    
    -- Frame 1: trigger update
    M.applySmoothedRemoteState(0.1)
    
    assertNotNil(lastOriginalPos)
    assertNotNil(lastOriginalRot)
    assertNotNil(lastClusterPos)
    assertNotNil(lastClusterRot)
    
    -- JBeam rotation should have started converging
    assertTrue(lastOriginalRot.z > 0.0, "Should interpolate towards target rotation")
    
    -- Converge fully over multiple frames
    for i = 1, 50 do
        M.applySmoothedRemoteState(0.1)
    end
    
    -- After convergence, original transform must match target rotation
    assertNear(0.0, lastOriginalRot.x)
    assertNear(0.0, lastOriginalRot.y)
    assertNear(0.7071068, lastOriginalRot.z, 0.01)
    assertNear(0.7071068, lastOriginalRot.w, 0.01)
    
    -- Relative rotation converges to target rotation (since spawn rotation is identity)
    assertNear(0.0, lastClusterRot.x)
    assertNear(0.0, lastClusterRot.y)
    assertNear(0.7071068, lastClusterRot.z, 0.01)
    assertNear(0.7071068, lastClusterRot.w, 0.01)
end

-- 21. Reliable UDP Transmission & ACK logic
tests.testReliableUDP = function()
    -- Initialize states
    M.setState("CONNECTED")
    M.setRole("CLIENT")
    M.resetMetrics()
    
    -- Send chat message which triggers sendPacketReliable
    M.chatMessage("Hello peer!")
    
    -- Check that seq increments to 1, and pending table has 1 item
    assertEqual(1, M._reliableSeq)
    local pending = M._pendingReliablePackets
    local count = 0
    local pkt = nil
    for id, p in pairs(pending) do
        count = count + 1
        pkt = p
    end
    assertEqual(1, count)
    assertNotNil(pkt)
    assertEqual(0, pkt.data.msg_id)
    assertEqual("chat", pkt.data.type)
    assertEqual(0, pkt.retries)
    
    -- Processing an ACK packet should clear the queue
    local ackPacket = '{"type":"ack","msg_id":0}'
    M.processPacket(ackPacket, "127.0.0.1", 27015)
    
    count = 0
    for id, p in pairs(pending) do
        count = count + 1
    end
    assertEqual(0, count)
    
    -- Send another packet to test retry timeouts and disconnects
    M.chatMessage("Goodbye!")
    
    -- Advance clock and trigger updates to simulate packet loss and retry limit
    local fakeClock = os.clock()
    local originalClock = os.clock
    os.clock = function() return fakeClock end
    
    for i = 1, 11 do
        fakeClock = fakeClock + 0.25
        M.onUpdate(0.25, 0.25)
    end
    
    os.clock = originalClock
    
    -- After 10 failed retries, it must disconnect and clear metrics
    assertEqual("IDLE", guihooks.triggered["lanMultiplayerStatus"].status)
    assertEqual("NONE", guihooks.triggered["lanMultiplayerStatus"].role)
end

-- 22. Spawn / Despawn Lifecycle Culling and Mapping
tests.testSpawnDespawnLifecycle = function()
    M.setState("CONNECTED")
    M.setRole("CLIENT")
    M.resetMetrics()
    M.setStrictLifecycle(true)
    
    -- Temporarily override spawnNewVehicle to prevent auto-calling onVehicleSpawned
    local originalSpawnNew = core_vehicles.spawnNewVehicle
    core_vehicles.spawnNewVehicle = function(model, options)
        table.insert(core_vehicles.spawned, { model = model, options = options })
    end
    
    -- Trigger spawn request using real JSON packet flow
    M.processPacket('{"type":"spawn","model":"covet","vehicle_id":7777}', "127.0.0.1", 27015)
    
    -- Restore original spawnNewVehicle function
    core_vehicles.spawnNewVehicle = originalSpawnNew
    
    -- 1. Attempt to spawn wrong model (hijacking attempt by local traffic)
    local mockHijackerId = 1111
    createMockVehicle(mockHijackerId, "pigeon", nil)
    M.onVehicleSpawned(mockHijackerId)
    
    -- Should be ignored: remote vehicle ID remains nil
    assertNil(M.getRemoteVehicleId())
    
    -- 2. Attempt to spawn correct model but outside the time window
    M._expectedSpawnTime = os.clock() - 6.0
    local mockExpiredId = 2222
    createMockVehicle(mockExpiredId, "covet", nil)
    M.onVehicleSpawned(mockExpiredId)
    
    -- Should be ignored: remote vehicle ID remains nil
    assertNil(M.getRemoteVehicleId())
    
    -- 3. Correct spawn (valid model and within time window)
    M._expectedSpawnTime = os.clock()
    local mockSuccessId = 3333
    createMockVehicle(mockSuccessId, "covet", nil)
    M.onVehicleSpawned(mockSuccessId)
    
    -- Should succeed: remote vehicle ID assigned, mapping registered
    assertEqual(mockSuccessId, M.getRemoteVehicleId())
    assertEqual(mockSuccessId, M._peerToLocalVehicles[7777])
    
    -- 4. Receive despawn command for peer ID 7777
    local despawnPacket = '{"type":"despawn","vehicle_id":7777}'
    M.processPacket(despawnPacket, "127.0.0.1", 27015)
    
    -- Should trigger deletion: local vehicle ID 3333 removed from objects, mapping cleared
    assertNil(be:getObjectByID(mockSuccessId))
    assertNil(M.getRemoteVehicleId())
    assertNil(M._peerToLocalVehicles[7777])
end

-- 23. World weather sync respects client toggle
tests.testWorldWeatherSyncToggle = function()
    local worldSync = extensions.worldSync
    assertNotNil(worldSync)

    local applied = false
    extensions.core_environment = {
        getTimeOfDay = function() return { time = 0.5, play = true } end,
        setTimeOfDay = function() applied = true end,
        getFogDensity = function() return 0.1 end,
        setFogDensity = function() applied = true end,
        getWindSpeed = function() return 3 end,
        setWindSpeed = function() applied = true end,
    }

    M.setState("CONNECTED")
    M.setRole("CLIENT")
    M.setWorldWeatherSync(false)

    worldSync.processPacket({ type = "world_env", time = 0.25, fogDensity = 500, windSpeed = 5 })
    assertFalse(applied, "weather must not apply when toggle is off")

    M.setWorldWeatherSync(true)
    worldSync.processPacket({ type = "world_env", time = 0.25, fogDensity = 500, windSpeed = 5 })
    assertTrue(applied, "weather must apply when toggle is on")
end

-- 24. Checkpoint packets trigger UI when enabled
tests.testCheckpointUiToggle = function()
    local gameplaySync = extensions.gameplaySync
    assertNotNil(gameplaySync)

    M.setState("CONNECTED")
    M.setRole("CLIENT")
    M.setCheckpointsUi(true)
    guihooks:reset()

    gameplaySync.processPacket({
        type = "checkpoint",
        trigger = "finish_line",
        nickname = "Host",
        elapsed = 42.5
    })

    assertNotNil(guihooks.triggered["lanMultiplayerCheckpoint"])
    assertEqual("finish_line", guihooks.triggered["lanMultiplayerCheckpoint"].latest.trigger)
    assertNear(42.5, guihooks.triggered["lanMultiplayerCheckpoint"].latest.elapsed, 0.01)
end

-- 25. AI snapshot FFI size
tests.testAiSnapshotSize = function()
    local aiSync = extensions.aiTrafficSync
    assertNotNil(aiSync)
    assertEqual(30, aiSync.getSnapshotSize())
end

-- 26. Quaternion compression roundtrip
tests.testAiQuatCompressRoundtrip = function()
    local aiSync = extensions.aiTrafficSync
    local cases = {
        { 0, 0, 0, 1 },
        { 0.707, 0, 0, 0.707 },
        { 0.1, 0.2, 0.3, 0.9 },
    }
    for _, c in ipairs(cases) do
        local qx, qy, qz, qw = c[1], c[2], c[3], c[4]
        local len = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
        qx, qy, qz, qw = qx / len, qy / len, qz / len, qw / len
        local li, c0, c1, c2 = aiSync.compressQuat(qx, qy, qz, qw)
        local rx, ry, rz, rw = aiSync.decompressQuat(li, c0, c1, c2)
        assertQuatSameOrientation({ x = qx, y = qy, z = qz, w = qw }, { x = rx, y = ry, z = rz, w = rw }, "quat roundtrip")
    end
end

-- 27. AI LOD zones
tests.testAiLodZone = function()
    local aiSync = extensions.aiTrafficSync
    assertEqual("A", aiSync.getLodZone(50))
    assertEqual("B", aiSync.getLodZone(250))
    assertEqual("C", aiSync.getLodZone(600))
    assertNear(1 / 60, aiSync.getLodSendInterval("A"), 0.0001)
    assertNear(0.1, aiSync.getLodSendInterval("B"), 0.0001)
    assertNil(aiSync.getLodSendInterval("C"))
end

-- 28. AI batch encode/decode roundtrip
tests.testAiBatchEncodeDecode = function()
    local aiSync = extensions.aiTrafficSync
    local snapshots = {
        {
            netId = 7,
            px = 10.5, py = 2.25, pz = -3.5,
            qx = 0, qy = 0, qz = 0, qw = 1,
            vx = 12.3, vy = -4.5, vz = 0.25,
        },
        {
            netId = 42,
            px = -100, py = 5, pz = 200,
            qx = 0.1, qy = 0.2, qz = 0.3, qw = 0.9,
            vx = 0, vy = 15, vz = -2,
        },
    }
    local packet, size = aiSync.buildBatchPacket(snapshots)
    assertNotNil(packet)
    assertEqual(12 + 2 * 30, size)

    local decoded = aiSync.decodeBatchPacket(packet)
    assertEqual(2, #decoded)
    assertEqual(7, decoded[1].netId)
    assertNear(10.5, decoded[1].px, 0.05)
    assertNear(12.3, decoded[1].vx, 0.05)
    assertEqual(42, decoded[2].netId)
end

-- 29. AI teleport packet updates puppet state
tests.testAiTeleportPacket = function()
    local aiSync = extensions.aiTrafficSync
    M.setState("CONNECTED")
    M.setRole("CLIENT")
    M.setAiTrafficSync(true)

    aiSync._aiNetToLocal[99] = { localId = 5001, model = "pickup" }
    aiSync.processPacket({
        type = "ai_teleport",
        net_id = 99,
        pos = { x = 1, y = 2, z = 3 },
        rot = { x = 0, y = 0, z = 0, w = 1 },
        vel = { x = 5, y = 0, z = -1 },
    })

    local entry = aiSync._aiNetToLocal[99]
    assertNear(1, entry.lastPx, 0.001)
    assertNear(2, entry.lastPy, 0.001)
    assertNear(5, entry.lastVx, 0.05)
end

-- 30. AI traffic toggle gates batch processing
tests.testAiTrafficSyncToggle = function()
    local aiSync = extensions.aiTrafficSync
    M.setState("CONNECTED")
    M.setRole("CLIENT")
    M.setAiTrafficSync(false)

    local fakeBatch = string.char(84, 65, 73, 66) -- TAIB
        .. string.char(1, 0, 1, 0, 0, 0, 0, 0)
        .. string.rep("\0", 30)

    assertFalse(aiSync.applyBatchRaw(fakeBatch))

    M.setAiTrafficSync(true)
    assertTrue(aiSync.applyBatchRaw(fakeBatch))
end

-- 31. Garage Preset Export/Import Roundtrip
tests.testGaragePresetRoundtrip = function()
    local contentSync = require("lua/ge/extensions/contentSync")
    assertNotNil(contentSync, "contentSync extension should be loaded")

    -- Setup mock vehicle
    local mockId = 123
    local mockVeh = createMockVehicle(mockId, "etk800", { parts = {}, vars = { licenseText = "MP" } })
    mockVeh.color = { x = 0.5, y = 0.5, z = 0.5, w = 1.0 }
    
    -- Mock vehicle manager
    extensions.core_vehicle_manager = {
        getVehicleData = function(id)
            if id == mockId then
                return {
                    config = {
                        vars = { licenseText = "MP-TEST" },
                        paints = {
                            { baseColor = { 1, 0, 0, 1 } }
                        }
                    }
                }
            end
            return nil
        end
    }

    local presetCode = contentSync.exportGaragePreset(mockId)
    assertNotNil(presetCode)
    assertTrue(presetCode:find("^BLMP%-") ~= nil)
    assertTrue(#presetCode < 500)

    -- Mock be:getPlayerVehicle to return the current vehicle which will be deleted
    be.playerVehicle = mockVeh
    
    local ok = contentSync.applyGaragePreset(presetCode)
    assertTrue(ok)
    assertEqual(1, #core_vehicles.spawned)
    assertEqual("etk800", core_vehicles.spawned[1].model)
    assertEqual("MP-TEST", core_vehicles.spawned[1].options.config.vars.licenseText)
    
    extensions.core_vehicle_manager = nil
end

-- 32. Mods Fingerprint Test
tests.testModsFingerprint = function()
    local contentSync = require("lua/ge/extensions/contentSync")
    
    -- Mock core_modmanager
    core_modmanager = {
        getModList = function()
            return {
                ["mod_a"] = { active = true },
                ["mod_b"] = { active = false },
                ["mod_c"] = { active = true }
            }
        end
    }
    
    local fp = contentSync.getModsFingerprint()
    assertNotNil(fp)
    assertNotNil(fp.mods_hash)
    assertEqual(2, fp.mods_count)
    assertEqual(2, #fp.mods_sample)
    assertEqual("mod_a", fp.mods_sample[1])
    assertEqual("mod_c", fp.mods_sample[2])
    
    core_modmanager = nil
end

-- 33. Map Validation Test
tests.testMapValidation = function()
    local contentSync = require("lua/ge/extensions/contentSync")
    
    -- Mock FS
    FS = {
        directoryExists = function(self, path)
            if path == "levels/gridmap_v2" or path == "levels/gridmap_v2/" or path == "/levels/gridmap_v2" then return true end
            return false
        end
    }
    
    assertTrue(contentSync.validateMapExists("levels/gridmap_v2"))
    assertFalse(contentSync.validateMapExists("levels/nonexistent"))
    
    FS = nil
end

-- 34. Config Truncation Verification
tests.testConfigTruncation = function()
    local normalConfig = { parts = { engine = "stage1" } }
    local config, truncated, reason = M.getSafeConfigPayload(normalConfig)
    assertEqual("stage1", config.parts.engine)
    assertFalse(truncated)
    assertNil(reason)

    -- Artificially huge configuration
    local hugeConfig = { parts = {}, vars = { turboBoost = 2.5 } }
    for i = 1, 100 do
        hugeConfig.parts["custom_fender_slot_part_index_" .. i] = "very_long_custom_part_name_installed_on_chassis_" .. i
    end
    
    local config2, truncated2, reason2 = M.getSafeConfigPayload(hugeConfig)
    assertNil(config2.parts)
    assertNotNil(config2.vars)
    assertEqual(2.5, config2.vars.turboBoost)
    assertTrue(truncated2)
    assertEqual("size", reason2)
end

-- 35. Reconnection FSM Transitions
tests.testReconnectionFSM = function()
    local sessionSync = require("lua/ge/extensions/sessionSync")
    assertNotNil(sessionSync)
    
    -- Normal operation: no transition if packets are fresh
    local now = os.clock()
    local nextState = sessionSync.tickReconnectFSM("CONNECTED", "CLIENT", now, 0.1)
    assertNil(nextState)
    
    -- Sim stopped packets for 2.1s -> should transition to RECONNECTING
    local nextState2 = sessionSync.tickReconnectFSM("CONNECTED", "CLIENT", now - 2.1, 0.1)
    assertEqual("RECONNECTING", nextState2)
    
    -- Resumed packets -> should recover to CONNECTED
    local nextState3 = sessionSync.tickReconnectFSM("RECONNECTING", "CLIENT", now - 0.5, 0.1)
    assertEqual("CONNECTED", nextState3)
    
    -- Mismatch for 5.1s -> should timeout
    local nextState4 = sessionSync.tickReconnectFSM("RECONNECTING", "CLIENT", now - 5.1, 0.1)
    assertEqual("TIMEOUT", nextState4)
end

-- 36. Handshake Version and Password Verification
tests.testHandshakeVersionVerification = function()
    local sessionSync = require("lua/ge/extensions/sessionSync")
    assertNotNil(sessionSync)
    
    -- Valid handshake
    local validPayload = {
        protocol_version = sessionSync.PROTOCOL_VERSION,
        mod_version = sessionSync.MOD_VERSION,
        game_version = sessionSync.GAME_VERSION
    }
    local res = sessionSync.verifyHandshake(validPayload)
    assertTrue(res.ok)
    
    -- Invalid protocol
    local invalidProto = {
        protocol_version = 999,
        mod_version = sessionSync.MOD_VERSION
    }
    local resProto = sessionSync.verifyHandshake(invalidProto)
    assertFalse(resProto.ok)
    assertEqual("protocol_mismatch", resProto.reason)
    
    -- Invalid mod
    local invalidMod = {
        protocol_version = sessionSync.PROTOCOL_VERSION,
        mod_version = "0.0.1"
    }
    local resMod = sessionSync.verifyHandshake(invalidMod)
    assertFalse(resMod.ok)
    assertEqual("mod_mismatch", resMod.reason)
end

-- 37. Trailer Attachment Sync
tests.testTrailerSync = function()
    local vehicleSync = require("lua/ge/extensions/vehicleSync")
    assertNotNil(vehicleSync)
    
    -- Setup peer mapping
    M._peerToLocalVehicles = {
        [200] = 2000, -- main vehicle
        [300] = 3000  -- trailer
    }
    
    local mainVeh = createMockVehicle(2000, "etk800", {})
    local trailerVeh = createMockVehicle(3000, "trailer", {})
    
    -- Mock handlePacket trailer_attach
    local ok = vehicleSync.handlePacket({
        type = "trailer_attach",
        vehicle_id = 200,
        trailer_id = 300
    })
    assertTrue(ok)
    
    -- Verify queueLuaCommand was called on main vehicle to attach couplers
    assertEqual(1, #mainVeh.queuedCommands)
    assertTrue(mainVeh.queuedCommands[1]:find("attachCouplers") ~= nil)
    
    -- Mock handlePacket trailer_detach
    local ok2 = vehicleSync.handlePacket({
        type = "trailer_detach",
        vehicle_id = 200,
        trailer_id = 300
    })
    assertTrue(ok2)
    assertEqual(2, #mainVeh.queuedCommands)
    assertTrue(mainVeh.queuedCommands[2]:find("detachCouplers") ~= nil)
    
    M._peerToLocalVehicles = {}
end

-- 38. Race Countdown and Throttle Locking
tests.testCountdownSync = function()
    local raceSync = require("lua/ge/extensions/raceSync")
    assertNotNil(raceSync)
    
    -- Setup mock player vehicle
    local myVeh = createMockVehicle(999, "etk800", {})
    be.playerVehicle = myVeh
    
    -- Mock os.clock to control time synchronously
    local oldClock = os.clock
    local fakeTime = 100.0
    os.clock = function() return fakeTime end
    
    -- Start countdown: 3 seconds
    raceSync.startCountdown(3)
    assertTrue(raceSync.isThrottleLocked())
    
    -- Run onUpdate: should lock throttle
    fakeTime = fakeTime + 0.1
    raceSync.onUpdate(0.1)
    assertEqual(2, #myVeh.queuedCommands)
    assertTrue(myVeh.queuedCommands[1]:find("throttle") ~= nil)
    
    -- Wait until countdown finishes
    fakeTime = fakeTime + 3.0
    raceSync.onUpdate(3.0)
    assertFalse(raceSync.isThrottleLocked())
    
    -- Restore os.clock
    os.clock = oldClock
    be.playerVehicle = nil
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
        
        local ok, err = xpcall(func, debug.traceback)
        if ok then
            passed = passed + 1
            print("\27[32m[PASS]\27[0m")
        else
            failed = failed + 1
            table.insert(failedNames, name)
            print("\27[31m[FAIL]\27[0m")
            print(tostring(err) .. "\n")
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
