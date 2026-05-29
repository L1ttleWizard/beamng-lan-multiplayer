-- Host-authoritative AI traffic sync (Stage 4)
local M = {}

local ffi = require("ffi")
local bit = require("bit")

local TAIB_MAGIC = 0x42414954 -- "TAIB" little-endian
local TAIB_VERSION = 1
local SNAPSHOT_SIZE = 30
local HEADER_SIZE = 12
local MAX_BATCH = 15
local MTU_TARGET = 1400

local TRAFFIC_SCAN_INTERVAL = 0.5
local DESPAWN_GRACE_SEC = 0.35
local TELEPORT_PAIR_MAX_DIST = 800.0
local ROT_SMOOTH_SPEED = 12.0
local ZONE_A_DIST = 100.0
local ZONE_B_DIST = 500.0
local RATE_A = 1.0 / 60.0
local RATE_B = 0.1

local VEL_SCALE = 100.0 -- 0.01 m/s per int16 unit
local QUAT_SCALE = 32767.0

ffi.cdef[[
typedef struct {
    uint32_t net_id;
    float px, py, pz;
    int16_t qx, qy, qz, qw;
    int16_t vx, vy, vz;
} AISnapshot;

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t count;
    uint32_t seq;
} AIBatchHeader;
]]

local batchBuf = ffi.new("uint8_t[?]", MTU_TARGET)
local outHeader = ffi.new("AIBatchHeader")
local outSnapshot = ffi.new("AISnapshot")

M._aiNetToLocal = {}
M._aiGameToNet = {}
M._nextNetId = 1
M._pendingAiSpawns = {}
M._hostScanTimer = 0
M._batchSeq = 0
M._clientTrafficDeactivated = false
M._txAiBytes = 0
M._rxAiBytes = 0
M._metricsAiTimer = 0
M._txAiKBs = 0
M._rxAiKBs = 0

local function getLan()
    return extensions and extensions.lanMultiplayer
end

local function isConnected()
    local lm = getLan()
    return lm and lm.getState and lm.getState() == "CONNECTED"
end

local function isHost()
    local lm = getLan()
    return lm and lm.getRole and lm.getRole() == "HOST"
end

local function isSyncEnabled()
    local lm = getLan()
    return lm and lm.aiTrafficSyncEnabled
end

local function isPlcEnabled()
    local lm = getLan()
    if not lm then return true end
    if lm.aiTrafficPlcEnabled == false then return false end
    return lm.plcEnabled ~= false
end

local function sendReliable(payload)
    local lm = getLan()
    if lm and lm.sendPacketReliable then
        lm.sendPacketReliable(payload)
    end
end

local function sendRaw(raw)
    local lm = getLan()
    if lm and lm.sendRaw then
        M._txAiBytes = M._txAiBytes + #raw
        lm.sendRaw(raw)
    end
end

local function trackRxAiBytes(n)
    M._rxAiBytes = M._rxAiBytes + (n or 0)
end

