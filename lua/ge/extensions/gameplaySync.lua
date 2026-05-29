-- Gameplay synchronization: tire wear/thermals + checkpoint triggers
local M = {}

local WHEEL_SYNC_INTERVAL = 0.5
local wheelSyncTimer = 0
local lastWheelPayloadKey = nil

M._checkpointEvents = {}
M._lapSessionStart = nil

local function getLan()
    return extensions and extensions.lanMultiplayer
end

local function isConnected()
    local lm = getLan()
    return lm and lm.getState and lm.getState() == "CONNECTED"
end

local function sendReliable(payload)
    local lm = getLan()
    if lm and lm.sendPacketReliable then
        lm.sendPacketReliable(payload)
    end
end

local function getPlayerVehicleId()
    if not be or not be.getPlayerVehicle then
        return nil
    end
    local veh = be:getPlayerVehicle(0)
    if veh and veh.getId then
        return veh:getId()
    end
    return nil
end

local function buildWheelPayloadKey(wheels)
    if not wheels then
        return ""
    end
    local parts = {}
    for name, st in pairs(wheels) do
        table.insert(parts, string.format(
            "%s:%d:%.1f:%.1f",
            name,
            st.deflated or 0,
            st.brakeSurface or 0,
            st.pressure or 0
        ))
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

function M.reportWheelState(wheels)
    if not isConnected() then
        return
    end

    local lm = getLan()
    if not lm or not lm.tireWearSyncEnabled then
        return
    end

    if type(wheels) ~= "table" then
        return
    end

    local key = buildWheelPayloadKey(wheels)
    if key == lastWheelPayloadKey then
        return
    end
    lastWheelPayloadKey = key

    sendReliable({
        type = "wheel_state",
        wheels = wheels,
        nickname = lm.getNickname and lm.getNickname() or "Player"
    })
end

local function serializeWheelTableToLua(tbl)
    local parts = { "{" }
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            local inner = { "{" }
            for ik, iv in pairs(v) do
                if type(ik) == "number" then
                    table.insert(inner, string.format("[%s]=%s,", tostring(ik), tostring(iv)))
                else
                    table.insert(inner, string.format("[%q]=%s,", tostring(ik), tostring(iv)))
                end
            end
            table.insert(inner, "}")
            table.insert(parts, string.format("[%q]=%s,", tostring(k), table.concat(inner)))
        else
            table.insert(parts, string.format("[%q]=%s,", tostring(k), tostring(v)))
        end
    end
    table.insert(parts, "}" )
    return table.concat(parts)
end

local function applyWheelState(msg)
    local lm = getLan()
    if not lm or not lm.tireWearSyncEnabled then
        return
    end

    if not msg.wheels then
        return
    end

    local remoteId = lm.getRemoteVehicleId and lm.getRemoteVehicleId()
    if not remoteId then
        return
    end

    local remoteVeh = be:getObjectByID(remoteId)
    if not remoteVeh then
        return
    end

    local luaPayload = serializeWheelTableToLua(msg.wheels)
    remoteVeh:queueLuaCommand(string.format(
        "if globalApplyWheelState then globalApplyWheelState(%s) end",
        luaPayload
    ))
end

local function pushCheckpointUi(event)
    local lm = getLan()
    if not lm or not lm.checkpointsUiEnabled then
        return
    end

    table.insert(M._checkpointEvents, 1, event)
    while #M._checkpointEvents > 8 do
        table.remove(M._checkpointEvents)
    end

    if guihooks then
        guihooks.trigger("lanMultiplayerCheckpoint", {
            events = M._checkpointEvents,
            latest = event
        })
    end
end

local function handleLocalCheckpoint(data)
    if data.event ~= "enter" then
        return
    end

    local myId = getPlayerVehicleId()
    if not myId or data.subjectID ~= myId then
        return
    end

    if not M._lapSessionStart then
        M._lapSessionStart = os.clock()
    end

    local elapsed = os.clock() - M._lapSessionStart
    local lm = getLan()

    local event = {
        trigger = data.triggerName or "checkpoint",
        nickname = lm and lm.getNickname and lm.getNickname() or "Player",
        elapsed = elapsed,
        wallTime = os.clock()
    }

    pushCheckpointUi(event)

    sendReliable({
        type = "checkpoint",
        trigger = event.trigger,
        event = "enter",
        elapsed = elapsed,
        nickname = event.nickname
    })
end

local function handleRemoteCheckpoint(msg)
    local event = {
        trigger = msg.trigger or "checkpoint",
        nickname = msg.nickname or "Friend",
        elapsed = msg.elapsed or 0,
        wallTime = os.clock(),
        remote = true
    }
    pushCheckpointUi(event)
end

function M.processPacket(msg)
    if not msg or not msg.type then
        return false
    end

    if msg.type == "wheel_state" then
        applyWheelState(msg)
        return true
    elseif msg.type == "checkpoint" then
        handleRemoteCheckpoint(msg)
        return true
    end

    return false
end

function M.onBeamNGTrigger(data)
    if not isConnected() then
        return
    end

    local lm = getLan()
    if not lm then
        return
    end

    if not data or not data.event then
        return
    end

    handleLocalCheckpoint(data)
end

function M.onUpdate(dtReal)
    if not isConnected() then
        wheelSyncTimer = 0
        return
    end

    local lm = getLan()
    if not lm or not lm.tireWearSyncEnabled then
        return
    end

    wheelSyncTimer = wheelSyncTimer + dtReal
    if wheelSyncTimer < WHEEL_SYNC_INTERVAL then
        return
    end
    wheelSyncTimer = wheelSyncTimer - WHEEL_SYNC_INTERVAL

    local myVeh = be:getPlayerVehicle(0)
    if not myVeh then
        return
    end

    myVeh:queueLuaCommand([[
(function()
  if not wheels or not wheels.wheels then return end
  local out = {}
  for idx, wd in ipairs(wheels.wheels) do
    local pressure = 0
    if wd.pressureGroup and v and v.data and v.data.pressureGroups and v.data.pressureGroups[wd.pressureGroup] then
      pressure = obj:getGroupPressure(v.data.pressureGroups[wd.pressureGroup])
    end
    out[wd.name] = {
      deflated = wd.isTireDeflated and 1 or 0,
      brakeSurface = wd.brakeSurfaceTemperature or 0,
      brakeCore = wd.brakeCoreTemperature or 0,
      thermalEff = wd.brakeThermalEfficiency or 1,
      pressure = pressure,
      idx = idx - 1
    }
  end
  local parts = {"{"}
  for name, st in pairs(out) do
    table.insert(parts, string.format("[%q]={deflated=%d,brakeSurface=%f,brakeCore=%f,thermalEff=%f,pressure=%f,idx=%d},",
      name, st.deflated, st.brakeSurface, st.brakeCore, st.thermalEff, st.pressure, st.idx))
  end
  table.insert(parts, "}")
  obj:queueGameEngineLua("extensions.gameplaySync.reportWheelState(" .. table.concat(parts) .. ")")
end)()
    ]])
end

function M.reset()
    wheelSyncTimer = 0
    lastWheelPayloadKey = nil
    M._checkpointEvents = {}
    M._lapSessionStart = nil
end

return M
