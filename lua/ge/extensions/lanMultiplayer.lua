-- LAN Multiplayer Mod for BeamNG.drive
-- Author: Antigravity (Google DeepMind Advanced Agentic Coding)

local M = {}

-- Libraries
local socket = require("socket")
local ffi = require("ffi")

-- Register FFI structure for zero-allocation binary updates
ffi.cdef[[
typedef struct {
    uint32_t magic;   // 0x42555044
    uint32_t seq;
    float px, py, pz;
    float rx, ry, rz, rw;
    float vx, vy, vz;
    float ax, ay, az;
    float throttle;
    float steering;
    float brake;
    float clutch;
    float handbrake;
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
local connectTimer = 0
local lastPacketTime = 0
local timeoutLimit = 5.0 -- 5 seconds timeout
local spawnPending = false
local spawnPendingModel = nil

-- Settings path
local settingsFile = "settings/lanMultiplayer.json"

-- Input filtering state
local lastRemoteInputs = nil

-- ============================================================
-- Remote Vehicle State
-- ============================================================
-- Remote target state (updated by packets, applied with smoothing each frame)
local remoteTargetPos = nil
local remoteTargetRot = nil
local remoteTargetVel = nil
local remoteTargetAngVel = nil
local remoteLastSpeed = 0       -- km/h for display

-- Interpolation settings
local smoothSpeed = 30          -- exponential convergence rate
local smoothThreshold = 0.02    -- meters: below this, just snap directly

-- Pre-allocated objects to avoid garbage collection pressure
local smoothedPos = vec3(0,0,0)
local smoothedRot = quat(0,0,0,1)
local nickColor = ColorF(0.22, 0.74, 1.0, 1.0)
local speedColor = ColorF(0.85, 0.85, 0.85, 0.75)

-- (Lerp/NLerp removed — no longer used; direct setPosRot at network rate)

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
    if guihooks and state == "CONNECTED" then
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
            pingMax = math.ceil(maxPing)
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
    remoteTargetPos = nil
    remoteTargetRot = nil
    remoteTargetVel = nil
    remoteTargetAngVel = nil
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
    adaptiveTimer = 0
    sendRate = minSendRate
    currentHz = math.floor(1 / minSendRate + 0.5)
    lastRemoteInputs = nil
    remoteTargetPos = nil
    remoteTargetRot = nil
    remoteTargetVel = nil
    remoteTargetAngVel = nil
    remoteLastSpeed = 0
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
        
        -- Debug logging for non-hot-path packets (ignore positions 'u' and pings/pongs)
        if rawData:sub(2, 9) ~= '"t":"u"' and rawData:sub(2, 9) ~= '"t":"ping' and rawData:sub(2, 9) ~= '"t":"pong' then
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
    
    txSeq = txSeq + 1
    
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
    
    -- Send directly as raw binary string (80 bytes)
    sendRaw(ffi.string(outPacket, 80))
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
    if not adaptiveEnabled then return end
    
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
    
    -- Parse target state into BeamNG math types (allocated only when packet is accepted)
    remoteTargetPos = vec3(data.px, data.py, data.pz)
    remoteTargetRot = quat(data.rx, data.ry, data.rz, data.rw)
    remoteTargetVel = vec3(data.vx, data.vy, data.vz)
    remoteTargetAngVel = vec3(data.ax, data.ay, data.az)
    
    -- Calculate speed for 3D drawing
    remoteLastSpeed = math.sqrt(data.vx*data.vx + data.vy*data.vy + data.vz*data.vz) * 3.6
    
    -- Apply control inputs to remote vehicle VM
    local t = data.throttle
    local s = data.steering
    local b = data.brake
    local c = data.clutch
    local hb = data.handbrake
    
    if not lastRemoteInputs or
       math.abs(t - lastRemoteInputs.t) > 0.001 or
       math.abs(s - lastRemoteInputs.s) > 0.001 or
       math.abs(b - lastRemoteInputs.b) > 0.001 or
       math.abs(c - lastRemoteInputs.c) > 0.001 or
       math.abs(hb - lastRemoteInputs.hb) > 0.001 then
        
        lastRemoteInputs = { t = t, s = s, b = b, c = c, hb = hb }
        
        local cmd = string.format(
            "input.event('throttle', %f, 1); input.event('steering', %f, 1); input.event('brake', %f, 1); input.event('clutch', %f, 1); input.event('handbrake', %f, 1);",
            t, s, b, c, hb
        )
        local remoteVeh = be:getObjectByID(remoteVehicleId)
        if remoteVeh then
            remoteVeh:queueLuaCommand(cmd)
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
    
    -- Store target state for smoothed application in onUpdate
    remoteTargetPos = p
    remoteTargetRot = r
    remoteTargetVel = v
    remoteTargetAngVel = av
    
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
        
        if not lastRemoteInputs or
           math.abs(t - lastRemoteInputs.t) > 0.001 or
           math.abs(s - lastRemoteInputs.s) > 0.001 or
           math.abs(b - lastRemoteInputs.b) > 0.001 or
           math.abs(c - lastRemoteInputs.c) > 0.001 or
           math.abs(hb - lastRemoteInputs.hb) > 0.001 then
            
            lastRemoteInputs = { t = t, s = s, b = b, c = c, hb = hb }
            
            local cmd = string.format(
                "input.event('throttle', %f, 1); input.event('steering', %f, 1); input.event('brake', %f, 1); input.event('clutch', %f, 1); input.event('handbrake', %f, 1);",
                t, s, b, c, hb
            )
            local remoteVeh = be:getObjectByID(remoteVehicleId)
            if remoteVeh then
                remoteVeh:queueLuaCommand(cmd)
            end
        end
    end
end

-- Apply smoothed remote vehicle state every frame using pre-allocated objects
local function applySmoothedRemoteState(dtReal)
    if not remoteVehicleId or not remoteTargetPos or not remoteTargetRot then return end
    
    local remoteVeh = be:getObjectByID(remoteVehicleId)
    if not remoteVeh then return end
    
    local currentPos = remoteVeh.getPosition and vec3(remoteVeh:getPosition())
    local currentRot = remoteVeh.getRotation and quat(remoteVeh:getRotation())
    if not currentPos or not currentRot then return end
    
    -- Calculate distance to target
    local dx = remoteTargetPos.x - currentPos.x
    local dy = remoteTargetPos.y - currentPos.y
    local dz = remoteTargetPos.z - currentPos.z
    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
    
    if dist < smoothThreshold then
        -- Very close: snap directly (no visible difference)
        remoteVeh:setPosRot(remoteTargetPos.x, remoteTargetPos.y, remoteTargetPos.z, remoteTargetRot.x, remoteTargetRot.y, remoteTargetRot.z, remoteTargetRot.w)
    else
        -- Smooth exponential convergence (frame-rate independent)
        local alpha = 1.0 - math.exp(-smoothSpeed * dtReal)
        
        -- In-place modification of pre-allocated vec3 to avoid allocations
        smoothedPos.x = currentPos.x + alpha * (remoteTargetPos.x - currentPos.x)
        smoothedPos.y = currentPos.y + alpha * (remoteTargetPos.y - currentPos.y)
        smoothedPos.z = currentPos.z + alpha * (remoteTargetPos.z - currentPos.z)
        
        -- In-place modification of pre-allocated quat (NLerp)
        local dot = currentRot.x*remoteTargetRot.x + currentRot.y*remoteTargetRot.y + currentRot.z*remoteTargetRot.z + currentRot.w*remoteTargetRot.w
        local s = 1
        if dot < 0 then s = -1 end
        local rx = currentRot.x + alpha * (s*remoteTargetRot.x - currentRot.x)
        local ry = currentRot.y + alpha * (s*remoteTargetRot.y - currentRot.y)
        local rz = currentRot.z + alpha * (s*remoteTargetRot.z - currentRot.z)
        local rw = currentRot.w + alpha * (s*remoteTargetRot.w - currentRot.w)
        local len = math.sqrt(rx*rx + ry*ry + rz*rz + rw*rw)
        if len > 0.0001 then
            rx, ry, rz, rw = rx/len, ry/len, rz/len, rw/len
        end
        
        smoothedRot.x = rx
        smoothedRot.y = ry
        smoothedRot.z = rz
        smoothedRot.w = rw
        
        remoteVeh:setPosRot(smoothedPos.x, smoothedPos.y, smoothedPos.z, smoothedRot.x, smoothedRot.y, smoothedRot.z, smoothedRot.w)
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
    -- Track RX counters
    rxPackets = rxPackets + 1
    rxBytes = rxBytes + #rawMsg
    
    -- Check if it's a binary BUPD update packet (exact length 80, matching magic number)
    if #rawMsg == 80 and rawMsg:sub(1, 4) == "DPUB" then
        lastPacketTime = os.clock()
        ffi.copy(inPacket, rawMsg, 80)
        updateRemoteVehicleBinary(inPacket)
        return
    end
    
    -- Debug logging for incoming JSON packets (ignore pings/pongs)
    if rawMsg:sub(2, 9) ~= '"t":"ping' and rawMsg:sub(2, 9) ~= '"t":"pong' then
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
            if msg.model and (msg.model ~= remoteVehicleModel or not areConfigsEqual(msg.config, remoteVehicleConfig) or not remoteVehicleId) then
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
        end
    end
end

-- Read socket inputs and drop duplicate/old updates to avoid buffer bloat and ping spikes
local function receivePackets()
    if not udpSocket then return end
    
    local latestUpdateMsg = nil
    local latestUpdateSeq = -1
    local latestUpdateIp = nil
    local latestUpdatePort = nil
    
    if role == "CLIENT" then
        while true do
            local data, err = udpSocket:receive()
            if not data then
                break
            end
            
            local isUpdate = false
            local seq = 0
            
            -- 1. Check for binary update packet
            if #data == 80 and data:sub(1, 4) == "DPUB" then
                isUpdate = true
                local b1, b2, b3, b4 = string.byte(data, 5, 8)
                seq = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
            end
            
            -- 2. Fallback to check for JSON update packet
            if not isUpdate then
                isUpdate = data:sub(1, 7) == '{"t":"u"' or data:sub(1, 10) == '{"type":"u"'
                if isUpdate then
                    local seqStr = data:match('"s":(%d+)')
                    seq = seqStr and tonumber(seqStr) or 0
                end
            end
            
            if isUpdate then
                if seq > latestUpdateSeq then
                    latestUpdateSeq = seq
                    latestUpdateMsg = data
                end
            else
                processPacket(data, targetIp, targetPort)
            end
        end
    else
        while true do
            local data, ip, port = udpSocket:receivefrom()
            if not data then
                break
            end
            
            local isUpdate = false
            local seq = 0
            
            -- 1. Check for binary update packet
            if #data == 80 and data:sub(1, 4) == "DPUB" then
                isUpdate = true
                local b1, b2, b3, b4 = string.byte(data, 5, 8)
                seq = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
            end
            
            -- 2. Fallback to check for JSON update packet
            if not isUpdate then
                isUpdate = data:sub(1, 7) == '{"t":"u"' or data:sub(1, 10) == '{"type":"u"'
                if isUpdate then
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

-- Main Game Loop update hook
local function onUpdate(dtReal, dtSim)
    if state == "IDLE" then return end
    
    -- Wrap entire body in pcall to prevent error cascade from tanking FPS
    local ok, err = pcall(function()
        -- 1. Receive packets
        receivePackets()
        
        -- 2. Handle handshake if connecting
        handleConnectingHandshake(dtReal)
        
        -- 3. Check for timeouts
        checkTimeout()
        
        -- 4. Connected state logic
        if state == "CONNECTED" then
            -- 4a. Send update packets at adaptive Hz (capped to frame rate)
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
                            myVehicleId = myId
                            lastMyVehicleModel = model
                            lastMyVehicleConfig = config
                            log('I', 'lanMultiplayer', 'Vehicle change detected. Sending spawn packet.')
                            sendSpawn(model, config)
                        end
                    end
                    
                    sendUpdate()
                end
            end
            
            -- 4b. Apply remote vehicle state (throttled to network rate inside the function)
            applySmoothedRemoteState(dtReal)
            
            -- 4c. Periodic ping
            pingTimer = pingTimer + dtReal
            if pingTimer >= pingInterval then
                pingTimer = pingTimer - pingInterval
                sendPing()
            end
            
            -- 4d. Per-second metrics window
            metricsTimer = metricsTimer + dtReal
            if metricsTimer >= metricsInterval then
                metricsTimer = metricsTimer - metricsInterval
                updateMetricsWindow()
            end
            
            -- 4e. Adaptive send rate re-evaluation
            adaptiveTimer = adaptiveTimer + dtReal
            if adaptiveTimer >= adaptiveInterval then
                adaptiveTimer = adaptiveTimer - adaptiveInterval
                adaptSendRate()
            end
            
            -- 4f. Draw nickname + speed above remote vehicle (pre-allocated colors, reuse pos cdata)
            if remoteVehicleId and debugDrawer then
                local remoteVeh = be:getObjectByID(remoteVehicleId)
                if remoteVeh and remoteVeh.getPosition then
                    local pos = remoteVeh:getPosition()
                    -- Modify the returned cdata in-place (it's a copy, safe to mutate)
                    pos.z = pos.z + 2.0
                    debugDrawer:drawTextAdvanced(pos, remoteNickname or "Friend", nickColor, true, true, ColorI(0, 0, 0, 128))
                    pos.z = pos.z - 0.5
                    local speedText = string.format("%.0f km/h", remoteLastSpeed)
                    debugDrawer:drawTextAdvanced(pos, speedText, speedColor, true, true, ColorI(0, 0, 0, 128))
                end
            end
        end
    end)
    
    if not ok then
        -- Log once per second to avoid spam
        if not M._lastErrTime or os.clock() - M._lastErrTime > 1.0 then
            M._lastErrTime = os.clock()
            log('E', 'lanMultiplayer', 'onUpdate error: ' .. tostring(err))
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
        end
    end
end

-- Vehicle Resetted/Repaired callback (Hook)
local function onVehicleResetted(vehicleId)
    if state ~= "CONNECTED" then return end
    
    local myVeh = be:getPlayerVehicle(0)
    if myVeh and myVeh:getId() == vehicleId then
        log('I', 'lanMultiplayer', 'Player reset their vehicle. Sending reset packet.')
        sendReset()
    end
end

-- Cleanup on unload
local function onExtensionUnloaded()
    disconnect()
end

-- Extension loaded
local function onExtensionLoaded()
    log('I', 'lanMultiplayer', 'LAN Multiplayer extension loaded.')
    loadSettings()
end

-- API Exports
M.onUpdate = onUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleResetted = onVehicleResetted
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.host = host
M.connect = connect
M.disconnect = disconnect
M.requestStatus = notifyUI
M.setNickname = setNickname

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

