-- LAN Multiplayer Mod for BeamNG.drive
-- Author: Antigravity (Google DeepMind Advanced Agentic Coding)

local M = {}
M.ghostModeEnabled = false
M.soundSyncEnabled = true
M.wheelSyncEnabled = true
M.lightsSyncEnabled = true
M.damageSyncEnabled = true
M.networkOptimizationEnabled = false
M.tuningSyncEnabled = true
M.backfireSyncEnabled = true
M.recoverySyncEnabled = true
M.adaptiveHzEnabled = true
M.jitterBufferEnabled = true
M.inputExtrapEnabled = true
M.plcEnabled = true
M.useTimeBasedExtrap = true
M.hemisphereCheckEnabled = true
M.netEmulatorEnabled = false
M.debugDropRate = 0.0
M.debugJitterMaxMs = 0
M._lastPacketTimestamp = 0
M._activeSessionsCount = 0
M._cpuFrameTimeMs = 0.0

M._lastSyncedRPM = 0
M._lastSyncedWS = 0
M._lastSyncedGear = -9
M._lastSyncedLights = 0
M._lastSyncedFlags = 0

-- Libraries
local socket = require("socket")
local ffi = require("ffi")
local table_clear = table.clear or require("table.clear")

-- Register FFI structure for zero-allocation binary updates
ffi.cdef[[
typedef struct {
    uint32_t magic;      // 0x42555044
    uint32_t seq;
    float px, py, pz;    // Position
    float rx, ry, rz, rw;// Rotation
    float vx, vy, vz;    // Velocity
    float ax, ay, az;    // Angular Velocity
    float throttle;      // Inputs
    float steering;
    float brake;
    float clutch;
    float handbrake;
    float rpm;           // [NEW] Engine RPM
    float wheelSpeed;    // [NEW] Average wheel speed
    int16_t gear;        // [NEW] Transmission gear index
    uint8_t lights;      // [NEW] Lights bitmask
    uint8_t flags;       // [NEW] Miscellaneous flags (bit 0: ghost mode)
} UpdatePacket;
]]

local outPacket = ffi.new("UpdatePacket")
local inPacket = ffi.new("UpdatePacket")


-- State variables
local state = "IDLE" -- "IDLE", "HOSTING", "CONNECTING", "CONNECTED"
local role = "NONE" -- "HOST", "CLIENT", "NONE"
local targetIp = nil
local targetPort = nil
local listenPort = nil
local udpSocket = nil

-- Discovery State
local discoverySendSocket = nil
local discoveryRecvSocket = nil
local beaconTimer = 0
local discoveredLobbies = {}
local lobbyCleanTimer = 0

-- Settings state (saved configuration, independent of connection status)
local savedIp = "127.0.0.1"
local savedPort = 27015
local savedClientPort = 0

-- Forward declarations
local host, connect, disconnect, saveSettings, loadSettings

-- Nicknames
local myNickname = "Player"
local remoteNickname = "Friend"

-- Vehicle tracking
local remoteVehicleId = nil
local remoteVehicleModel = nil
local remoteVehicleConfig = nil
local myVehicleId = nil
local lastMyVehicleModel = nil
local lastMyVehicleConfig = nil

-- Timing & Flags
local sendTimer = 0
local sendRate = 0.0166 -- ~60 Hz updates default
local vehicleCheckTimer = 0
local damageCheckTimer = 0
local connectTimer = 0
local lastPacketTime = 0
local timeoutLimit = 5.0 -- 5 seconds timeout
local spawnPending = false
local spawnPendingModel = nil

-- Settings path
local settingsFile = "settings/lanMultiplayer.json"

-- Input filtering state
local lastRemoteInputs = { t = 0, s = 0, b = 0, c = 0, hb = 0 }
local remoteTargetInputs = { t = 0, s = 0, b = 0, c = 0, hb = 0 }
M._lastSyncedInputs = { t = 0, s = 0, b = 0, c = 0, hb = 0 }
local prevLocalPos = vec3(0,0,0)
local prevLocalPosInitialized = false

-- Dead Reckoning State for Sender
local lastSentPos = vec3(0,0,0)
local lastSentVel = vec3(0,0,0)
local lastSentRot = quat(0,0,0,1)
local lastSentInputs = { t = 0, s = 0, b = 0, c = 0, hb = 0 }
local lastSentTime = 0
local heartbeatCounter = 0


-- ============================================================
-- Remote Vehicle State
-- ============================================================
-- Remote target state (updated by packets, applied with smoothing each frame)
local remoteTargetPos = vec3(0,0,0)
local remoteTargetRot = quat(0,0,0,1)
local remoteTargetVel = vec3(0,0,0)
local remoteTargetAngVel = vec3(0,0,0)
local hasRemoteState = false
local lastGhostState = false
local remoteLastSpeed = 0       -- km/h for display

-- Remote target variables for electrics sync
local remoteTargetRPM = 0
local remoteTargetWS = 0
local remoteTargetGear = 0
local remoteTargetLights = 0
local remoteTargetFlags = 0

-- Interpolation settings
local smoothSpeed = 30          -- exponential convergence rate
local smoothThreshold = 0.02    -- meters: below this, just snap directly

-- Pre-allocated objects to avoid garbage collection pressure
local smoothedPos = vec3(0,0,0)
local smoothedRot = quat(0,0,0,1)

local nickColor = ColorF(0.22, 0.74, 1.0, 1.0)
local speedColor = ColorF(0.85, 0.85, 0.85, 0.75)
local shadowColor = ColorI(0, 0, 0, 128)
local chatTextColor = ColorF(1.0, 0.84, 0.0, 1.0)
local chatShadowColor = ColorI(0, 0, 0, 180)
local uiPosVec = vec3(0,0,0)

local bit = require("bit")

-- ============================================================
-- Adaptive Send Rate
-- ============================================================
local adaptiveEnabled = true
local minSendRate = 0.0166     -- 60 Hz ceiling
local maxSendRate = 0.05       -- 20 Hz floor
local adaptiveTimer = 0
local adaptiveInterval = 3.0    -- re-evaluate every 3s
local currentHz = 60           -- display value

-- ============================================================
-- Network Metrics
-- ============================================================
-- Ping / RTT
local pingTimer = 0
local pingInterval = 0.5       -- send ping every 0.5s
local pingSeq = 0              -- outgoing ping sequence number
local pingSendTime = {}        -- map: seq -> os.clock() when sent
local currentPing = 0          -- last measured RTT in ms
local pingHistorySize = 60     -- 30 seconds of history at 0.5s interval
local pingHistory = {}         -- ring buffer of last 60 ping values
local pingHistoryIdx = 0

-- Jitter (variance of ping)
local currentJitter = 0        -- ms

-- Packet counters (per-second)
local txPackets = 0            -- packets sent this window
local rxPackets = 0            -- packets received this window
local metricsTimer = 0
local metricsInterval = 1.0    -- calculate rates every 1s
local txRate = 0               -- packets/sec display value
local rxRate = 0               -- packets/sec display value

-- Packet loss (sequence-number based)
local txSeq = 0                -- sequence number we embed in update packets
local remoteLastSeq = 0        -- highest sequence number received from remote
local remoteLostCount = 0      -- total packets we detected as lost
local remoteTotalExpected = 0  -- total packets we expected
local packetLoss = 0           -- percentage 0-100

-- Bandwidth estimation
local txBytes = 0              -- bytes sent this window
local rxBytes = 0              -- bytes received this window
local txBandwidth = 0          -- KB/s display value
local rxBandwidth = 0          -- KB/s display value

-- ============================================================

-- UI Communication Helper
local function notifyUI(errMsg)
    if guihooks then
        guihooks.trigger("lanMultiplayerStatus", {
            status = state,
            role = role,
            activeIp = targetIp or "",
            activePort = listenPort or "",
            activeTargetPort = targetPort or "",
            configIp = savedIp or "127.0.0.1",
            configPort = savedPort or 27015,
            configClientPort = savedClientPort or 0,
            nickname = myNickname or "Player",
            remoteNickname = remoteNickname or "",
            ghostMode = M.ghostModeEnabled,
            soundSync = M.soundSyncEnabled,
            wheelSync = M.wheelSyncEnabled,
            lightsSync = M.lightsSyncEnabled,
            damageSync = M.damageSyncEnabled,
            networkOpt = M.networkOptimizationEnabled,
            tuningSync = M.tuningSyncEnabled,
            backfireSync = M.backfireSyncEnabled,
            recoverySync = M.recoverySyncEnabled,
            adaptiveHz = M.adaptiveHzEnabled,
            jitterBuff = M.jitterBufferEnabled,
            inputExtrap = M.inputExtrapEnabled,
            plc = M.plcEnabled,
            useTimeBasedExtrap = M.useTimeBasedExtrap,
            hemisphereCheck = M.hemisphereCheckEnabled,
            netEmulator = M.netEmulatorEnabled,
            debugDropRate = M.debugDropRate,
            debugJitterMaxMs = M.debugJitterMaxMs,
            loadStatus = { sessions = M._activeSessionsCount or 0, frameTimeMs = M._cpuFrameTimeMs or 0 },
            error = errMsg
        })
    end
end

-- Build ordered ping history for sparkline
local function getOrderedPingHistory()
    local ordered = {}
    local count = #pingHistory
    if count == 0 then return ordered end
    for i = 1, count do
        local idx = ((pingHistoryIdx - count + i - 1) % pingHistorySize) + 1
        ordered[i] = pingHistory[idx] or 0
    end
    return ordered
end

-- Network metrics UI update (separate event to avoid spamming the main status)
local function notifyMetrics()
    if guihooks and (state == "CONNECTED" or state == "HOSTING") then
        local history = getOrderedPingHistory()
        local maxPing = 1
        for i = 1, #history do
            if history[i] > maxPing then maxPing = history[i] end
        end
        guihooks.trigger("lanMultiplayerMetrics", {
            ping = math.floor(currentPing + 0.5),
            jitter = math.floor(currentJitter * 10 + 0.5) / 10,
            txRate = txRate,
            rxRate = rxRate,
            packetLoss = math.floor(packetLoss * 10 + 0.5) / 10,
            txKBs = math.floor(txBandwidth * 10 + 0.5) / 10,
            rxKBs = math.floor(rxBandwidth * 10 + 0.5) / 10,
            hz = math.floor(currentHz + 0.5),
            pingHistory = history,
            pingMax = math.ceil(maxPing),
            loadStatus = { sessions = M._activeSessionsCount or 0, frameTimeMs = M._cpuFrameTimeMs or 0 }
        })
    end
end

-- Safely get vehicle model and config path
local function getVehicleInfo(veh)
    if not veh then return nil, nil end
    local model = veh.JBeam
    local config = nil
    
    if veh.partConfig then
        config = veh.partConfig
    elseif extensions.core_vehicle_manager then
        local data = extensions.core_vehicle_manager.getVehicleData(veh:getId())
        if data and data.config then
            config = data.config
        end
    end
    
    return model, config
end

-- Minimize vehicle config table size by removing empty slots or none values
local function getMinimizedConfig(config)
    if not config or type(config) ~= "table" then
        return config
    end
    
    local minConfig = {}
    
    if config.parts and type(config.parts) == "table" then
        minConfig.parts = {}
        for k, v in pairs(config.parts) do
            if type(v) == "string" and v ~= "" and v ~= "none" then
                minConfig.parts[k] = v
            end
        end
    end
    
    if config.vars and type(config.vars) == "table" then
        minConfig.vars = {}
        for k, v in pairs(config.vars) do
            if v ~= nil then
                minConfig.vars[k] = v
            end
        end
    end
    
    return minConfig
