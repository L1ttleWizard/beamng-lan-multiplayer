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

local tests = {}

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
    assertEqual(80, #sentPacket, "FFI update packet must be exactly 80 bytes")
    
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
    
    -- Validate control inputs applied to remote vehicle Lua VM
    assertEqual(1, #remoteVeh.queuedCommands)
    local cmd = remoteVeh.queuedCommands[1]
    assertTrue(cmd:find("throttle', 0.900000") ~= nil, "Remote throttle command check failed")
    assertTrue(cmd:find("steering', 0.150000") ~= nil, "Remote steering command check failed")
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
