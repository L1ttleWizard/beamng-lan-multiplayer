-- Mocks for BeamNG Globals in Unit Tests
local ffi = require("ffi")
ffi.cdef[[
typedef unsigned char uint8_t;
]]

-- Mock ColorF class constructor
function ColorF(r, g, b, a)
    return { r = r or 1, g = g or 1, b = b or 1, a = a or 1 }
end

-- Mock ColorI class constructor
function ColorI(r, g, b, a)
    return { r = r or 255, g = g or 255, b = b or 255, a = a or 255 }
end

-- Mock Point3F class constructor
function Point3F(x, y, z)
    if type(x) == "table" or type(x) == "cdata" then
        return { x = x.x or 0, y = x.y or 0, z = x.z or 0 }
    end
    return { x = x or 0, y = y or 0, z = z or 0 }
end

-- 1. Logging Mock
function log(level, area, msg)
    if level == "E" then
        print(string.format("\27[31m[%s][%s] %s\27[0m", level, area, msg))
    end
end

-- 2. GUI Hooks Mock
guihooks = {
    triggered = {},
    trigger = function(event, data)
        guihooks.triggered[event] = data
    end,
    reset = function()
        guihooks.triggered = {}
    end
}

-- 3. File System JSON Mock
local mockSettingsStore = {}
function jsonWriteFile(path, data, pretty)
    mockSettingsStore[path] = jsonEncode(data)
    return true
end

function jsonReadFile(path)
    if mockSettingsStore[path] then
        return jsonDecode(mockSettingsStore[path])
    end
    return nil
end

function getMockSettingsStore()
    return mockSettingsStore
end

-- 4. Level & Mission Mock
function getMissionFilename()
    return "levels/east_coast_usa/info.json"
end

core_levels = {
    loadedLevel = nil,
    startLevel = function(path)
        core_levels.loadedLevel = path
    end,
    reset = function()
        core_levels.loadedLevel = nil
    end
}

-- 5. Debug Drawer Mock
debugDrawer = {
    drawnTexts = {},
    drawText3D = function(self, pos, text, color)
        table.insert(debugDrawer.drawnTexts, { pos = vec3(pos), text = text, color = color })
    end,
    drawTextAdvanced = function(self, pos, text, color, drawBackground, centerText, backgroundColor)
        table.insert(debugDrawer.drawnTexts, { pos = vec3(pos), text = text, color = color, bg = backgroundColor })
    end,
    reset = function()
        debugDrawer.drawnTexts = {}
    end
}

-- 6. Player Control Inputs Mock
input = {
    state = {
        throttle = { val = 0.8 },
        steering = { val = -0.25 },
        brake = { val = 0.0 },
        clutch = { val = 0.0 },
        handbrake = { val = 0.0 }
    }
}

-- 7. Game Engine Physics & Vehicles Mock
be = {
    playerVehicle = nil,
    objects = {},
    getPlayerVehicle = function(self, id)
        return be.playerVehicle
    end,
    getObjectByID = function(self, id)
        return be.objects[id]
    end,
    enterVehicle = function(self, id, veh)
        -- mock transition
    end,
    reset = function()
        be.playerVehicle = nil
        be.objects = {}
    end
}

core_vehicles = {
    spawned = {},
    spawnNewVehicle = function(model, options)
        table.insert(core_vehicles.spawned, { model = model, options = options })
        -- Trigger spawn event callback
        local mockId = 9999
        local newVeh = createMockVehicle(mockId, model, options.config)
        newVeh.position = options.pos or vec3(0,0,0)
        newVeh.rotation = options.rot or quat(0,0,0,1)
        if M and M.onVehicleSpawned then
            M.onVehicleSpawned(mockId)
        end
    end,
    deleteVehicle = function(id)
        be.objects[id] = nil
    end,
    reset = function()
        core_vehicles.spawned = {}
    end
}