local function dist3(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function nlerpQuat(qx, qy, qz, qw, tx, ty, tz, tw, t)
    local dot = qx * tx + qy * ty + qz * tz + qw * tw
    if dot < 0 then
        tx, ty, tz, tw = -tx, -ty, -tz, -tw
    end
    local rx = qx + (tx - qx) * t
    local ry = qy + (ty - qy) * t
    local rz = qz + (tz - qz) * t
    local rw = qw + (tw - qw) * t
    local len = math.sqrt(rx * rx + ry * ry + rz * rz + rw * rw)
    if len < 1e-6 then
        return tx, ty, tz, tw
    end
    return rx / len, ry / len, rz / len, rw / len
end

local function applyKinematicsToEntry(entry, px, py, pz, qx, qy, qz, qw, vx, vy, vz, snapRot)
    entry.lastPx, entry.lastPy, entry.lastPz = px, py, pz
    if snapRot then
        entry.lastQx, entry.lastQy, entry.lastQz, entry.lastQw = qx, qy, qz, qw
        entry.smoothQx, entry.smoothQy, entry.smoothQz, entry.smoothQw = qx, qy, qz, qw
    else
        entry.lastQx, entry.lastQy, entry.lastQz, entry.lastQw = qx, qy, qz, qw
    end
    entry.lastVx, entry.lastVy, entry.lastVz = vx or 0, vy or 0, vz or 0
    entry.lastPacketTime = os.clock()
    entry.pendingDespawn = nil
end

local function getVehicleModelConfig(veh)
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

local function vec3FromTable(t)
    if not t then return 0, 0, 0 end
    return t.x or 0, t.y or 0, t.z or 0
end

local function quatFromTable(t)
    if not t then return 0, 0, 0, 1 end
    return t.x or 0, t.y or 0, t.z or 0, t.w or 1
end

local function tableFromPos(pos)
    if not pos then return { x = 0, y = 0, z = 0 } end
    if type(pos) == "table" then
        return { x = pos.x or 0, y = pos.y or 0, z = pos.z or 0 }
    end
    return { x = pos.x, y = pos.y, z = pos.z }
end

local function tableFromQuat(q)
    if not q then return { x = 0, y = 0, z = 0, w = 1 } end
    if type(q) == "table" then
        return { x = q.x or 0, y = q.y or 0, z = q.z or 0, w = q.w or 1 }
    end
    return { x = q.x, y = q.y, z = q.z, w = q.w }
end

-- Smallest-three quaternion compression (for tests + network)
function M.compressQuat(qx, qy, qz, qw)
    local ax, ay, az, aw = math.abs(qx), math.abs(qy), math.abs(qz), math.abs(qw)
    local largest = 0
    local maxv = ax
    if ay > maxv then largest, maxv = 1, ay end
    if az > maxv then largest, maxv = 2, az end
    if aw > maxv then largest, maxv = 3, aw end

    local sign = 1
    if largest == 0 and qx < 0 then sign = -1
    elseif largest == 1 and qy < 0 then sign = -1
    elseif largest == 2 and qz < 0 then sign = -1
    elseif largest == 3 and qw < 0 then sign = -1
    end

    local comps = { qx, qy, qz, qw }
    local vals = {}
    local vi = 1
    for i = 1, 4 do
        if i - 1 ~= largest then
            vals[vi] = comps[i] * sign
            vi = vi + 1
        end
    end

    return largest,
        math.floor(vals[1] * QUAT_SCALE + 0.5),
        math.floor(vals[2] * QUAT_SCALE + 0.5),
        math.floor(vals[3] * QUAT_SCALE + 0.5)
end

function M.decompressQuat(largest, c0, c1, c2)
    local v0 = c0 / QUAT_SCALE
    local v1 = c1 / QUAT_SCALE
    local v2 = c2 / QUAT_SCALE
    local sum = v0 * v0 + v1 * v1 + v2 * v2
    local missing = math.sqrt(math.max(0, 1.0 - sum))

    local out = { 0, 0, 0, 0 }
    local vi = 1
    for i = 0, 3 do
        if i == largest then
            out[i + 1] = missing
        else
            out[i + 1] = ({ v0, v1, v2 })[vi]
            vi = vi + 1
        end
    end
    return out[1], out[2], out[3], out[4]
end

local function compressQuat(qx, qy, qz, qw)
    return M.compressQuat(qx, qy, qz, qw)
end

local function decompressQuat(largest, c0, c1, c2)
    return M.decompressQuat(largest, c0, c1, c2)
end

local function encodeSnapshot(ptr, netId, px, py, pz, qx, qy, qz, qw, vx, vy, vz)
    ptr.net_id = netId
    ptr.px = px
    ptr.py = py
    ptr.pz = pz
    local li, c0, c1, c2 = compressQuat(qx, qy, qz, qw)
    ptr.qx = li
    ptr.qy = c0
    ptr.qz = c1
    ptr.qw = c2
    ptr.vx = math.max(-32768, math.min(32767, math.floor(vx * VEL_SCALE + 0.5)))
    ptr.vy = math.max(-32768, math.min(32767, math.floor(vy * VEL_SCALE + 0.5)))
    ptr.vz = math.max(-32768, math.min(32767, math.floor(vz * VEL_SCALE + 0.5)))
end

local function decodeSnapshot(ptr)
    local qx, qy, qz, qw = decompressQuat(ptr.qx, ptr.qy, ptr.qz, ptr.qw)
    return ptr.net_id,
        ptr.px, ptr.py, ptr.pz,
        qx, qy, qz, qw,
        ptr.vx / VEL_SCALE, ptr.vy / VEL_SCALE, ptr.vz / VEL_SCALE
end

function M.getSnapshotSize()
    return SNAPSHOT_SIZE
end

function M.getLodZone(dist)
    if dist <= ZONE_A_DIST then return "A" end
    if dist <= ZONE_B_DIST then return "B" end
    return "C"
end

function M.getLodSendInterval(zone)
    if zone == "A" then return RATE_A end
    if zone == "B" then return RATE_B end
    return nil
end

local function deleteLocalPuppet(netId)
    local entry = M._aiNetToLocal[netId]
    if not entry then return end
    local localId = entry.localId
    if localId then
        if core_vehicles and core_vehicles.removeVehicle then
            core_vehicles.removeVehicle(localId)
        elseif core_vehicles and core_vehicles.deleteVehicle then
            core_vehicles.deleteVehicle(localId)
        else
            local veh = be:getObjectByID(localId)
            if veh then veh:delete() end
        end
    end
    M._aiNetToLocal[netId] = nil
end

local function deactivateClientTraffic()
    if M._clientTrafficDeactivated then return end
    if extensions.gameplay_traffic and extensions.gameplay_traffic.deactivate then
        extensions.gameplay_traffic.deactivate(true)
        M._clientTrafficDeactivated = true
        log('I', 'aiTrafficSync', 'Deactivated local gameplay_traffic on client.')
    end
end

local function allocateNetId()
    local id = M._nextNetId
    M._nextNetId = M._nextNetId + 1
    return id
end

local function getPeerReferencePos()
    local lm = getLan()
    if isHost() and lm and lm.getRemoteTargetPos then
        local p = lm.getRemoteTargetPos()
        if p and (p.x or p.y or p.z) then
            return p.x or 0, p.y or 0, p.z or 0
        end
    end
    local veh = be:getPlayerVehicle(0)
    if veh and veh.getPosition then
        local pos = veh:getPosition()
        return pos.x, pos.y, pos.z
    end
    return 0, 0, 0
end

local function readVehicleKinematics(gameId)
    local veh = be:getObjectByID(gameId)
    if not veh then return nil end
    local pos = veh.getPosition and veh:getPosition()
    if not pos then return nil end
    local rotRaw = veh.getRotation and veh:getRotation()
    local qx, qy, qz, qw = 0, 0, 0, 1
    if rotRaw then
        if type(rotRaw) == "table" then
            qx, qy, qz, qw = rotRaw.x or 0, rotRaw.y or 0, rotRaw.z or 0, rotRaw.w or 1
        else
            qx, qy, qz, qw = rotRaw.x, rotRaw.y, rotRaw.z, rotRaw.w
        end
    end
    local vx, vy, vz = 0, 0, 0
    if veh.getVelocity then
        local vel = veh:getVelocity()
        if vel then vx, vy, vz = vel.x, vel.y, vel.z end
    end
    return pos.x, pos.y, pos.z, qx, qy, qz, qw, vx, vy, vz
end

local function updateHostLastKnown(netId, gameId)
    local entry = M._aiNetToLocal[netId]
    if not entry or not gameId then return end
    local px, py, pz = readVehicleKinematics(gameId)
    if px then
        entry.lastPx, entry.lastPy, entry.lastPz = px, py, pz
    end
end

local function spawnAiPuppet(model, config, pos, rot, netId)
    local lm = getLan()
    local safeConfig = config
    if lm and lm.getSafeConfigPayload then
        safeConfig = lm.getSafeConfigPayload(config)
    end

    M._pendingAiSpawns[netId] = {
        model = model,
        time = os.clock(),
    }

    local p = vec3(0, 0, 0)
    if pos then
        if type(pos) == "table" then
            p = vec3(pos.x or 0, pos.y or 0, pos.z or 0)
        else
            p = pos
        end
    end
    local r = quat(0, 0, 0, 1)
    if rot then
        if type(rot) == "table" then
            r = quat(rot.x or 0, rot.y or 0, rot.z or 0, rot.w or 1)
        else
            r = rot
        end
    end

    local originalVeh = be:getPlayerVehicle(0)
    core_vehicles.spawnNewVehicle(model, {
        config = safeConfig,
        pos = p,
        rot = r,
        autoEnterVehicle = false,
    })
    if originalVeh then
        be:enterVehicle(0, originalVeh)
    end
end

local function hostBroadcastSpawn(gameId, veh)
    local model, config = getVehicleModelConfig(veh)
    if not model then return end
    local netId = allocateNetId()
    M._aiGameToNet[gameId] = netId
    local pos = veh.getPosition and veh:getPosition()
    M._aiNetToLocal[netId] = {
        gameId = gameId,
        model = model,
        sendTimer = 0,
        lodZone = "A",
        lastPx = pos and pos.x or 0,
        lastPy = pos and pos.y or 0,
        lastPz = pos and pos.z or 0,
    }

    local rotRaw = veh.getRotation and veh:getRotation()
    local lm = getLan()
    local safeConfig = config
    if lm and lm.getSafeConfigPayload then
        safeConfig = lm.getSafeConfigPayload(config)
    end

    sendReliable({
        type = "ai_spawn",
        net_id = netId,
        model = model,
        config = safeConfig,
        pos = tableFromPos(pos),
        rot = tableFromQuat(rotRaw),
    })
    log('I', 'aiTrafficSync', string.format('Host registered AI netId=%d gameId=%d model=%s', netId, gameId, model))
end

local function hostBroadcastDespawn(netId)
    sendReliable({ type = "ai_despawn", net_id = netId })
    local entry = M._aiNetToLocal[netId]
    if entry and entry.gameId then
        M._aiGameToNet[entry.gameId] = nil
    end
    M._aiNetToLocal[netId] = nil
end

local function hostBroadcastTeleport(netId, gameId)
    local px, py, pz, qx, qy, qz, qw, vx, vy, vz = readVehicleKinematics(gameId)
    if not px then return end

    local entry = M._aiNetToLocal[netId]
    if entry then
        entry.gameId = gameId
        applyKinematicsToEntry(entry, px, py, pz, qx, qy, qz, qw, vx, vy, vz, true)
    end

    sendReliable({
        type = "ai_teleport",
        net_id = netId,
        pos = { x = px, y = py, z = pz },
        rot = { x = qx, y = qy, z = qz, w = qw },
        vel = { x = vx, y = vy, z = vz },
    })
    log('I', 'aiTrafficSync', string.format('Host teleported AI netId=%d -> gameId=%d', netId, gameId))
end

local function hostScanTraffic(dt)
    if not extensions.gameplay_traffic or not extensions.gameplay_traffic.getTrafficList then
        return
    end
    M._hostScanTimer = M._hostScanTimer + dt
    if M._hostScanTimer < TRAFFIC_SCAN_INTERVAL then
        return
    end
    M._hostScanTimer = 0

    local now = os.clock()
    local current = {}
    local newUnmapped = {}
    local list = extensions.gameplay_traffic.getTrafficList()
    if list then
        for _, gameId in ipairs(list) do
            current[gameId] = true
            if not M._aiGameToNet[gameId] then
                table.insert(newUnmapped, gameId)
            else
                local netId = M._aiGameToNet[gameId]
                updateHostLastKnown(netId, gameId)
                local entry = M._aiNetToLocal[netId]
                if entry then
                    entry.pendingDespawn = nil
                end
            end
        end
    end

    local removed = {}
    for gameId, netId in pairs(M._aiGameToNet) do
        if not current[gameId] then
            table.insert(removed, { gameId = gameId, netId = netId })
        end
    end

    local usedNew = {}
    for _, rem in ipairs(removed) do
        local entry = M._aiNetToLocal[rem.netId]
        local remModel = entry and entry.model
        local refPx = entry and entry.lastPx or 0
        local refPy = entry and entry.lastPy or 0
        local refPz = entry and entry.lastPz or 0

        local bestIdx, bestDist
        for idx, newGameId in ipairs(newUnmapped) do
            if not usedNew[idx] then
                local veh = be:getObjectByID(newGameId)
                if veh and remModel and veh.JBeam == remModel then
                    local px, py, pz = readVehicleKinematics(newGameId)
                    if px then
                        local d = dist3(refPx, refPy, refPz, px, py, pz)
                        if d <= TELEPORT_PAIR_MAX_DIST and (not bestDist or d < bestDist) then
                            bestIdx, bestDist = idx, d
                        end
                    end
                end
            end
        end

        if bestIdx then
            local newGameId = newUnmapped[bestIdx]
            usedNew[bestIdx] = true
            M._aiGameToNet[rem.gameId] = nil
            M._aiGameToNet[newGameId] = rem.netId
            hostBroadcastTeleport(rem.netId, newGameId)
        else
            if not entry then
                M._aiGameToNet[rem.gameId] = nil
            elseif not entry.pendingDespawn then
                entry.pendingDespawn = now
            elseif (now - entry.pendingDespawn) >= DESPAWN_GRACE_SEC then
                hostBroadcastDespawn(rem.netId)
                log('I', 'aiTrafficSync', 'Host despawned AI netId=' .. tostring(rem.netId))
            end
        end
    end

    for idx, newGameId in ipairs(newUnmapped) do
        if not usedNew[idx] then
            local veh = be:getObjectByID(newGameId)
            if veh then
                hostBroadcastSpawn(newGameId, veh)
            end
        end
    end
end

function M.syncRosterToClient()
    if not isHost() or not isSyncEnabled() then
        return
    end
    if not extensions.gameplay_traffic or not extensions.gameplay_traffic.getTrafficList then
        return
    end

    hostScanTraffic(TRAFFIC_SCAN_INTERVAL)

    local count = 0
    for netId, entry in pairs(M._aiNetToLocal) do
        local gameId = entry.gameId
        local veh = gameId and be:getObjectByID(gameId)
        if veh then
            local model, config = getVehicleModelConfig(veh)
            local pos = veh.getPosition and veh:getPosition()
            local rotRaw = veh.getRotation and veh:getRotation()
            local lm = getLan()
            local safeConfig = config
            if lm and lm.getSafeConfigPayload then
                safeConfig = lm.getSafeConfigPayload(config)
            end
            sendReliable({
                type = "ai_spawn",
                net_id = netId,
                model = model,
                config = safeConfig,
                pos = tableFromPos(pos),
                rot = tableFromQuat(rotRaw),
            })
            count = count + 1
        end
    end
    log('I', 'aiTrafficSync', 'Synced AI roster to client: ' .. tostring(count) .. ' vehicles')
end

function M.buildBatchPacket(snapshots)
    if not snapshots or #snapshots == 0 then
        return nil, 0
    end
    local batchCount = math.min(MAX_BATCH, #snapshots)
    local packetSize = HEADER_SIZE + batchCount * SNAPSHOT_SIZE
    outHeader.magic = TAIB_MAGIC
    outHeader.version = TAIB_VERSION
    outHeader.count = batchCount
    M._batchSeq = M._batchSeq + 1
    outHeader.seq = M._batchSeq
    ffi.copy(batchBuf, outHeader, HEADER_SIZE)
    local offset = HEADER_SIZE
    for i = 1, batchCount do
        local s = snapshots[i]
        encodeSnapshot(outSnapshot, s.netId, s.px, s.py, s.pz, s.qx, s.qy, s.qz, s.qw, s.vx, s.vy, s.vz)
        ffi.copy(batchBuf + offset, outSnapshot, SNAPSHOT_SIZE)
        offset = offset + SNAPSHOT_SIZE
    end
    return ffi.string(batchBuf, packetSize), packetSize
end

function M.decodeBatchPacket(rawMsg)
    local results = {}
    if #rawMsg < HEADER_SIZE then return results end
    local m1, m2, m3, m4 = string.byte(rawMsg, 1, 4)
    if m1 ~= 84 or m2 ~= 65 or m3 ~= 73 or m4 ~= 66 then
        return results
    end
    local count = string.byte(rawMsg, 7) + string.byte(rawMsg, 8) * 256
    if count <= 0 or count > MAX_BATCH then return results end
    local expected = HEADER_SIZE + count * SNAPSHOT_SIZE
    if #rawMsg < expected then return results end
    local offset = HEADER_SIZE
    for _ = 1, count do
        ffi.copy(outSnapshot, rawMsg:sub(offset + 1, offset + SNAPSHOT_SIZE), SNAPSHOT_SIZE)
        offset = offset + SNAPSHOT_SIZE
        local netId, px, py, pz, qx, qy, qz, qw, vx, vy, vz = decodeSnapshot(outSnapshot)
        table.insert(results, {
            netId = netId,
            px = px, py = py, pz = pz,
            qx = qx, qy = qy, qz = qz, qw = qw,
            vx = vx, vy = vy, vz = vz,
        })
    end
    return results
end

function M.applyBatchRaw(rawMsg)
    if not isSyncEnabled() or not isConnected() then
        return false
    end
    if #rawMsg < HEADER_SIZE then return false end

    local m1, m2, m3, m4 = string.byte(rawMsg, 1, 4)
    if m1 ~= 84 or m2 ~= 65 or m3 ~= 73 or m4 ~= 66 then
        return false
    end

    trackRxAiBytes(#rawMsg)

    local count = string.byte(rawMsg, 7) + string.byte(rawMsg, 8) * 256
    if count <= 0 or count > MAX_BATCH then return true end

    local expected = HEADER_SIZE + count * SNAPSHOT_SIZE
    if #rawMsg < expected then return true end

    local offset = HEADER_SIZE
    for i = 1, count do
        ffi.copy(outSnapshot, rawMsg:sub(offset + 1, offset + SNAPSHOT_SIZE), SNAPSHOT_SIZE)
        offset = offset + SNAPSHOT_SIZE

        local netId, px, py, pz, qx, qy, qz, qw, vx, vy, vz = decodeSnapshot(outSnapshot)
        local entry = M._aiNetToLocal[netId]
        if entry and entry.localId then
            applyKinematicsToEntry(entry, px, py, pz, qx, qy, qz, qw, vx, vy, vz, false)
        end
    end
    return true
end

local function hostSendBatch(dt)
    local refX, refY, refZ = getPeerReferencePos()
    local toSend = {}

    for netId, entry in pairs(M._aiNetToLocal) do
        local gameId = entry.gameId
        if gameId and be:getObjectByID(gameId) then
            local px, py, pz, qx, qy, qz, qw, vx, vy, vz = readVehicleKinematics(gameId)
            local dx, dy, dz = px - refX, py - refY, pz - refZ
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            local zone = M.getLodZone(dist)
            entry.lodZone = zone
            local interval = M.getLodSendInterval(zone)
            if interval then
                entry.sendTimer = (entry.sendTimer or 0) + dt
                if entry.sendTimer >= interval then
                    entry.sendTimer = entry.sendTimer - interval
                    applyKinematicsToEntry(entry, px, py, pz, qx, qy, qz, qw, vx, vy, vz, false)
                    table.insert(toSend, {
                        netId = netId,
                        px = px, py = py, pz = pz,
                        qx = qx, qy = qy, qz = qz, qw = qw,
                        vx = vx, vy = vy, vz = vz,
                    })
                end
            end
        end
    end

    if #toSend == 0 then return end

    local idx = 1
    while idx <= #toSend do
        local batchCount = math.min(MAX_BATCH, #toSend - idx + 1)
        local batchSlice = {}
        for j = 0, batchCount - 1 do
            table.insert(batchSlice, toSend[idx + j])
        end
        local packet, packetSize = M.buildBatchPacket(batchSlice)
        if packet then
            sendRaw(packet)
        end
        idx = idx + batchCount
    end
end

local function applyClientTeleport(msg)
    local netId = msg.net_id
    if not netId then return end
    local entry = M._aiNetToLocal[netId]
    if not entry then return end

    local px, py, pz = vec3FromTable(msg.pos)
    local qx, qy, qz, qw = quatFromTable(msg.rot)
    local vx, vy, vz = 0, 0, 0
    if msg.vel then
        vx, vy, vz = vec3FromTable(msg.vel)
    end
    applyKinematicsToEntry(entry, px, py, pz, qx, qy, qz, qw, vx, vy, vz, true)

    if entry.localId then
        local veh = be:getObjectByID(entry.localId)
        if veh and veh.setPosRot then
            veh:setPosRot(px, py, pz, qx, qy, qz, qw)
        end
        if veh and veh.setVelocity then
            veh:setVelocity(vec3(vx, vy, vz))
        end
    end
end

local function applyClientPuppetTransforms(dt)
    if isHost() then return end
    local plc = isPlcEnabled()
    for netId, entry in pairs(M._aiNetToLocal) do
        if entry.localId and entry.lastPx then
            local veh = be:getObjectByID(entry.localId)
            if veh then
                local px, py, pz = entry.lastPx, entry.lastPy, entry.lastPz
                local vx = entry.lastVx or 0
                local vy = entry.lastVy or 0
                local vz = entry.lastVz or 0
                if plc and entry.lastPacketTime then
                    local elapsed = os.clock() - entry.lastPacketTime
                    px = px + vx * elapsed
                    py = py + vy * elapsed
                    pz = pz + vz * elapsed
                end
                local tqx = entry.lastQx or 0
                local tqy = entry.lastQy or 0
                local tqz = entry.lastQz or 0
                local tqw = entry.lastQw or 1
                local sqx = entry.smoothQx or tqx
                local sqy = entry.smoothQy or tqy
                local sqz = entry.smoothQz or tqz
                local sqw = entry.smoothQw or tqw
                local rotT = math.min(1, ROT_SMOOTH_SPEED * dt)
                local qx, qy, qz, qw = nlerpQuat(sqx, sqy, sqz, sqw, tqx, tqy, tqz, tqw, rotT)
                entry.smoothQx, entry.smoothQy, entry.smoothQz, entry.smoothQw = qx, qy, qz, qw
                if veh.setPosRot then
                    veh:setPosRot(px, py, pz, qx, qy, qz, qw)
                end
            end
        end
    end
end

function M.processPacket(msg)
    if not isSyncEnabled() or not isConnected() then
        return false
    end
    if type(msg) ~= "table" then return false end

    local msgType = msg.type
    if msgType == "ai_spawn" then
        if isHost() then return true end
        deactivateClientTraffic()
        local netId = msg.net_id
        if not netId then return true end
        if M._aiNetToLocal[netId] then
            deleteLocalPuppet(netId)
        end
        M._aiNetToLocal[netId] = {
            localId = nil,
            model = msg.model,
            sendTimer = 0,
        }
        spawnAiPuppet(msg.model, msg.config, msg.pos, msg.rot, netId)
        return true
    elseif msgType == "ai_despawn" then
        if isHost() then return true end
        local netId = msg.net_id
        if netId then
            deleteLocalPuppet(netId)
            M._pendingAiSpawns[netId] = nil
        end
        return true
    elseif msgType == "ai_teleport" then
        if isHost() then return true end
        deactivateClientTraffic()
        applyClientTeleport(msg)
        return true
    end
    return false
end

function M.onVehicleSpawned(id)
    local veh = be:getObjectByID(id)
    if not veh then return false end
    local model = veh.JBeam

    for netId, pending in pairs(M._pendingAiSpawns) do
        if pending.model == model and pending.time and (os.clock() - pending.time) < 8.0 then
            M._pendingAiSpawns[netId] = nil
            local entry = M._aiNetToLocal[netId] or {}
            entry.localId = id
            entry.model = model
            M._aiNetToLocal[netId] = entry

            veh:queueLuaCommand('ai.setMode("stop")')
            if veh.setField then
                veh:setField('collision', 0, 'false')
            end
            log('I', 'aiTrafficSync', string.format('AI puppet ready netId=%d localId=%d', netId, id))
            return true
        end
    end
    return false
end

function M.onVehicleDestroyed(id)
    for netId, entry in pairs(M._aiNetToLocal) do
        if entry.localId == id then
            entry.localId = nil
            log('I', 'aiTrafficSync', 'AI puppet destroyed netId=' .. tostring(netId))
            return true
        end
    end
    return false
end

function M.onUpdate(dtReal)
    if not isConnected() or not isSyncEnabled() then
        return
    end

    M._metricsAiTimer = M._metricsAiTimer + dtReal
    if M._metricsAiTimer >= 1.0 then
        M._txAiKBs = M._txAiBytes / 1024
        M._rxAiKBs = M._rxAiBytes / 1024
        M._txAiBytes = 0
        M._rxAiBytes = 0
        M._metricsAiTimer = 0
    end

    if isHost() then
        hostScanTraffic(dtReal)
        hostSendBatch(dtReal)
    else
        deactivateClientTraffic()
        applyClientPuppetTransforms(dtReal)
    end
end

function M.getMetrics()
    return {
        activeAiPuppets = M.getActivePuppetCount(),
        txAiKBs = math.floor((M._txAiKBs or 0) * 10 + 0.5) / 10,
        rxAiKBs = math.floor((M._rxAiKBs or 0) * 10 + 0.5) / 10,
    }
end

function M.reset()
    for netId, _ in pairs(M._aiNetToLocal) do
        if not isHost() then
            deleteLocalPuppet(netId)
        end
    end
    M._aiNetToLocal = {}
    M._aiGameToNet = {}
    M._pendingAiSpawns = {}
    M._hostScanTimer = 0
    M._batchSeq = 0
    M._clientTrafficDeactivated = false
    M._txAiBytes = 0
    M._rxAiBytes = 0
    M._metricsAiTimer = 0
    M._txAiKBs = 0
    M._rxAiKBs = 0
end

function M.getActivePuppetCount()
    local n = 0
    for _, entry in pairs(M._aiNetToLocal) do
        if entry.localId or entry.gameId then
            n = n + 1
        end
    end
    return n
end

return M