end

-- Check JSON-encoded size and downgrade/strip parts if too large to prevent fragmentation
local function getSafeConfigPayload(config)
    if not config then return nil end
    if type(config) ~= "table" then
        return config
    end
    
    local minConfig = getMinimizedConfig(config)
    local jsonStr = jsonEncode(minConfig)
    if not jsonStr then return nil end
    
    -- Target UDP payload <= 1400 bytes, limit config JSON size to 1000 bytes
    if #jsonStr <= 1000 then
        return minConfig
    end
    
    log('W', 'lanMultiplayer', 'Vehicle parts configuration is too large (' .. tostring(#jsonStr) .. ' bytes). Dropping custom parts to prevent packet fragmentation.')
    
    -- Fallback: send only tuning vars if they fit
    if minConfig.vars and next(minConfig.vars) then
        local varsOnly = { vars = minConfig.vars }
        local varsJson = jsonEncode(varsOnly)
        if varsJson and #varsJson <= 1000 then
            return varsOnly
        end
    end
    
    return nil
end

-- Deep table equivalence comparison (order-independent)
local function areConfigsEqual(c1, c2)
    if type(c1) ~= type(c2) then return false end
    if type(c1) ~= "table" then
        return c1 == c2
    end
    
    local keys1 = {}
    for k, v in pairs(c1) do
        keys1[k] = true
        if not areConfigsEqual(v, c2[k]) then
            return false
        end
    end
    
    for k, _ in pairs(c2) do
        if not keys1[k] then
            return false
        end
    end
    
    return true
end

-- Safe control input reader returning raw values to avoid table allocations
local function getInputsRaw()
    local t, s, b, c, hb = 0, 0, 0, 0, 0
    if input then
        if input.state then
            if input.state.throttle then t = input.state.throttle.val or input.state.throttle or 0 end
            if input.state.steering then s = input.state.steering.val or input.state.steering or 0 end
            if input.state.brake then b = input.state.brake.val or input.state.brake or 0 end
            if input.state.clutch then c = input.state.clutch.val or input.state.clutch or 0 end
            if input.state.handbrake then hb = input.state.handbrake.val or input.state.handbrake or 0 end
        elseif input.throttle then
            t = input.throttle or 0
            s = input.steering or 0
            b = input.brake or 0
            c = input.clutch or 0
            hb = input.handbrake or 0
        end
    end
    return t, s, b, c, hb
end

-- Get current map path
local function getCurrentMapPath()
    local path = getMissionFilename()
    if path and path ~= "" then
        return path
    end
    if core_levels then
        if core_levels.getCurrentLevelIdentifier then
            local id = core_levels.getCurrentLevelIdentifier()
            if id and id ~= "" then
                return "levels/" .. id .. "/info.json"
            end
        end
    end
    return nil
end

-- Check if client is on the same map as host, load it if not
local function checkAndLoadMap(hostMapPath)
    if not hostMapPath then return end
    local myMapPath = getCurrentMapPath()
    if myMapPath ~= hostMapPath then
        log('I', 'lanMultiplayer', 'Map mismatch! Host is on: ' .. tostring(hostMapPath) .. '. Loading map...')
        if core_levels and core_levels.startLevel then
            core_levels.startLevel(hostMapPath)
        end
    end
end

-- Delete remote vehicle
local function deleteRemoteVehicle()
    if remoteVehicleId then
        log('I', 'lanMultiplayer', 'Deleting remote vehicle ID: ' .. tostring(remoteVehicleId))
        if core_vehicles and core_vehicles.deleteVehicle then
            core_vehicles.deleteVehicle(remoteVehicleId)
        else
            local veh = be:getObjectByID(remoteVehicleId)
            if veh then veh:delete() end
        end
        remoteVehicleId = nil
        remoteVehicleModel = nil
        remoteVehicleConfig = nil
        spawnPending = false
        spawnPendingModel = nil
    end
    hasRemoteState = false
    lastGhostState = false
    remoteTargetPos.x = 0
    remoteTargetPos.y = 0
    remoteTargetPos.z = 0
    remoteTargetRot.x = 0
    remoteTargetRot.y = 0
    remoteTargetRot.z = 0
    remoteTargetRot.w = 1
    remoteTargetVel.x = 0
    remoteTargetVel.y = 0
    remoteTargetVel.z = 0
    remoteTargetAngVel.x = 0
    remoteTargetAngVel.y = 0
    remoteTargetAngVel.z = 0
    remoteLastSpeed = 0
end

-- Spawn remote vehicle
local function spawnRemoteVehicle(model, config, pos, rot)
    if spawnPending then return end
    
    deleteRemoteVehicle()
    
    log('I', 'lanMultiplayer', 'Spawning remote vehicle: ' .. tostring(model))
    
    local originalVeh = be:getPlayerVehicle(0)
    local originalId = originalVeh and originalVeh:getId()
    
    spawnPending = true
    spawnPendingModel = model
    remoteVehicleModel = model
    remoteVehicleConfig = config
    
    -- Convert JSON tables to vec3/quat objects
    local p = vec3(0,0,0)
    if pos then
        if type(pos) == "table" then
            p = vec3(pos.x or 0, pos.y or 0, pos.z or 0)
        else
            p = pos
        end
    end
    
    local r = quat(0,0,0,1)
    if rot then
        if type(rot) == "table" then
            r = quat(rot.x or 0, rot.y or 0, rot.z or 0, rot.w or 1)
        else
            r = rot
        end
    end
    
    -- If position is zero, spawn near original/host vehicle
    if originalVeh and (p.x == 0 and p.y == 0 and p.z == 0) then
        local hostPos = originalVeh:getPosition()
        local hostRot = quat(originalVeh:getRotation())
        -- Offset spawn position 5 meters to the right side of the host vehicle
        local dirRight = hostRot * vec3(1, 0, 0)
        p = hostPos + dirRight * 5.0
        p.z = p.z + 0.5
        r = hostRot
        log('I', 'lanMultiplayer', string.format("Defaulting remote vehicle spawn near host: %s", tostring(p)))
    end
    
    core_vehicles.spawnNewVehicle(model, {
        config = config,
        pos = p,
        rot = r,
        autoEnterVehicle = false
    })
    
    -- Select the player's original vehicle back immediately
    if originalVeh then
        be:enterVehicle(0, originalVeh)
    end
end

-- Close socket
local function closeSocket()
    if udpSocket then
        udpSocket:close()
        udpSocket = nil
        log('I', 'lanMultiplayer', 'Socket closed.')
    end
end

-- Reset network metrics
local function resetMetrics()
    M._jitterQueue = {}
    M._ipcTimer = 0.02
    currentPing = 0
    currentJitter = 0
    pingSeq = 0
    pingSendTime = {}
    pingHistory = {}
    pingHistoryIdx = 0
    txPackets = 0
    rxPackets = 0
    txRate = 0
    rxRate = 0
    txSeq = 0
    remoteLastSeq = 0
    remoteLostCount = 0
    remoteTotalExpected = 0
    packetLoss = 0
    txBytes = 0
    rxBytes = 0
    txBandwidth = 0
    rxBandwidth = 0
    pingTimer = 0
    metricsTimer = 0
    damageCheckTimer = 0
    adaptiveTimer = 0
    sendRate = minSendRate
    currentHz = math.floor(1 / minSendRate + 0.5)
    lastRemoteInputs.t = 0
    lastRemoteInputs.s = 0
    lastRemoteInputs.b = 0
    lastRemoteInputs.c = 0
    lastRemoteInputs.hb = 0
    remoteTargetInputs.t = 0
    remoteTargetInputs.s = 0
    remoteTargetInputs.b = 0
    remoteTargetInputs.c = 0
    remoteTargetInputs.hb = 0
    M._lastSyncedInputs.t = 0
    M._lastSyncedInputs.s = 0
    M._lastSyncedInputs.b = 0
    M._lastSyncedInputs.c = 0
    M._lastSyncedInputs.hb = 0
    prevLocalPos.x = 0; prevLocalPos.y = 0; prevLocalPos.z = 0
    prevLocalPosInitialized = false
    M._tandemScore = 0
    M._chatTimer = 0
    M._chatText = nil
    M._lastSyncedRPM = 0
    M._lastSyncedWS = 0
    M._lastSyncedGear = -9
    M._lastSyncedLights = 0
    M._lastSyncedFlags = 0
    lastSentPos.x = 0; lastSentPos.y = 0; lastSentPos.z = 0
    lastSentVel.x = 0; lastSentVel.y = 0; lastSentVel.z = 0
    lastSentRot.x = 0; lastSentRot.y = 0; lastSentRot.z = 0; lastSentRot.w = 1
    lastSentInputs.t = 0; lastSentInputs.s = 0; lastSentInputs.b = 0; lastSentInputs.c = 0; lastSentInputs.hb = 0
    lastSentTime = 0
    heartbeatCounter = 0
    hasRemoteState = false
    lastGhostState = false
    remoteTargetPos.x = 0
    remoteTargetPos.y = 0
    remoteTargetPos.z = 0
    remoteTargetRot.x = 0
    remoteTargetRot.y = 0
    remoteTargetRot.z = 0
    remoteTargetRot.w = 1
    remoteTargetVel.x = 0
    remoteTargetVel.y = 0
    remoteTargetVel.z = 0
    remoteTargetAngVel.x = 0
    remoteTargetAngVel.y = 0
    remoteTargetAngVel.z = 0
    remoteLastSpeed = 0
    remoteTargetRPM = 0
    remoteTargetWS = 0
    remoteTargetGear = 0
    remoteTargetLights = 0
    remoteTargetFlags = 0
end

-- Disconnect
local function disconnect()
    log('I', 'lanMultiplayer', 'Disconnecting and resetting multiplayer state.')
    deleteRemoteVehicle()
    closeSocket()
    
    state = "IDLE"
    role = "NONE"
    targetIp = nil
    targetPort = nil
    listenPort = nil
    remoteNickname = "Friend"
    resetMetrics()
    
    if saveSettings then saveSettings(false) end
    notifyUI()
end

-- Host server
local function host(port)
    savedPort = port or 27015
    
    disconnect()
    
    local portVal = savedPort
    local sock = socket.udp()
    sock:settimeout(0)
    
    local success, err = sock:setsockname("0.0.0.0", portVal)
    if not success then
        local errMsg = 'Failed to bind host socket: ' .. tostring(err)
        log('E', 'lanMultiplayer', errMsg)
        notifyUI(errMsg)
        return false
    end
    
    udpSocket = sock
    listenPort = portVal
    state = "HOSTING"
    role = "HOST"
    
    log('I', 'lanMultiplayer', 'Hosting multiplayer server on UDP port ' .. tostring(portVal))
    saveSettings(true)
    notifyUI()
    return true
end

-- Connect to host
local function connect(ip, port, localPort)
    savedIp = ip or "127.0.0.1"
    savedPort = port or 27015
    savedClientPort = localPort or 0
    
    disconnect()
    
    local targetIpVal = savedIp
    local targetPortVal = savedPort
    local localPortVal = savedClientPort
    
    local sock = socket.udp()
    sock:settimeout(0)
    
    local success, err = sock:setsockname("0.0.0.0", localPortVal)
    if not success then
        local errMsg = 'Failed to bind client socket: ' .. tostring(err)
        log('E', 'lanMultiplayer', errMsg)
        notifyUI(errMsg)
        return false
    end
    
    local _, boundPort = sock:getsockname()
    
    -- Connect the socket to the host (creates stateful UDP for Windows Firewall hole-punching)
    local peerOk, peerErr = sock:setpeername(targetIpVal, targetPortVal)
    if not peerOk then
        local errMsg = 'Failed to set peer on client socket: ' .. tostring(peerErr)
        log('E', 'lanMultiplayer', errMsg)
        sock:close()
        notifyUI(errMsg)
        return false
    end
    log('I', 'lanMultiplayer', 'Client socket connected to peer ' .. tostring(targetIpVal) .. ':' .. tostring(targetPortVal))
    
    udpSocket = sock
    targetIp = targetIpVal
    targetPort = targetPortVal
    listenPort = boundPort or localPortVal
    state = "CONNECTING"
    role = "CLIENT"
    connectTimer = 0
    
    log('I', 'lanMultiplayer', 'Connecting to host ' .. tostring(targetIpVal) .. ':' .. tostring(targetPortVal) .. ' from port ' .. tostring(listenPort))
    saveSettings(true)
    notifyUI()
    return true
end

-- Save connection settings
function saveSettings(autoReconnect)
    local data = {
        autoReconnect = autoReconnect,
        role = role,
        ip = savedIp,
        port = savedPort,
        clientPort = savedClientPort,
        nickname = myNickname
    }
    jsonWriteFile(settingsFile, data, true)
end

-- Load connection settings and auto-connect/host
function loadSettings()
    local data = jsonReadFile(settingsFile)
    if data then
        myNickname = data.nickname or "Player"
        savedIp = data.ip or "127.0.0.1"
        savedPort = data.port or 27015
        savedClientPort = data.clientPort or 0
        if data.autoReconnect then
            log('I', 'lanMultiplayer', 'Auto-reconnection active. Restoring session: ' .. tostring(data.role))
            if data.role == "HOST" then
                host(savedPort)
            elseif data.role == "CLIENT" then
                connect(savedIp, savedPort, savedClientPort)
            end
        else
            notifyUI()
        end
    else
        notifyUI()
    end
end

-- Send raw bytes via socket (low-level, tracks TX counters)
local function sendRaw(rawData)
    if not udpSocket then return end
    local success, err
    if role == "CLIENT" then
        -- Connected socket: use send() (peer set via setpeername)
        success, err = udpSocket:send(rawData)
    else
        -- Unconnected socket (HOST): use sendto()
        if not targetIp or not targetPort then return end
        success, err = udpSocket:sendto(rawData, targetIp, targetPort)
    end
    if success then
        txPackets = txPackets + 1
        txBytes = txBytes + #rawData
        
        -- Allocation-free check to ignore telemetry hot-path and ping/pong from logging
        local firstByte = string.byte(rawData, 1)
        local shouldLog = true
        if firstByte == 68 then -- 'D' (DPUB binary telemetry)
            shouldLog = false
        elseif firstByte == 123 then -- '{' (JSON)
            local t = rawData:match('"t":"([^"]+)"') or rawData:match('"type":"([^"]+)"')
            if t == "u" or t == "ping" or t == "pong" then
                shouldLog = false
            end
        end
        
        if shouldLog then
            log('I', 'lanMultiplayer', 'Sent packet: ' .. rawData:sub(1, 120) .. '... (size: ' .. tostring(#rawData) .. ' bytes)')
        end
    else
        log('W', 'lanMultiplayer', 'Failed to send packet: ' .. tostring(err))
    end
end

-- Send a packet (JSON-encoded, for non-hot-path messages)
local function sendPacket(payload)
    sendRaw(jsonEncode(payload))
end

-- Send update packet with zero Lua-GC allocations using binary FFI struct
local function sendUpdate()
    local myVeh = be:getPlayerVehicle(0)
    if not myVeh then return end
    
    -- Nil-safe raw field access (no fallback vec3/quat allocations)
    local pos = myVeh.getPosition and myVeh:getPosition()
    local rawRot = myVeh.getRotation and myVeh:getRotation()
    if not pos or not rawRot then return end
    local rot = quat(rawRot)
    
    local vx, vy, vz = 0, 0, 0
    local vel = myVeh.getVelocity and myVeh:getVelocity()
    if vel then vx, vy, vz = vel.x, vel.y, vel.z end
    
    local ax, ay, az = 0, 0, 0
    local angVel = myVeh.getAngularVelocity and myVeh:getAngularVelocity()
    if angVel then ax, ay, az = angVel.x, angVel.y, angVel.z end
    
    local t, s, b, c, hb = getInputsRaw()
    
    -- Network Optimization / State-based Dead Reckoning
    if M.networkOptimizationEnabled and lastSentTime > 0 then
        local dt = os.clock() - lastSentTime
        local predX = lastSentPos.x + lastSentVel.x * dt
        local predY = lastSentPos.y + lastSentVel.y * dt
        local predZ = lastSentPos.z + lastSentVel.z * dt
        
        local dx = pos.x - predX
        local dy = pos.y - predY
        local dz = pos.z - predZ
        local errDist = math.sqrt(dx*dx + dy*dy + dz*dz)
        
        local inputsUnchanged = math.abs(t - lastSentInputs.t) < 0.005 and
                                math.abs(s - lastSentInputs.s) < 0.005 and
                                math.abs(b - lastSentInputs.b) < 0.005 and
                                math.abs(c - lastSentInputs.c) < 0.005 and
                                math.abs(hb - lastSentInputs.hb) < 0.005
        
        if errDist < 0.05 and inputsUnchanged and heartbeatCounter < 15 then
            heartbeatCounter = heartbeatCounter + 1
            return
        end
    end
    
    txSeq = txSeq + 1
    
    -- Read electrics cache for player vehicle
    local myId = myVeh:getId()
    local rpm = M.soundSyncEnabled and (core_vehicleBridge.getCachedVehicleData(myId, 'rpm') or 0) or 0
    local wheelSpeed = M.wheelSyncEnabled and (core_vehicleBridge.getCachedVehicleData(myId, 'wheelspeed') or 0) or 0
    local gear = M.soundSyncEnabled and (core_vehicleBridge.getCachedVehicleData(myId, 'gearIndex') or 0) or 0
    
    local lightsMask = 0
    if M.lightsSyncEnabled then
        local lights_state = core_vehicleBridge.getCachedVehicleData(myId, 'lights_state') or 0
        local signal_L = core_vehicleBridge.getCachedVehicleData(myId, 'signal_L') or false
        local signal_R = core_vehicleBridge.getCachedVehicleData(myId, 'signal_R') or false
        local hazard = core_vehicleBridge.getCachedVehicleData(myId, 'hazard') or false
        local fog = core_vehicleBridge.getCachedVehicleData(myId, 'fog') or false
        local lightbar = core_vehicleBridge.getCachedVehicleData(myId, 'lightbar') or 0
        local horn = core_vehicleBridge.getCachedVehicleData(myId, 'horn') or false
        
        if lights_state ~= 0 then lightsMask = lightsMask + 1 end
        if signal_L then lightsMask = lightsMask + 2 end
        if signal_R then lightsMask = lightsMask + 4 end
        if hazard then lightsMask = lightsMask + 8 end
        if fog then lightsMask = lightsMask + 16 end
        if lightbar ~= 0 then lightsMask = lightsMask + 32 end
        if horn then lightsMask = lightsMask + 64 end
    end
    
    -- Encode flags (bit 0: Ghost Mode)
    local flagsMask = 0
    if M.ghostModeEnabled then flagsMask = flagsMask + 1 end
    
    -- Write to pre-allocated C struct (0 dynamic memory allocation)
    outPacket.magic = 0x42555044
    outPacket.seq = txSeq
    outPacket.px = pos.x
    outPacket.py = pos.y
    outPacket.pz = pos.z
    outPacket.rx = rot.x
    outPacket.ry = rot.y
    outPacket.rz = rot.z
    outPacket.rw = rot.w
    outPacket.vx = vx
    outPacket.vy = vy
    outPacket.vz = vz
    outPacket.ax = ax
    outPacket.ay = ay
    outPacket.az = az
    outPacket.throttle = t
    outPacket.steering = s
    outPacket.brake = b
    outPacket.clutch = c
    outPacket.handbrake = hb
    outPacket.rpm = rpm
    outPacket.wheelSpeed = wheelSpeed
    outPacket.gear = gear
    outPacket.lights = lightsMask
    outPacket.flags = flagsMask
    
    -- Save sent state
    lastSentPos.x = pos.x
    lastSentPos.y = pos.y
    lastSentPos.z = pos.z
    lastSentVel.x = vx
    lastSentVel.y = vy
    lastSentVel.z = vz
    lastSentRot.x = rot.x
    lastSentRot.y = rot.y
    lastSentRot.z = rot.z
    lastSentRot.w = rot.w
    lastSentInputs.t = t
    lastSentInputs.s = s
    lastSentInputs.b = b
    lastSentInputs.c = c
    lastSentInputs.hb = hb
    lastSentTime = os.clock()
    heartbeatCounter = 0
    
    -- Send directly as raw binary string (92 bytes)
    sendRaw(ffi.string(outPacket, 92))
end

-- Send spawn / vehicle configuration info
local function sendSpawn(model, config)
    local myVeh = be:getPlayerVehicle(0)
    if not myVeh then return end
    
    local pos = (myVeh.getPosition and myVeh:getPosition()) or vec3(0,0,0)
    local rot = (myVeh.getRotation and quat(myVeh:getRotation())) or quat(0,0,0,1)
    
    -- Filter config payload to prevent fragmentation
    local safeConfig = getSafeConfigPayload(config)
    
    local payload = {
        type = "spawn",
        model = model,
        config = safeConfig,
        nickname = myNickname,
        pos = { x = pos.x, y = pos.y, z = pos.z },
        rot = { x = rot.x, y = rot.y, z = rot.z, w = rot.w }
    }
    
    sendPacket(payload)
end

-- Send reset packet
local function sendReset()
    sendPacket({ type = "reset" })
end

-- Send ping packet
local function sendPing()
    pingSeq = pingSeq + 1
    pingSendTime[pingSeq] = socket.gettime()
    sendRaw(string.format('{"t":"ping","s":%d}', pingSeq))
    -- Cleanup old unacknowledged pings (older than 5s)
    local now = socket.gettime()
    for seq, t in pairs(pingSendTime) do
        if now - t > 5.0 then
            pingSendTime[seq] = nil
        end
    end
end

-- Send pong response
local function sendPong(seq)
    sendRaw(string.format('{"t":"pong","s":%d}', seq))
end

-- Process pong (RTT measurement)
local function processPong(seq)
    local sentAt = pingSendTime[seq]
    if not sentAt then return end
    pingSendTime[seq] = nil
    
    local rtt = (socket.gettime() - sentAt) * 1000 -- ms
    currentPing = rtt
    
    -- Store in ring buffer for jitter and sparkline
    pingHistoryIdx = (pingHistoryIdx % pingHistorySize) + 1
    pingHistory[pingHistoryIdx] = rtt
    
    -- Calculate jitter as average deviation from mean
    local count = #pingHistory
    if count >= 2 then
        local sum = 0
        for i = 1, count do
            sum = sum + pingHistory[i]
        end
        local mean = sum / count
        local devSum = 0
        for i = 1, count do
            devSum = devSum + math.abs(pingHistory[i] - mean)
        end
        currentJitter = devSum / count
    end
end

-- Calculate per-second metrics
local function updateMetricsWindow()
    txRate = txPackets
    rxRate = rxPackets
    txBandwidth = txBytes / 1024   -- KB/s
    rxBandwidth = rxBytes / 1024   -- KB/s
    
    -- Calculate packet loss
    if remoteTotalExpected > 0 then
        packetLoss = (remoteLostCount / remoteTotalExpected) * 100
    else
        packetLoss = 0
    end
    
    -- Reset window counters
    txPackets = 0
    rxPackets = 0
    txBytes = 0
    rxBytes = 0
    
    notifyMetrics()
end

-- Adaptive send rate adjustment
local function adaptSendRate()
    if not M.adaptiveHzEnabled then
        sendRate = minSendRate
        currentHz = math.floor(1 / minSendRate + 0.5)
        return
    end
    
    local prevRate = sendRate
    if packetLoss > 3 or currentJitter > 50 then
        -- Network stressed: reduce frequency
        sendRate = math.min(sendRate * 1.5, maxSendRate)
    elseif packetLoss < 1 and currentJitter < 20 and sendRate > minSendRate then
        -- Network healthy: increase frequency
        sendRate = math.max(sendRate / 1.2, minSendRate)
    end
    
    currentHz = math.floor(1 / sendRate + 0.5)
    
    if sendRate ~= prevRate then
        log('I', 'lanMultiplayer', string.format('Adaptive rate: %.1f Hz (loss=%.1f%%, jitter=%.1fms)', currentHz, packetLoss, currentJitter))
    end
end

-- Set nickname from UI
local function setNickname(name)
    if not name or name == "" then
        name = "Player"
    end
    myNickname = name
    saveSettings(state ~= "IDLE")
    notifyUI()
    
    -- If connected, send a spawn packet to immediately update nickname on friend's client
    if state == "CONNECTED" then
        local myVeh = be:getPlayerVehicle(0)
        local model, config = getVehicleInfo(myVeh)
        sendSpawn(model, config)
    end
end

-- Store remote vehicle target state from binary packet (0 allocations for JSON decoding)
local function updateRemoteVehicleBinary(data)
    if not remoteVehicleId then return end
    
    -- Track packet loss via sequence numbers
    local seq = data.seq
    if remoteLastSeq > 0 then
        local expected = seq - remoteLastSeq
        if expected > 0 then
            local lost = expected - 1
            remoteLostCount = remoteLostCount + lost
            remoteTotalExpected = remoteTotalExpected + expected
        end
    else
        remoteTotalExpected = remoteTotalExpected + 1
    end
    remoteLastSeq = seq
    
    -- Update timestamp of last received packet
    M._lastPacketTimestamp = socket.gettime()
    
    -- Parse target state into pre-allocated FFI objects (0 heap allocations)
    remoteTargetPos.x = data.px
    remoteTargetPos.y = data.py
    remoteTargetPos.z = data.pz
    
    remoteTargetRot.x = data.rx
    remoteTargetRot.y = data.ry
    remoteTargetRot.z = data.rz
    remoteTargetRot.w = data.rw
    
    remoteTargetVel.x = data.vx
    remoteTargetVel.y = data.vy
    remoteTargetVel.z = data.vz
    
    remoteTargetAngVel.x = data.ax
    remoteTargetAngVel.y = data.ay
    remoteTargetAngVel.z = data.az
    
    hasRemoteState = true
    
    -- Calculate speed for 3D drawing
    remoteLastSpeed = math.sqrt(data.vx*data.vx + data.vy*data.vy + data.vz*data.vz) * 3.6
    
    -- Update remote target states to be smoothed in onUpdate
    remoteTargetInputs.t = data.throttle
    remoteTargetInputs.s = data.steering
    remoteTargetInputs.b = data.brake
    remoteTargetInputs.c = data.clutch
    remoteTargetInputs.hb = data.handbrake
    
    remoteTargetRPM = data.rpm
    remoteTargetWS = data.wheelSpeed
    remoteTargetGear = data.gear
    remoteTargetLights = data.lights
    remoteTargetFlags = data.flags
    
    local remoteVeh = be:getObjectByID(remoteVehicleId)
    if remoteVeh then
        -- 1. Handle Ghost Mode (bit 0 of flags)
        local remoteGhost = bit.band(data.flags, 1) ~= 0
        local currentGhost = remoteGhost or M.ghostModeEnabled
        if currentGhost ~= lastGhostState then
            lastGhostState = currentGhost
            remoteVeh:setField('collision', 0, currentGhost and 'false' or 'true')
            remoteVeh:setField('collisionType', 0, currentGhost and 'None' or 'Collision Mesh')
            log('I', 'lanMultiplayer', 'Ghost mode state toggled: ' .. tostring(currentGhost))
        end
    end
end

-- Store remote vehicle target state from packet (applied with smoothing in onUpdate)
local function updateRemoteVehicle(data)
    if not remoteVehicleId then return end
    
    -- Track packet loss via sequence numbers
    local seq = data.s
    if seq then
        if remoteLastSeq > 0 then
            local expected = seq - remoteLastSeq
            if expected > 0 then
                local lost = expected - 1
                remoteLostCount = remoteLostCount + lost
                remoteTotalExpected = remoteTotalExpected + expected
            end
        else
            remoteTotalExpected = remoteTotalExpected + 1
        end
        remoteLastSeq = seq
    end
    
    -- Parse target state
    local p, r, v, av, inputs
    if data.t == "u" then
        local dp = data.p
        local dr = data.r
        local dv = data.v
        local dav = data.a
        p = vec3(dp[1], dp[2], dp[3])
        r = quat(dr[1], dr[2], dr[3], dr[4])
        v = vec3(dv[1], dv[2], dv[3])
        av = vec3(dav[1], dav[2], dav[3])
        inputs = data.i
    else
        p = vec3(data.pos.x, data.pos.y, data.pos.z)
        r = quat(data.rot.x, data.rot.y, data.rot.z, data.rot.w)
        v = vec3(data.vel.x, data.vel.y, data.vel.z)
        av = vec3(data.angVel.x, data.angVel.y, data.angVel.z)
        inputs = data.inputs
    end
    
    -- Update timestamp of last received packet
    M._lastPacketTimestamp = socket.gettime()

    -- Store target state for smoothed application in onUpdate
    remoteTargetPos.x = p.x
    remoteTargetPos.y = p.y
    remoteTargetPos.z = p.z
    
    remoteTargetRot.x = r.x
    remoteTargetRot.y = r.y
    remoteTargetRot.z = r.z
    remoteTargetRot.w = r.w
    
    remoteTargetVel.x = v.x
    remoteTargetVel.y = v.y
    remoteTargetVel.z = v.z
    
    remoteTargetAngVel.x = av.x
    remoteTargetAngVel.y = av.y
    remoteTargetAngVel.z = av.z
    
    hasRemoteState = true

    
    -- Calculate remote speed for 3D display (m/s -> km/h)
    remoteLastSpeed = math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z) * 3.6
    
    -- Apply control inputs to vehicle VM (filtered to avoid cross-VM command flooding)
    if inputs then
        local t, s, b, c, hb
        if data.t == "u" then
            t = inputs[1] or 0
            s = inputs[2] or 0
            b = inputs[3] or 0
            c = inputs[4] or 0
            hb = inputs[5] or 0
        else
            t = inputs.throttle or 0
            s = inputs.steering or 0
            b = inputs.brake or 0
            c = inputs.clutch or 0
            hb = inputs.handbrake or 0
        end
        
        remoteTargetInputs.t = t
        remoteTargetInputs.s = s
        remoteTargetInputs.b = b
        remoteTargetInputs.c = c
        remoteTargetInputs.hb = hb
    end
    
    remoteTargetRPM = data.rpm or 0
    remoteTargetWS = data.wheelSpeed or 0
    remoteTargetGear = data.gear or 0
    remoteTargetLights = data.lights or 0
    remoteTargetFlags = data.flags or 0
end

-- Apply smoothed remote vehicle state every frame using pre-allocated objects
local function applySmoothedRemoteState(dtReal)
    if not remoteVehicleId or not hasRemoteState then return end
    
    local remoteVeh = be:getObjectByID(remoteVehicleId)
    if not remoteVeh then return end
    
    -- Calculate target position based on PLC settings
    local targetX = remoteTargetPos.x
    local targetY = remoteTargetPos.y
    local targetZ = remoteTargetPos.z

    if M.plcEnabled then
        if M.useTimeBasedExtrap and M._lastPacketTimestamp > 0 then
            local timeSinceLastPacket = socket.gettime() - M._lastPacketTimestamp
            targetX = remoteTargetPos.x + remoteTargetVel.x * timeSinceLastPacket
            targetY = remoteTargetPos.y + remoteTargetVel.y * timeSinceLastPacket
            targetZ = remoteTargetPos.z + remoteTargetVel.z * timeSinceLastPacket
        else
            -- Old dtReal-based cumulative extrapolation
            remoteTargetPos.x = remoteTargetPos.x + remoteTargetVel.x * dtReal
            remoteTargetPos.y = remoteTargetPos.y + remoteTargetVel.y * dtReal
            remoteTargetPos.z = remoteTargetPos.z + remoteTargetVel.z * dtReal
            targetX = remoteTargetPos.x
            targetY = remoteTargetPos.y
            targetZ = remoteTargetPos.z
        end
    end
    
    local currentPos = remoteVeh.getPosition and remoteVeh:getPosition()
    local rawRot = remoteVeh.getRotation and remoteVeh:getRotation()
    if not currentPos or not rawRot then return end
    local currentRot = quat(rawRot)
    
    -- Calculate distance to target
    local dx = targetX - currentPos.x
    local dy = targetY - currentPos.y
    local dz = targetZ - currentPos.z
    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
    
    local currentSmoothSpeed = smoothSpeed
    if M.jitterBufferEnabled then
        -- Base speed is 30. Reduce speed (increase smoothing) as jitter and packet loss increase.
        local jitterPenalty = math.min(15, currentJitter * 0.3)
        local lossPenalty = math.min(5, packetLoss * 0.5)
        currentSmoothSpeed = math.max(10, 30 - jitterPenalty - lossPenalty)
    end
    
    local targetRotX = remoteTargetRot.x
    local targetRotY = remoteTargetRot.y
    local targetRotZ = remoteTargetRot.z
    local targetRotW = remoteTargetRot.w
    
    -- Quaternion Hemisphere Check to prevent 360 flips
    if M.hemisphereCheckEnabled then
        local dot = currentRot.x * targetRotX + currentRot.y * targetRotY + currentRot.z * targetRotZ + currentRot.w * targetRotW
        if dot < 0 then
            targetRotX = -targetRotX
            targetRotY = -targetRotY
            targetRotZ = -targetRotZ
            targetRotW = -targetRotW
        end
    end
    
    if dist < smoothThreshold then
        -- Very close: snap directly (no visible difference)
        remoteVeh:setPosRot(targetX, targetY, targetZ, targetRotX, targetRotY, targetRotZ, targetRotW)
    else
        -- Smooth exponential convergence (frame-rate independent)
        local alpha = 1.0 - math.exp(-currentSmoothSpeed * dtReal)
        
        -- In-place modification of pre-allocated vec3 to avoid allocations
        smoothedPos.x = currentPos.x + alpha * (targetX - currentPos.x)
        smoothedPos.y = currentPos.y + alpha * (targetY - currentPos.y)
        smoothedPos.z = currentPos.z + alpha * (targetZ - currentPos.z)
        
        -- NLerp rotation interpolation
        local rx = currentRot.x + alpha * (targetRotX - currentRot.x)
        local ry = currentRot.y + alpha * (targetRotY - currentRot.y)
        local rz = currentRot.z + alpha * (targetRotZ - currentRot.z)
        local rw = currentRot.w + alpha * (targetRotW - currentRot.w)
        
        local len = math.sqrt(rx*rx + ry*ry + rz*rz + rw*rw)
        if len > 0.0001 then
            rx = rx / len
            ry = ry / len
            rz = rz / len
            rw = rw / len
        else
            rx, ry, rz, rw = targetRotX, targetRotY, targetRotZ, targetRotW
        end
        
        remoteVeh:setPosRot(smoothedPos.x, smoothedPos.y, smoothedPos.z, rx, ry, rz, rw)
        
        M._debugRotTimer = (M._debugRotTimer or 0) + dtReal
        if M._debugRotTimer >= 1.0 then
            M._debugRotTimer = 0
            log('I', 'lanMultiplayer', string.format("ROTATION DEBUG - currentPos: %s, remoteTargetPos: %s, remoteTargetRot: %s", tostring(currentPos), tostring(remoteTargetPos), tostring(remoteTargetRot)))
        end
    end
    
    -- Always set velocity/angularVelocity for physics dead reckoning and visuals
    if remoteVeh.setVelocity and remoteTargetVel then
        remoteVeh:setVelocity(remoteTargetVel)
    end
    if remoteVeh.setAngularVelocity and remoteTargetAngVel then
        remoteVeh:setAngularVelocity(remoteTargetAngVel)
    end
end

-- Packet processor
local function processPacket(rawMsg, ip, port)
    -- Track active sessions
    if ip and port then
        M._sessions = M._sessions or {}
        M._sessions[ip .. ":" .. port] = socket.gettime()
    end

    -- Track RX counters
    rxPackets = rxPackets + 1
    rxBytes = rxBytes + #rawMsg
    
    -- Check if it's a binary BUPD update packet (exact length 92, matching magic number)
    local m1, m2, m3, m4 = string.byte(rawMsg, 1, 4)
    if #rawMsg == 92 and m1 == 68 and m2 == 80 and m3 == 85 and m4 == 66 then -- "DPUB"
        lastPacketTime = os.clock()
        ffi.copy(inPacket, rawMsg, 92)
        updateRemoteVehicleBinary(inPacket)
        return
    end
    
    -- Debug logging for incoming JSON packets (ignore position updates and pings/pongs)
    local j1, j2, j3, j4, j5, j6, j7, j8, j9 = string.byte(rawMsg, 2, 10)
    local isUpdateOrPingPong = false
    if j1 == 34 and j2 == 116 and j3 == 34 and j4 == 58 and j5 == 34 then -- starts with '"t":"'
        if j6 == 117 and j7 == 34 then -- 'u"'
            isUpdateOrPingPong = true
        elseif j6 == 112 and j7 == 105 and j8 == 110 and j9 == 103 then -- 'ping'
            isUpdateOrPingPong = true
        elseif j6 == 112 and j7 == 111 and j8 == 110 and j9 == 103 then -- 'pong'
            isUpdateOrPingPong = true
        end
    end
    
    if not isUpdateOrPingPong then
        log('I', 'lanMultiplayer', 'Received packet from ' .. tostring(ip) .. ':' .. tostring(port) .. ' : ' .. rawMsg:sub(1, 120) .. '... (size: ' .. tostring(#rawMsg) .. ' bytes)')
    end
    
    local msg = jsonDecode(rawMsg)
    if not msg then
        log('W', 'lanMultiplayer', 'Failed to decode incoming JSON packet of size ' .. tostring(#rawMsg) .. ' from ' .. tostring(ip))
        return
    end
    
    local msgType = msg.type or msg.t
    if not msgType then return end
    
    lastPacketTime = os.clock()
    
    -- Ping/Pong handling (works in any connected state)
    if msgType == "ping" then
        sendPong(msg.s)
        return
    end
    if msgType == "pong" then
        processPong(msg.s)
        return
    end
    
    -- Host logic to establish connection
    if (state == "HOSTING" or (state == "CONNECTED" and role == "HOST")) and msgType == "connect" then
        targetIp = ip
        targetPort = port
        state = "CONNECTED"
        remoteNickname = msg.nickname or "Client"
        resetMetrics()
        log('I', 'lanMultiplayer', 'Client connected/reconnected from ' .. tostring(ip) .. ':' .. tostring(port) .. ' (' .. tostring(remoteNickname) .. ')')
        
        local myVeh = be:getPlayerVehicle(0)
        local model, config = getVehicleInfo(myVeh)
        local pos = myVeh and myVeh.getPosition and myVeh:getPosition()
        local rot = myVeh and myVeh.getRotation and quat(myVeh:getRotation())
        
        -- Filter config to prevent packet fragmentation
        local safeConfig = getSafeConfigPayload(config)
        
        local payload = {
            type = "connect_ack",
            model = model,
            config = safeConfig,
            nickname = myNickname,
            mapPath = getCurrentMapPath(),
            pos = pos and { x = pos.x, y = pos.y, z = pos.z } or nil,
            rot = rot and { x = rot.x, y = rot.y, z = rot.z, w = rot.w } or nil
        }
        sendPacket(payload)
        notifyUI()
        
        if msg.model and (msg.model ~= remoteVehicleModel or not areConfigsEqual(msg.config, remoteVehicleConfig) or not remoteVehicleId) then
            spawnRemoteVehicle(msg.model, msg.config, msg.pos, msg.rot)
        end
        return
    end
    
    -- Client logic to establish connection
    if state == "CONNECTING" and msgType == "connect_ack" then
        state = "CONNECTED"
        remoteNickname = msg.nickname or "Host"
        resetMetrics()
        log('I', 'lanMultiplayer', 'Connected to host successfully! (' .. tostring(remoteNickname) .. ')')
        notifyUI()
        
        checkAndLoadMap(msg.mapPath)
        
        local myVeh = be:getPlayerVehicle(0)
        local model, config = getVehicleInfo(myVeh)
        sendSpawn(model, config)
        
        if msg.model then
            spawnRemoteVehicle(msg.model, msg.config, msg.pos, msg.rot)
        end
        return
    end
    
    -- Connected state updates
    if state == "CONNECTED" then
        if msgType == "update" or msgType == "u" then
            updateRemoteVehicle(msg)
        elseif msgType == "spawn" then
            if msg.nickname then
                remoteNickname = msg.nickname
                notifyUI()
            end
            if msg.model and (msg.model ~= remoteVehicleModel or (M.tuningSyncEnabled and not areConfigsEqual(msg.config, remoteVehicleConfig)) or not remoteVehicleId) then
                spawnRemoteVehicle(msg.model, msg.config, msg.pos, msg.rot)
            end
        elseif msgType == "reset" then
            if remoteVehicleId then
                local remoteVeh = be:getObjectByID(remoteVehicleId)
                if remoteVeh then
                    remoteVeh:queueLuaCommand("obj:requestReset(RESET_PHYSICS)")
                    log('I', 'lanMultiplayer', 'Reset remote vehicle damage.')
                end
            end
        elseif msgType == "damage" then
            if M.damageSyncEnabled and remoteVehicleId then
                local remoteVeh = be:getObjectByID(remoteVehicleId)
                if remoteVeh then
                    remoteVeh:queueLuaCommand(string.format("globalApplyDeformedNodes(%s)", jsonEncode(msg.nodes)))
                    log('I', 'lanMultiplayer', 'Applied damage sync nodes to remote vehicle.')
                end
            end
        elseif msgType == "backfire" then
            if M.backfireSyncEnabled and remoteVehicleId then
                local remoteVeh = be:getObjectByID(remoteVehicleId)
                if remoteVeh then
                    remoteVeh:queueLuaCommand("if exhaust then exhaust.backfire(1) end")
                end
            end
        elseif msgType == "recovery" then
            if M.recoverySyncEnabled and remoteVehicleId then
                local remoteVeh = be:getObjectByID(remoteVehicleId)
                if remoteVeh then
                    local rp = msg.pos
                    local rr = msg.rot
                    remoteVeh:setPosRot(rp.x, rp.y, rp.z, rr.x, rr.y, rr.z, rr.w)
                    remoteTargetPos.x = rp.x
                    remoteTargetPos.y = rp.y
                    remoteTargetPos.z = rp.z
                    remoteTargetRot.x = rr.x
                    remoteTargetRot.y = rr.y
                    remoteTargetRot.z = rr.z
                    remoteTargetRot.w = rr.w
                    remoteTargetVel.x = 0; remoteTargetVel.y = 0; remoteTargetVel.z = 0
                    remoteTargetAngVel.x = 0; remoteTargetAngVel.y = 0; remoteTargetAngVel.z = 0
                    log('I', 'lanMultiplayer', 'Applied remote recovery snap.')
                end
            end
        elseif msgType == "chat" then
            guihooks.trigger("lanMultiplayerChat", {
                sender = msg.sender or "Friend",
                text = msg.text or ""
            })
            if remoteVehicleId and msg.text then
                M._chatText = msg.text
                M._chatTimer = 3.0
            end
        end
    end
end

-- Pre-allocated packets pool to achieve zero dynamic memory allocations in receivePackets
local packetsToProcess = {}
local packetPool = {}
local poolSize = 0

local function getPoolPacket(data, ip, port)
    local pkt = packetPool[poolSize + 1]
    if not pkt then
        pkt = {}
        packetPool[poolSize + 1] = pkt
    end
    poolSize = poolSize + 1
    pkt.data = data
    pkt.ip = ip
    pkt.port = port
    return pkt
end

local function handleIncoming(data, ip, port, now)
    if M.netEmulatorEnabled then
        if math.random() < M.debugDropRate then
            return -- simulate drop
        end
        if M.debugJitterMaxMs > 0 then
            local delay = math.random() * M.debugJitterMaxMs / 1000
            table.insert(M._jitterQueue, {
                data = data,
                ip = ip,
                port = port,
                executeAt = now + delay
            })
            return -- simulate jitter delay
        end
    end
    table.insert(packetsToProcess, getPoolPacket(data, ip, port))
end

-- Read socket inputs and drop duplicate/old updates to avoid buffer bloat and ping spikes
local function receivePackets()
    if not udpSocket then return end
    
    M._jitterQueue = M._jitterQueue or {}
    local now = socket.gettime()
    
    -- Clear pre-allocated tables for the new frame
    poolSize = 0
    table_clear(packetsToProcess)
    
    -- 1. Read all new packets from socket
    if role == "CLIENT" then
        while true do
            local data, err = udpSocket:receive()
            if not data then break end
            handleIncoming(data, targetIp, targetPort, now)
        end
    else
        while true do
            local data, ip, port = udpSocket:receivefrom()
            if not data then break end
            handleIncoming(data, ip, port, now)
        end
    end
    
    -- 2. Process ready delayed packets from jitter queue
    for i = #M._jitterQueue, 1, -1 do
        local pkt = M._jitterQueue[i]
        if now >= pkt.executeAt then
            table.insert(packetsToProcess, pkt)
            table.remove(M._jitterQueue, i)
        end
    end
    
    -- 3. Filter update packets and keep only the latest seq
    local latestUpdateMsg = nil
    local latestUpdateSeq = -1
    local latestUpdateIp = nil
    local latestUpdatePort = nil
    
    for _, pkt in ipairs(packetsToProcess) do
        local data = pkt.data
        local ip = pkt.ip
        local port = pkt.port
        
        local isUpdate = false
        local seq = 0
        local dataLen = #data
        
        -- Safe length check before string.byte to avoid crashes
        if dataLen == 92 then
            local m1, m2, m3, m4 = string.byte(data, 1, 4)
            if m1 == 68 and m2 == 80 and m3 == 85 and m4 == 66 then -- "DPUB"
                isUpdate = true
                local b1, b2, b3, b4 = string.byte(data, 5, 8)
                seq = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
            end
        elseif dataLen >= 10 then
            local b1, b2, b3, b4, b5, b6, b7 = string.byte(data, 1, 7)
            local isJsonUpdate = (b1 == 123 and b2 == 34 and b3 == 116 and b4 == 34 and b5 == 58 and b6 == 34 and b7 == 117) -- '{"t":"u"'
            if not isJsonUpdate then
                local b8, b9, b10 = string.byte(data, 8, 10)
                isJsonUpdate = (b1 == 123 and b2 == 34 and b3 == 112 and b4 == 121 and b5 == 112 and b6 == 101 and b7 == 34 and b8 == 58 and b9 == 34 and b10 == 117) -- '{"type":"u"'
            end
            if isJsonUpdate then
                isUpdate = true
                local seqStr = data:match('"s":(%d+)')
                seq = seqStr and tonumber(seqStr) or 0
            end
        end
        
        if isUpdate then
            if seq > latestUpdateSeq then
                latestUpdateSeq = seq
                latestUpdateMsg = data
                latestUpdateIp = ip
                latestUpdatePort = port
            end
        else
            processPacket(data, ip, port)
        end
    end
    
    -- Process ONLY the latest update packet from this frame's network buffer
    if latestUpdateMsg then
        processPacket(latestUpdateMsg, latestUpdateIp or targetIp, latestUpdatePort or targetPort)
    end
end

-- Connection handshake routine for client
local function handleConnectingHandshake(dt)
    if state ~= "CONNECTING" then return end
    
    connectTimer = connectTimer + dt
    if connectTimer >= 1.0 then
        connectTimer = 0
        local myVeh = be:getPlayerVehicle(0)
        local model, config = getVehicleInfo(myVeh)
        local pos = myVeh and myVeh.getPosition and myVeh:getPosition()
        local rot = myVeh and myVeh.getRotation and quat(myVeh:getRotation())
        
        -- Filter config to prevent packet fragmentation
        local safeConfig = getSafeConfigPayload(config)
        
        local payload = {
            type = "connect",
            model = model,
            config = safeConfig,
            nickname = myNickname,
            mapPath = getCurrentMapPath(),
            pos = pos and { x = pos.x, y = pos.y, z = pos.z } or nil,
            rot = rot and { x = rot.x, y = rot.y, z = rot.z, w = rot.w } or nil
        }
        sendPacket(payload)
    end
end

-- Timeout detection
local function checkTimeout()
    if state == "CONNECTED" then
        if os.clock() - lastPacketTime > timeoutLimit then
            log('W', 'lanMultiplayer', 'Connection timed out!')
            if role == "HOST" then
                deleteRemoteVehicle()
                targetIp = nil
                targetPort = nil
                state = "HOSTING"
                remoteNickname = "Friend"
                resetMetrics()
                log('I', 'lanMultiplayer', 'Host reverted to listening.')
                notifyUI()
            else
                deleteRemoteVehicle()
                state = "CONNECTING"
                remoteNickname = "Friend"
                resetMetrics()
                log('I', 'lanMultiplayer', 'Client reverted to reconnecting.')
                notifyUI()
            end
        end
    end
end

--- Main Game Loop update hook
local function onUpdate(dtReal, dtSim)
    -- 1. If IDLE, only poll discovery and clean old lobbies
    if state == "IDLE" then
        if not discoveryRecvSocket then
            local sock = socket.udp()
            sock:settimeout(0)
            local success, bindErr = sock:setsockname("0.0.0.0", 27019)
            if success then
                discoveryRecvSocket = sock
            end
        end
        
        if discoveryRecvSocket then
            local data, ip, port = discoveryRecvSocket:receivefrom()
            local receivedAny = false
            while data do
                local msg = jsonDecode(data)
                if msg and msg.type == "lobby" then
                    local key = ip .. ":" .. tostring(msg.port or 27015)
                    discoveredLobbies[key] = {
                        nickname = msg.nickname or "Host",
                        ip = ip,
                        port = msg.port or 27015,
                        lastHeard = os.clock()
                    }
                    receivedAny = true
                end
                data, ip, port = discoveryRecvSocket:receivefrom()
            end
            
            lobbyCleanTimer = lobbyCleanTimer + dtReal
            if lobbyCleanTimer >= 1.0 or receivedAny then
                lobbyCleanTimer = 0
                local now = os.clock()
                local changed = false
                for key, lobby in pairs(discoveredLobbies) do
                    if now - lobby.lastHeard > 10.0 then
                        discoveredLobbies[key] = nil
                        changed = true
                    end
                end
                
                if changed or receivedAny then
                    local list = {}
                    for _, lobby in pairs(discoveredLobbies) do
                        table.insert(list, {
                            nickname = lobby.nickname,
                            ip = lobby.ip,
                            port = lobby.port
                        })
                    end
                    if guihooks then
                        guihooks.trigger("lanMultiplayerLobby", list)
                    end
                end
            end
        end
        return
    end
    
    if discoveryRecvSocket then
        discoveryRecvSocket:close()
        discoveryRecvSocket = nil
    end
    
    -- 1. Receive packets
    receivePackets()
    
    -- 2. Handle handshake if connecting
    handleConnectingHandshake(dtReal)
    
    -- 3. Check for timeouts
    checkTimeout()
    
    -- 4. Active Host Lobby Beaconing
    if (state == "HOSTING" or state == "CONNECTED") and role == "HOST" then
        beaconTimer = beaconTimer + dtReal
        if beaconTimer >= 3.0 then
            beaconTimer = 0
            if not discoverySendSocket then
                local sock = socket.udp()
                sock:settimeout(0)
                sock:setoption("broadcast", true)
                discoverySendSocket = sock
            end
            if discoverySendSocket then
                local payload = jsonEncode({
                    type = "lobby",
                    nickname = myNickname,
                    port = listenPort
                })
                discoverySendSocket:sendto(payload, "255.255.255.255", 27019)
            end
        end
    else
        beaconTimer = 0
        if discoverySendSocket then
            discoverySendSocket:close()
            discoverySendSocket = nil
        end
    end
    
    -- 5. Connected state logic
    if state == "CONNECTED" then
        -- 5a. Send update packets at adaptive Hz (capped to frame rate)
        sendTimer = sendTimer + dtReal
        if sendTimer >= sendRate then
            sendTimer = sendTimer - sendRate
            if sendTimer > sendRate then
                sendTimer = 0
            end
            
            local myVeh = be:getPlayerVehicle(0)
            if myVeh then
                local myId = myVeh:getId()
                
                -- Check model and config once every second, or immediately if vehicle ID changes
                vehicleCheckTimer = vehicleCheckTimer + dtReal
                if vehicleCheckTimer >= 1.0 or myId ~= myVehicleId then
                    vehicleCheckTimer = 0
                    local model, config = getVehicleInfo(myVeh)
                    if myId ~= myVehicleId or model ~= lastMyVehicleModel or not areConfigsEqual(config, lastMyVehicleConfig) then
                        local isNewPhysicalVehicle = (myId ~= myVehicleId)
                        
                        myVehicleId = myId
                        lastMyVehicleModel = model
                        lastMyVehicleConfig = config
                        log('I', 'lanMultiplayer', 'Vehicle change detected. Sending spawn packet.')
                        sendSpawn(model, config)
                        
                        -- Register electrics change notifications strictly once per unique physical vehicle
                        if isNewPhysicalVehicle and core_vehicleBridge then
                            core_vehicleBridge.registerValueChangeNotification(myVeh, 'rpm')
                            core_vehicleBridge.registerValueChangeNotification(myVeh, 'wheelspeed')
                            core_vehicleBridge.registerValueChangeNotification(myVeh, 'gearIndex')
                            core_vehicleBridge.registerValueChangeNotification(myVeh, 'lights_state')
                            core_vehicleBridge.registerValueChangeNotification(myVeh, 'signal_L')
                            core_vehicleBridge.registerValueChangeNotification(myVeh, 'signal_R')
                            core_vehicleBridge.registerValueChangeNotification(myVeh, 'hazard')
                            core_vehicleBridge.registerValueChangeNotification(myVeh, 'fog')
                            core_vehicleBridge.registerValueChangeNotification(myVeh, 'lightbar')
                            core_vehicleBridge.registerValueChangeNotification(myVeh, 'horn')
                            log('I', 'lanMultiplayer', 'Registered core_vehicleBridge notifications for new vehicle ID: ' .. tostring(myId))
                        end
                    end
                end
                
                -- Send backfire events if backfireSync is active
                if M.backfireSyncEnabled then
                    local localBackfire = core_vehicleBridge.getCachedVehicleData(myId, 'backfire') or 0
                    if localBackfire > 0 and not M._localBackfireTriggered then
                        M._localBackfireTriggered = true
                        sendPacket({ type = "backfire" })
                    elseif localBackfire == 0 then
                        M._localBackfireTriggered = false
                    end
                end
                
                -- Check local quick recovery event
                local currentPos = myVeh:getPosition()
                if prevLocalPosInitialized then
                    local dist = currentPos:distance(prevLocalPos)
                    local speed = myVeh:getVelocity():length()
                    if M.recoverySyncEnabled and dist > 10.0 and speed < 5.0 then
                        local rot = quat(myVeh:getRotation())
                        sendPacket({
                            type = "recovery",
                            pos = { x = currentPos.x, y = currentPos.y, z = currentPos.z },
                            rot = { x = rot.x, y = rot.y, z = rot.z, w = rot.w }
                        })
                        log('I', 'lanMultiplayer', 'Local vehicle recovery snap detected. Sending sync packet.')
                    end
                end
                prevLocalPos.x = currentPos.x
                prevLocalPos.y = currentPos.y
                prevLocalPos.z = currentPos.z
                prevLocalPosInitialized = true
                
                sendUpdate()
            end
        end
        
        -- 5b. Decoupled input extrapolation / smoothing
        if remoteVehicleId and hasRemoteState then
            if M.inputExtrapEnabled then
                local alpha = 1.0 - math.exp(-15 * dtReal)
                lastRemoteInputs.t = lastRemoteInputs.t + alpha * (remoteTargetInputs.t - lastRemoteInputs.t)
                lastRemoteInputs.s = lastRemoteInputs.s + alpha * (remoteTargetInputs.s - lastRemoteInputs.s)
                lastRemoteInputs.b = lastRemoteInputs.b + alpha * (remoteTargetInputs.b - lastRemoteInputs.b)
                lastRemoteInputs.c = lastRemoteInputs.c + alpha * (remoteTargetInputs.c - lastRemoteInputs.c)
                lastRemoteInputs.hb = lastRemoteInputs.hb + alpha * (remoteTargetInputs.hb - lastRemoteInputs.hb)
            else
                lastRemoteInputs.t = remoteTargetInputs.t
                lastRemoteInputs.s = remoteTargetInputs.s
                lastRemoteInputs.b = remoteTargetInputs.b
                lastRemoteInputs.c = remoteTargetInputs.c
                lastRemoteInputs.hb = remoteTargetInputs.hb
            end
            
            -- Limit IPC command rate to 50 Hz (20ms interval) to prevent Vehicle VM message queue flooding
            M._ipcTimer = (M._ipcTimer or 0) + dtReal
            if M._ipcTimer >= 0.02 then
                M._ipcTimer = M._ipcTimer - 0.02
                if M._ipcTimer > 0.02 then M._ipcTimer = 0 end
                
                local inputsChanged = math.abs(lastRemoteInputs.t - M._lastSyncedInputs.t) > 0.01 or
                                      math.abs(lastRemoteInputs.s - M._lastSyncedInputs.s) > 0.01 or
                                      math.abs(lastRemoteInputs.b - M._lastSyncedInputs.b) > 0.01 or
                                      math.abs(lastRemoteInputs.c - M._lastSyncedInputs.c) > 0.01 or
                                      math.abs(lastRemoteInputs.hb - M._lastSyncedInputs.hb) > 0.01
                
                local stateChanged = math.abs(remoteTargetRPM - M._lastSyncedRPM) > 50 or
                                     math.abs(remoteTargetWS - M._lastSyncedWS) > 0.5 or
                                     remoteTargetGear ~= M._lastSyncedGear or
                                     remoteTargetLights ~= M._lastSyncedLights or
                                     remoteTargetFlags ~= M._lastSyncedFlags
                
                M._updateCounter = (M._updateCounter or 0) + 1
                if inputsChanged or stateChanged or M._updateCounter >= 10 then
                    M._updateCounter = 0
                    M._lastSyncedInputs.t = lastRemoteInputs.t
                    M._lastSyncedInputs.s = lastRemoteInputs.s
                    M._lastSyncedInputs.b = lastRemoteInputs.b
                    M._lastSyncedInputs.c = lastRemoteInputs.c
                    M._lastSyncedInputs.hb = lastRemoteInputs.hb
                    M._lastSyncedRPM = remoteTargetRPM
                    M._lastSyncedWS = remoteTargetWS
                    M._lastSyncedGear = remoteTargetGear
                    M._lastSyncedLights = remoteTargetLights
                    M._lastSyncedFlags = remoteTargetFlags
                    
                    local soundSyncVal = M.soundSyncEnabled and 1 or 0
                    local wheelSyncVal = M.wheelSyncEnabled and 1 or 0
                    local lightsSyncVal = M.lightsSyncEnabled and 1 or 0
                    
                    local remoteVeh = be:getObjectByID(remoteVehicleId)
                    if remoteVeh then
                        local cmd = string.format("globalSyncVeh(%f,%f,%f,%f,%f,%f,%d,%f,%d,%d,%d,%d,%d)", 
                            lastRemoteInputs.t, lastRemoteInputs.s, lastRemoteInputs.b, lastRemoteInputs.c, lastRemoteInputs.hb, 
                            remoteTargetRPM, remoteTargetGear, remoteTargetWS, remoteTargetLights, remoteTargetFlags, 
                            soundSyncVal, wheelSyncVal, lightsSyncVal)
                        remoteVeh:queueLuaCommand(cmd)
                    end
                end
            end
        end
        
        -- 5c. Apply remote vehicle state with CPU time tracking
        local startTime = socket.gettime()
        applySmoothedRemoteState(dtReal)
        local duration = (socket.gettime() - startTime) * 1000 -- ms
        M._cpuFrameTimeMs = (M._cpuFrameTimeMs or 0.0) * 0.95 + duration * 0.05
        
        -- Track active sessions and FPS degradation if sessions > 5
        local now = socket.gettime()
        local sessionCount = 0
        M._sessions = M._sessions or {}
        for key, lastTime in pairs(M._sessions) do
            if now - lastTime > 5.0 then
                M._sessions[key] = nil
            else
                sessionCount = sessionCount + 1
            end
        end
        M._activeSessionsCount = sessionCount
        
        if M._activeSessionsCount > 5 and duration > 1.0 then
            log('W', 'lanMultiplayer', string.format('Performance degradation detected! applySmoothedRemoteState took %.2f ms with %d active sessions.', duration, M._activeSessionsCount))
        end

        -- 5d. Periodic ping
        pingTimer = pingTimer + dtReal
        if pingTimer >= pingInterval then
            pingTimer = pingTimer - pingInterval
            sendPing()
        end
        
        -- 5e. Per-second metrics window
        metricsTimer = metricsTimer + dtReal
        if metricsTimer >= metricsInterval then
            metricsTimer = metricsTimer - metricsInterval
            updateMetricsWindow()
        end
        
        -- 5f. Adaptive send rate re-evaluation
        adaptiveTimer = adaptiveTimer + dtReal
        if adaptiveTimer >= adaptiveInterval then
            adaptiveTimer = adaptiveTimer - adaptiveInterval
            adaptSendRate()
        end
        
        -- 5g. Draw nickname + speed + active chat in 3D above remote vehicle
        if remoteVehicleId and debugDrawer then
            local remoteVeh = be:getObjectByID(remoteVehicleId)
            if remoteVeh and remoteVeh.getPosition then
                local vehPos = remoteVeh:getPosition()
                uiPosVec.x = vehPos.x
                uiPosVec.y = vehPos.y
                uiPosVec.z = vehPos.z + 2.0
                
                debugDrawer:drawTextAdvanced(uiPosVec, remoteNickname or "Friend", nickColor, true, true, shadowColor)
                
                uiPosVec.z = uiPosVec.z - 0.5
                local speedText = string.format("%.0f km/h", remoteLastSpeed)
                debugDrawer:drawTextAdvanced(uiPosVec, speedText, speedColor, true, true, shadowColor)
                
                -- Draw 3D Emote/Chat above car if timer is active
                if M._chatTimer and M._chatTimer > 0 then
                    M._chatTimer = M._chatTimer - dtReal
                    uiPosVec.z = uiPosVec.z + 1.5
                    debugDrawer:drawTextAdvanced(uiPosVec, string.format("[%s]: %s", remoteNickname, M._chatText), chatTextColor, true, true, chatShadowColor)
                end
            end
        end
        
        -- 5h. Periodic telemetry HUD & Tandem Scorer calculation (10 Hz)
        M._uiTelemetryTimer = (M._uiTelemetryTimer or 0) + dtReal
        if M._uiTelemetryTimer >= 0.1 then
            M._uiTelemetryTimer = 0
            local myVeh = be:getPlayerVehicle(0)
            if myVeh then
                -- Trigger Remote Telemetry HUD Update
                guihooks.trigger("lanMultiplayerRemoteTelemetry", {
                    rpm = remoteTargetRPM,
                    speed = remoteLastSpeed,
                    gear = remoteTargetGear,
                    throttle = lastRemoteInputs.t,
                    steering = lastRemoteInputs.s,
                    brake = lastRemoteInputs.b
                })
                
                -- Calculate and trigger Tandem Scorer Update
                if remoteVehicleId and hasRemoteState then
                    local pos = myVeh:getPosition()
                    local dist = pos:distance(remoteTargetPos)
                    local mySpeed = myVeh:getVelocity():length() * 3.6
                    
                    local myVel = myVeh:getVelocity()
                    local myDir = myVeh:getDirectionVector()
                    local myDriftAngle = 0
                    if myVel:length() > 2.0 then
                        local velDir = myVel:normalized()
                        local cosAngle = myDir:dot(velDir)
                        cosAngle = math.max(-1.0, math.min(1.0, cosAngle))
                        myDriftAngle = math.acos(cosAngle) * 57.29577951
                    end
                    
                    local remoteDir = remoteTargetRot * vec3(0, 1, 0)
                    local remoteDriftAngle = 0
                    if remoteTargetVel:length() > 2.0 then
                        local velDir = remoteTargetVel:normalized()
                        local cosAngle = remoteDir:dot(velDir)
                        cosAngle = math.max(-1.0, math.min(1.0, cosAngle))
                        remoteDriftAngle = math.acos(cosAngle) * 57.29577951
                    end
                    
                    local angleDiff = math.abs(myDriftAngle - remoteDriftAngle)
                    local speedDiff = math.abs(mySpeed - remoteLastSpeed)
                    
                    -- Scoring algorithm
                    if dist < 15.0 and myDriftAngle > 10.0 and remoteDriftAngle > 10.0 and mySpeed > 10.0 then
                        local proximityMult = math.max(1.0, 15.0 - dist)
                        local angleMult = math.max(0.5, (90.0 - angleDiff) / 90.0)
                        local pointsEarned = 10 * proximityMult * angleMult * 0.1 -- 10 Hz step
                        M._tandemScore = (M._tandemScore or 0) + pointsEarned
                    end
                    
                    guihooks.trigger("lanMultiplayerTandemUpdate", {
                        dist = dist,
                        speedDiff = speedDiff,
                        angleDiff = angleDiff,
                        score = M._tandemScore or 0
                    })
                end
            end
        end
        
        -- 5i. Check and sync player vehicle damage (every 1.0 second)
        if M.damageSyncEnabled then
            damageCheckTimer = damageCheckTimer + dtReal
            if damageCheckTimer >= 1.0 then
                damageCheckTimer = damageCheckTimer - 1.0
                local myVeh = be:getPlayerVehicle(0)
                if myVeh then
                    local checkCmd = [[
                    (function()
                        local dmg = beamstate and beamstate.damage or 0
                        if dmg > (lastReportedDmg or 0) then
                            lastReportedDmg = dmg
                            local deformed = {}
                            for cid, node in pairs(v.data.nodes) do
                                local pos = v.data.nodes[cid].pos
                                local currentPos = obj:getNodePosition(cid)
                                local dist = pos:distance(currentPos)
                                if dist > 0.03 then
                                    deformed[tostring(cid)] = {currentPos.x, currentPos.y, currentPos.z}
                                end
                            end
                            if next(deformed) then
                                obj:queueGameEngineLua(string.format("extensions.lanMultiplayer.reportDamage(%s)", jsonEncode(deformed)))
                            end
                        end
                    end)()
                    ]]
                    myVeh:queueLuaCommand(checkCmd)
                end
            end
        end
    end
end

-- Vehicle Spawned callback (Hook)
local function onVehicleSpawned(id)
    if not spawnPending then return end
    
    local veh = be:getObjectByID(id)
    if veh then
        local model = veh.JBeam
        if model == spawnPendingModel or not spawnPendingModel then
            remoteVehicleId = id
            spawnPending = false
            spawnPendingModel = nil
            log('I', 'lanMultiplayer', 'Successfully spawned remote vehicle with ID: ' .. tostring(id))
            
            -- Inject sync and damage helpers into vehicle Lua VM
            local initScript = [[
            globalSyncVeh = function(t, s, b, c, hb, rpm, gear, ws, lights, flags, soundSync, wheelSync, lightsSync)
                input.event('throttle', t, 1)
                input.event('steering', s, 1)
                input.event('brake', b, 1)
                input.event('clutch', c, 1)
                input.event('handbrake', hb, 1)
                if soundSync ~= 0 then
                    if mainEngine then
                        mainEngine.rpm = rpm
                        mainEngine.visualRPM = rpm
                        mainEngine.inputAV = rpm * 0.104719755
                    end
                    if gearbox then
                        gearbox.gearIndex = gear
                    end
                    electrics.values.rpm = rpm
                    electrics.values.rpmSpin = rpm
                    electrics.values.gearIndex = gear
                    electrics.values.gear = gear
                end
                if wheelSync ~= 0 then
                    electrics.values.wheelspeed = ws
                    if wheels then
                        for _, w in ipairs(wheels.wheels) do
                            w.angularVelocity = ws
                            w.angularVelocityBrakeCouple = ws
                        end
                    end
                end
                if lightsSync ~= 0 then
                    if electrics.setLightsState then
                        electrics.setLightsState(bit.band(lights, 1) ~= 0 and 1 or 0)
                        electrics.set_left_signal(bit.band(lights, 2) ~= 0)
                        electrics.set_right_signal(bit.band(lights, 4) ~= 0)
                        electrics.set_warn_signal(bit.band(lights, 8) ~= 0)
                        electrics.set_fog_lights(bit.band(lights, 16) ~= 0)
                        electrics.set_lightbar_signal(bit.band(lights, 32) ~= 0 and 1 or 0)
                        electrics.horn(bit.band(lights, 64) ~= 0)
                    end
                end
            end
            globalApplyDeformedNodes = function(nodes)
                for cidStr, pos in pairs(nodes) do
                    local cid = tonumber(cidStr)
                    if cid then
                        obj:setNodePosition(cid, vec3(pos[1], pos[2], pos[3]))
                    end
                end
            end
            ]]
            veh:queueLuaCommand(initScript)
        end
    end
end

-- Vehicle Resetted/Repaired callback (Hook)
local function onVehicleResetted(vehicleId)
    if state ~= "CONNECTED" then return end
    
    local myVeh = be:getPlayerVehicle(0)
    if myVeh and myVeh:getId() == vehicleId then
        myVeh:queueLuaCommand("lastReportedDmg = 0")
        log('I', 'lanMultiplayer', 'Player reset their vehicle. Sending reset packet.')
        sendReset()
    end
end

local originalGCPause = 200

-- Cleanup on unload
local function onExtensionUnloaded()
    collectgarbage("setpause", originalGCPause)
    log('I', 'lanMultiplayer', 'GC Pause restored to ' .. tostring(originalGCPause))
    disconnect()
end

-- Extension loaded
local function onExtensionLoaded()
    log('I', 'lanMultiplayer', 'LAN Multiplayer extension loaded.')
    originalGCPause = collectgarbage("setpause", 800)
    log('I', 'lanMultiplayer', 'GC Pause set to 800 (was ' .. tostring(originalGCPause) .. ')')
    loadSettings()
end

local function reportDamage(deformed)
    if state == "CONNECTED" then
        sendPacket({ type = "damage", nodes = deformed })
    end
end

local function setGhostMode(enabled)
    M.ghostModeEnabled = enabled
    log('I', 'lanMultiplayer', 'Ghost mode set to: ' .. tostring(enabled))
    
    -- Immediately update remote vehicle collision if it exists
    if remoteVehicleId then
        local remoteVeh = be:getObjectByID(remoteVehicleId)
        if remoteVeh then
            local bit = require("bit")
            local remoteGhost = false
            if M._lastSyncedFlags then
                remoteGhost = bit.band(M._lastSyncedFlags, 1) ~= 0
            end
            local currentGhost = remoteGhost or M.ghostModeEnabled
            if currentGhost ~= lastGhostState then
                lastGhostState = currentGhost
                remoteVeh:setField('collision', 0, currentGhost and 'false' or 'true')
                remoteVeh:setField('collisionType', 0, currentGhost and 'None' or 'Collision Mesh')
            end
        end
    end
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setSoundSync(enabled)
    M.soundSyncEnabled = enabled
    log('I', 'lanMultiplayer', 'Sound sync set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setWheelSync(enabled)
    M.wheelSyncEnabled = enabled
    log('I', 'lanMultiplayer', 'Wheel sync set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setLightsSync(enabled)
    M.lightsSyncEnabled = enabled
    log('I', 'lanMultiplayer', 'Lights sync set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setDamageSync(enabled)
    M.damageSyncEnabled = enabled
    log('I', 'lanMultiplayer', 'Damage sync set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setNetworkOpt(enabled)
    M.networkOptimizationEnabled = enabled
    log('I', 'lanMultiplayer', 'Network optimization set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setTuningSync(enabled)
    M.tuningSyncEnabled = enabled
    log('I', 'lanMultiplayer', 'Tuning sync set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setBackfireSync(enabled)
    M.backfireSyncEnabled = enabled
    log('I', 'lanMultiplayer', 'Backfire sync set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setRecoverySync(enabled)
    M.recoverySyncEnabled = enabled
    log('I', 'lanMultiplayer', 'Recovery sync set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setAdaptiveHz(enabled)
    M.adaptiveHzEnabled = enabled
    log('I', 'lanMultiplayer', 'Adaptive Hz set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setJitterBuffer(enabled)
    M.jitterBufferEnabled = enabled
    log('I', 'lanMultiplayer', 'Jitter buffer set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setInputExtrap(enabled)
    M.inputExtrapEnabled = enabled
    log('I', 'lanMultiplayer', 'Input extrapolation set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setPLC(enabled)
    M.plcEnabled = enabled
    log('I', 'lanMultiplayer', 'PLC set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setUseTimeBasedExtrap(enabled)
    M.useTimeBasedExtrap = enabled
    log('I', 'lanMultiplayer', 'Use Time-Based Extrapolation set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setHemisphereCheck(enabled)
    M.hemisphereCheckEnabled = enabled
    log('I', 'lanMultiplayer', 'Hemisphere check set to: ' .. tostring(enabled))
    saveSettings(state ~= "IDLE")
    notifyUI()
end

local function setNetEmulator(enabled)
    M.netEmulatorEnabled = enabled
    log('I', 'lanMultiplayer', 'Net emulator set to: ' .. tostring(enabled))
    notifyUI()
end

local function setNetEmulatorSettings(dropRate, jitterMaxMs)
    M.debugDropRate = tonumber(dropRate) or 0.0
    M.debugJitterMaxMs = tonumber(jitterMaxMs) or 0
    log('I', 'lanMultiplayer', string.format('Net emulator settings updated: dropRate=%.2f, jitterMaxMs=%d', M.debugDropRate, M.debugJitterMaxMs))
    notifyUI()
end

local function chatMessage(text)
    if not text or text == "" then return end
    if state == "CONNECTED" then
        sendPacket({ type = "chat", text = text, sender = myNickname })
        guihooks.trigger("lanMultiplayerChat", {
            sender = myNickname,
            text = text
        })
    end
end

local function onPartConfigChanged(vehicleId)
    local myVeh = be:getPlayerVehicle(0)
    if myVeh and myVeh:getId() == vehicleId and state == "CONNECTED" then
        if M.tuningSyncEnabled then
            local model, config = getVehicleInfo(myVeh)
            log('I', 'lanMultiplayer', 'Part config changed. Syncing paint and parts.')
            sendSpawn(model, config)
        end
    end
end

local function teleportToFriend()
    if not remoteVehicleId then
        log('W', 'lanMultiplayer', 'No remote vehicle to teleport to.')
        return
    end
    local remoteVeh = be:getObjectByID(remoteVehicleId)
    local myVeh = be:getPlayerVehicle(0)
    if remoteVeh and myVeh then
        local remotePos = remoteVeh:getPosition()
        local remoteRot = quat(remoteVeh:getRotation())
        myVeh:setPosRot(remotePos.x, remotePos.y, remotePos.z + 2.0, remoteRot.x, remoteRot.y, remoteRot.z, remoteRot.w)
        log('I', 'lanMultiplayer', 'Teleported to friend.')
    end
end

-- API Exports
M.onUpdate = onUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleResetted = onVehicleResetted
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onPartConfigChanged = onPartConfigChanged

M.host = host
M.connect = connect
M.disconnect = disconnect
M.requestStatus = notifyUI
M.setNickname = setNickname
M.setGhostMode = setGhostMode
M.setSoundSync = setSoundSync
M.setWheelSync = setWheelSync
M.setLightsSync = setLightsSync
M.setDamageSync = setDamageSync
M.setNetworkOpt = setNetworkOpt
M.setTuningSync = setTuningSync
M.setBackfireSync = setBackfireSync
M.setRecoverySync = setRecoverySync
M.setAdaptiveHz = setAdaptiveHz
M.setJitterBuffer = setJitterBuffer
M.setInputExtrap = setInputExtrap
M.setPLC = setPLC
M.setUseTimeBasedExtrap = setUseTimeBasedExtrap
M.setHemisphereCheck = setHemisphereCheck
M.setNetEmulator = setNetEmulator
M.setNetEmulatorSettings = setNetEmulatorSettings
M.teleportToFriend = teleportToFriend
M.reportDamage = reportDamage
M.chatMessage = chatMessage

-- Internal API exports for testing
M.getInputsRaw = getInputsRaw
M.getMinimizedConfig = getMinimizedConfig
M.getSafeConfigPayload = getSafeConfigPayload
M.areConfigsEqual = areConfigsEqual
M.updateRemoteVehicleBinary = updateRemoteVehicleBinary
M.updateRemoteVehicle = updateRemoteVehicle
M.applySmoothedRemoteState = applySmoothedRemoteState
M.sendUpdate = sendUpdate
M.receivePackets = receivePackets
M.resetMetrics = resetMetrics
M.processPacket = processPacket
M.adaptSendRate = adaptSendRate
M.setTargetIp = function(ip) targetIp = ip end
M.setTargetPort = function(port) targetPort = port end
M.setRole = function(r) role = r end
M.setState = function(s) state = s end
M.setSendRate = function(rate) sendRate = rate end
M.getSendRate = function() return sendRate end
M.getRemoteVehicleId = function() return remoteVehicleId end
M.setRemoteVehicleId = function(id) remoteVehicleId = id end
M.getRemoteTargetPos = function() return remoteTargetPos end
M.getRemoteTargetRot = function() return remoteTargetRot end
M.getRemoteTargetVel = function() return remoteTargetVel end
M.getRemoteTargetAngVel = function() return remoteTargetAngVel end
M.getRemoteLastSpeed = function() return remoteLastSpeed end
M.getLastRemoteInputs = function() return lastRemoteInputs end
M.getTxSeq = function() return txSeq end
M.getPacketLoss = function() return packetLoss end
M.getJitter = function() return currentJitter end
M.setPacketLoss = function(loss) packetLoss = loss end
M.setJitter = function(jitter) currentJitter = jitter end

return M

