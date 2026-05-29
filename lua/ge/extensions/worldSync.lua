-- World synchronization submodule for LAN Multiplayer (time/weather + dynamic props)
local M = {}

local ENV_INTERVAL = 5.0
local PROPS_INTERVAL = 0.125 -- ~8 Hz
local PROP_SCAN_INTERVAL = 2.0
local MAX_PROPS_PER_PACKET = 24
local PROP_RADIUS_M = 200.0
local PROP_MOVE_THRESH_SQR = 0.0004 -- 2 cm

local envTimer = 0
local propsTimer = 0
local propScanTimer = 0
local knownProps = {} -- [id] = last known transform
local lastSentProps = {} -- [id] = last broadcast transform
local clientPropCache = {}

local function getLan()
    return extensions and extensions.lanMultiplayer
end

local function isHost()
    local lm = getLan()
    return lm and lm.getRole and lm.getRole() == "HOST"
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

local function sendUnreliable(payload)
    local lm = getLan()
    if lm and lm.sendPacket then
        lm.sendPacket(payload)
    end
end

local function getEnvironmentApi()
    if extensions and extensions.core_environment then
        return extensions.core_environment
    end
    return core_environment
end

local function collectHostEnvironment()
    local env = getEnvironmentApi()
    if not env or not env.getTimeOfDay then
        return nil
    end

    local tod = env.getTimeOfDay()
    local fogDensity = 0
    if env.getFogDensity then
        fogDensity = env.getFogDensity() * 1000
    end

    local windSpeed = 0
    if env.getWindSpeed then
        windSpeed = env.getWindSpeed()
    end

    return {
        type = "world_env",
        time = tod and tod.time or 0,
        play = tod and tod.play or false,
        fogDensity = fogDensity,
        windSpeed = windSpeed
    }
end

local function applyEnvironment(msg)
    local lm = getLan()
    if not lm or not lm.worldWeatherSyncEnabled then
        return
    end

    local env = getEnvironmentApi()
    if not env then
        return
    end

    if msg.time ~= nil and env.getTimeOfDay and env.setTimeOfDay then
        local tod = env.getTimeOfDay() or {}
        tod.time = msg.time
        if msg.play ~= nil then
            tod.play = msg.play
        else
            tod.play = false
        end
        env.setTimeOfDay(tod)
    end

    if msg.fogDensity ~= nil and env.setFogDensity then
        env.setFogDensity(msg.fogDensity / 1000)
    end

    if msg.windSpeed ~= nil and env.setWindSpeed then
        env.setWindSpeed(msg.windSpeed)
    end
end

local function getPlayerPosition()
    if not be or not be.getPlayerVehicle then
        return nil
    end
    local veh = be:getPlayerVehicle(0)
    if veh and veh.getPosition then
        return veh:getPosition()
    end
    return nil
end

local function readPropTransform(obj)
    local pos = obj:getPosition()
    if not pos then
        return nil
    end

    local rot = obj:getRotation()
    if not rot then
        rot = { x = 0, y = 0, z = 0, w = 1 }
    end

    return {
        x = pos.x,
        y = pos.y,
        z = pos.z,
        rx = rot.x,
        ry = rot.y,
        rz = rot.z,
        rw = rot.w
    }
end

local function scanDynamicProps()
    if not scenetree or not scenetree.findClassObjects then
        return
    end

    local seen = {}
    local playerPos = getPlayerPosition()
    local classes = { "TSStatic", "SimObject" }

    for _, className in ipairs(classes) do
        local names = scenetree.findClassObjects(className)
        if names then
            for _, name in ipairs(names) do
                local obj = scenetree.findObject(name)
                if obj and obj.getID and obj.getPosition then
                    local id = obj:getID()
                    if id and id > 0 then
                        local class = obj.getClassName and obj:getClassName() or ""
                        if class ~= "BeamNGVehicle" and class ~= "Camera" then
                            local transform = readPropTransform(obj)
                            if transform then
                                if not playerPos or vec3(transform.x, transform.y, transform.z):squaredDistance(playerPos) <= (PROP_RADIUS_M * PROP_RADIUS_M) then
                                    knownProps[id] = transform
                                    seen[id] = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    for id, _ in pairs(knownProps) do
        if not seen[id] then
            knownProps[id] = nil
            lastSentProps[id] = nil
        end
    end
end

local function buildPropsPayload()
    local props = {}
    local count = 0

    for id, p in pairs(knownProps) do
        local prev = lastSentProps[id]
        local dx = prev and (p.x - prev.x) or 1
        local dy = prev and (p.y - prev.y) or 1
        local dz = prev and (p.z - prev.z) or 1
        if not prev or (dx * dx + dy * dy + dz * dz) >= PROP_MOVE_THRESH_SQR then
            count = count + 1
            if count > MAX_PROPS_PER_PACKET then
                break
            end
            table.insert(props, {
                id = id,
                x = p.x,
                y = p.y,
                z = p.z,
                rx = p.rx,
                ry = p.ry,
                rz = p.rz,
                rw = p.rw
            })
            lastSentProps[id] = {
                x = p.x,
                y = p.y,
                z = p.z,
                rx = p.rx,
                ry = p.ry,
                rz = p.rz,
                rw = p.rw
            }
        end
    end

    if #props == 0 then
        return nil
    end

    return {
        type = "world_props",
        props = props
    }
end

local function applyProps(msg)
    local lm = getLan()
    if not lm or not lm.worldPropsSyncEnabled then
        return
    end

    if not msg.props then
        return
    end

    for _, p in ipairs(msg.props) do
        if p.id then
            local obj = scenetree.findObjectById(p.id)
            if not obj and getObjectByID then
                obj = getObjectByID(p.id)
            end

            if obj and obj.setPosRot then
                obj:setPosRot(p.x, p.y, p.z, p.rx, p.ry, p.rz, p.rw)
                clientPropCache[p.id] = p
            end
        end
    end
end

function M.processPacket(msg)
    if not msg or not msg.type then
        return false
    end

    if msg.type == "world_env" then
        applyEnvironment(msg)
        return true
    elseif msg.type == "world_props" then
        applyProps(msg)
        return true
    end

    return false
end

function M.onUpdate(dtReal)
    if not isConnected() or not isHost() then
        envTimer = 0
        propsTimer = 0
        propScanTimer = 0
        return
    end

    local lm = getLan()
    if not lm then
        return
    end

    if lm.worldWeatherSyncEnabled then
        envTimer = envTimer + dtReal
        if envTimer >= ENV_INTERVAL then
            envTimer = envTimer - ENV_INTERVAL
            local payload = collectHostEnvironment()
            if payload then
                sendReliable(payload)
            end
        end
    end

    if lm.worldPropsSyncEnabled then
        propScanTimer = propScanTimer + dtReal
        if propScanTimer >= PROP_SCAN_INTERVAL then
            propScanTimer = 0
            scanDynamicProps()
        end

        propsTimer = propsTimer + dtReal
        if propsTimer >= PROPS_INTERVAL then
            propsTimer = propsTimer - PROPS_INTERVAL
            local payload = buildPropsPayload()
            if payload then
                sendUnreliable(payload)
            end
        end
    end
end

function M.reset()
    envTimer = 0
    propsTimer = 0
    propScanTimer = 0
    knownProps = {}
    lastSentProps = {}
    clientPropCache = {}
end

return M