-- Mock vehicle generator
function createMockVehicle(id, model, config)
    local v = {
        _id = id,
        JBeam = model,
        partConfig = config,
        position = vec3(0, 0, 0),
        rotation = quat(0, 0, 0, 1),
        velocity = vec3(0, 0, 0),
        angularVelocity = vec3(0, 0, 0),
        
        getId = function(self) return self._id end,
        getPosition = function(self) return self.position end,
        getRotation = function(self) return self.rotation end,
        getVelocity = function(self) return self.velocity end,
        getAngularVelocity = function(self) return self.angularVelocity end,
        getDirectionVector = function(self)
            return self.rotation * vec3(0, 1, 0)
        end,
        getDirectionVectorUp = function(self)
            return self.rotation * vec3(0, 0, 1)
        end,
        
        setPositionNoPhysicsReset = function(self, pos)
            self.position = vec3(pos)
        end,
        setPosRot = function(self, x, y, z, rx, ry, rz, rw)
            if type(x) == "table" or type(x) == "cdata" then
                self.position = vec3(x)
                self.rotation = quat(y)
            else
                self.position = vec3(x or 0, y or 0, z or 0)
                self.rotation = quat(rx or 0, ry or 0, rz or 0, rw or 1)
            end
        end,
        setVelocity = function(self, vel)
            self.velocity = vec3(vel)
        end,
        setAngularVelocity = function(self, angVel)
            self.angularVelocity = vec3(angVel)
        end,
        
        queuedCommands = {},
        queueLuaCommand = function(self, cmd)
            table.insert(self.queuedCommands, cmd)
        end
    }
    be.objects[id] = v
    return v
end

-- 8. Mock UDP Socket
mockSocket = {}
function mockSocket.create()
    local s = {
        _boundIp = nil,
        _boundPort = nil,
        _peerIp = nil,
        _peerPort = nil,
        _timeout = nil,
        _sent = {},
        _recvQueue = {},
        
        settimeout = function(self, t)
            self._timeout = t
        end,
        setsockname = function(self, ip, port)
            self._boundIp = ip
            self._boundPort = port == 0 and 55555 or port
            return true
        end,
        getsockname = function(self)
            return self._boundIp, self._boundPort
        end,
        setpeername = function(self, ip, port)
            self._peerIp = ip
            self._peerPort = port
            return true, nil
        end,
        send = function(self, data)
            table.insert(self._sent, { data = data, ip = self._peerIp, port = self._peerPort })
            return #data
        end,
        sendto = function(self, data, ip, port)
            table.insert(self._sent, { data = data, ip = ip, port = port })
            return #data
        end,
        receive = function(self)
            if #self._recvQueue > 0 then
                local item = table.remove(self._recvQueue, 1)
                return item.data, nil
            end
            return nil, "timeout"
        end,
        receivefrom = function(self)
            if #self._recvQueue > 0 then
                local item = table.remove(self._recvQueue, 1)
                return item.data, item.ip, item.port
            end
            return nil, "timeout"
        end,
        close = function(self)
            -- closed
        end,
        
        -- Helper for test validation
        queuePacket = function(self, data, ip, port)
            table.insert(self._recvQueue, { data = data, ip = ip or "127.0.0.1", port = port or 27015 })
        end,
        clearSent = function(self)
            self._sent = {}
        end
    }
    return s
end

-- Override socket require
local lastCreatedSocket = nil
local mockSocketLib = {
    udp = function()
        lastCreatedSocket = mockSocket.create()
        return lastCreatedSocket
    end,
    gettime = function()
        return os.clock()
    end,
    getLastSocket = function()
        return lastCreatedSocket
    end
}
package.loaded["socket"] = mockSocketLib
package.preload["socket"] = function()
    return mockSocketLib
end

-- Mock ffi.cast since it is disabled in BeamNG console sandbox
local originalCast = ffi.cast
ffi.cast = function(ct, init)
    local ctStr = tostring(ct)
    if ctStr:find("char%*") or ctStr:find("char %*") then
        return {
            _isCharPointer = true,
            _data = init
        }
    elseif ctStr:find("uint32") or ctStr:find("uint32 %*") then
        local str = type(init) == "table" and init._data or init
        if type(str) ~= "string" then
            local ok, res = pcall(originalCast, ct, init)
            if ok then return res end
            error("ffi.cast failed in mock: " .. tostring(res))
        end
        return setmetatable({}, {
            __index = function(tbl, idx)
                local startByte = idx * 4 + 1
                if startByte + 3 > #str then return 0 end
                local b1 = string.byte(str, startByte) or 0
                local b2 = string.byte(str, startByte + 1) or 0
                local b3 = string.byte(str, startByte + 2) or 0
                local b4 = string.byte(str, startByte + 3) or 0
                return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
            end
        })
    else
        local ok, res = pcall(originalCast, ct, init)
        if ok then return res end
        error("ffi.cast failed in mock for type '" .. tostring(ct) .. "': " .. tostring(res))
    end
end

-- 9. core_vehicleBridge Mock
core_vehicleBridge = {
    cachedData = {},
    registerValueChangeNotification = function(veh, key)
        -- mock registration
    end,
    getCachedVehicleData = function(vehId, key)
        if core_vehicleBridge.cachedData[vehId] then
            return core_vehicleBridge.cachedData[vehId][key]
        end
        return nil
    end,
    reset = function()
        core_vehicleBridge.cachedData = {}
    end
}


