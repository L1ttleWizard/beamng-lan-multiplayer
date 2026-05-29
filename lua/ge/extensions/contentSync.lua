-- Content and Mods Replication for BeamNG LAN Multiplayer
local M = {}

local mime = require('mime')

local function b64encode(str)
    if not str then return nil end
    local encoded = mime.b64(str)
    if encoded then
        return encoded:gsub("\n", ""):gsub("=", "")
    end
    return nil
end

local function b64decode(str)
    if not str then return nil end
    -- Pad with '=' to make length a multiple of 4
    local padded = str
    local remainder = #str % 4
    if remainder > 0 then
        padded = padded .. string.rep("=", 4 - remainder)
    end
    return mime.unb64(padded)
end

-- Shared Garage Preset (Stage 7.4)
function M.exportGaragePreset(vehId)
    local veh = be:getObjectByID(vehId)
    if not veh then return nil end
    
    local model = veh.JBeam
    local vars = {}
    local paints = {}
    
    if extensions.core_vehicle_manager then
        local data = extensions.core_vehicle_manager.getVehicleData(vehId)
        if data and data.config then
            if data.config.vars then
                for k, v in pairs(data.config.vars) do
                    vars[k] = v
                end
            end
            if data.config.paints then
                for k, v in pairs(data.config.paints) do
                    paints[k] = v
                end
            end
        end
    end
    
    -- Fallback for paints if empty
    if #paints == 0 and veh.color then
        local metallicPaintData = veh.getMetallicPaintData and veh:getMetallicPaintData() or {}
        local function createPaint(color, metal)
            if not color then return nil end
            return {
                baseColor = { color.x or color[1] or 1, color.y or color[2] or 1, color.z or color[3] or 1, color.w or color[4] or 1 },
                metallic = metal and (metal.x or metal[1]) or 0,
                roughness = metal and (metal.y or metal[2]) or 0.5,
                clearcoat = metal and (metal.z or metal[3]) or 0,
                clearcoatRoughness = metal and (metal.w or metal[4]) or 0.1
            }
        end
        paints[1] = createPaint(veh.color, metallicPaintData[1])
        paints[2] = createPaint(veh.colorPalette0, metallicPaintData[2])
        paints[3] = createPaint(veh.colorPalette1, metallicPaintData[3])
    end
    
    local preset = {
        v = 1,
        model = model,
        vars = vars,
        paints = paints,
        label = model:upper() .. " Preset"
    }
    
    local jsonStr = jsonEncode(preset)
    if not jsonStr then return nil end
    
    local b64 = b64encode(jsonStr)
    if not b64 then return nil end
    
    return "BLMP-" .. b64
end

function M.applyGaragePreset(presetCode)
    if not presetCode or not presetCode:find("^BLMP%-") then
        log('W', 'contentSync', 'Invalid preset code format: ' .. tostring(presetCode))
        return false
    end
    
    local b64 = presetCode:sub(6)
    local decoded = b64decode(b64)
    if not decoded then
        log('W', 'contentSync', 'Failed to decode base64 preset')
        return false
    end
    
    local preset = jsonDecode(decoded)
    if not preset or not preset.model then
        log('W', 'contentSync', 'Failed to parse preset JSON')
        return false
    end
    
    log('I', 'contentSync', 'Applying garage preset for model: ' .. tostring(preset.model))
    
    local config = {
        parts = {},
        vars = preset.vars or {},
        paints = preset.paints or {}
    }
    
    if core_vehicles and core_vehicles.spawnNewVehicle then
        -- Find current player vehicle to replace it
        local currentVeh = be:getPlayerVehicle(0)
        local pos = currentVeh and currentVeh:getPosition() or vec3(0,0,0)
        local rot = currentVeh and currentVeh:getRotation() or quat(0,0,0,1)
        
        if currentVeh then
            if core_vehicles.removeVehicle then
                core_vehicles.removeVehicle(currentVeh:getId())
            else
                currentVeh:delete()
            end
        end
        
        core_vehicles.spawnNewVehicle(preset.model, {
            config = config,
            pos = pos,
            rot = rot,
            autoEnterVehicle = true
        })
        return true
    end
    return false
end

-- Mods Verification (Stage 7.1)
function M.getModsFingerprint()
    local hash = "sha256:dummyhash"
    local count = 0
    local samples = {}
    
    if core_modmanager and core_modmanager.getModList then
        local list = core_modmanager.getModList()
        local modNames = {}
        for name, info in pairs(list) do
            if info.active then
                table.insert(modNames, name)
            end
        end
        table.sort(modNames)
        count = #modNames
        
        -- Create a simple fingerprint hash by concatenating sorted active mod names
        if count > 0 then
            local combined = table.concat(modNames, ",")
            -- Simple DJB2-like string hashing since we don't have built-in sha256 function easily accessible in GE Lua
            local h = 5381
            for i = 1, #combined do
                h = bit.bxor(bit.lshift(h, 5) + h, string.byte(combined, i))
            end
            hash = string.format("djb2:%x", h)
            
            -- Take up to 5 samples
            for i = 1, math.min(5, count) do
                table.insert(samples, modNames[i])
            end
        end
    end
    
    return {
        mods_hash = hash,
        mods_count = count,
        mods_sample = samples
    }
end

-- Custom Map Validation (Stage 7.2)
function M.validateMapExists(mapPath)
    if not mapPath then return false end
    
    -- Check if map folder/file exists
    if FS:directoryExists(mapPath) or FS:directoryExists("/levels/" .. mapPath) or FS:directoryExists("levels/" .. mapPath) then
        return true
    end
    
    -- Also try checking standard level files
    local levels = core_levels and core_levels.getList and core_levels.getList() or {}
    for _, lvl in ipairs(levels) do
        if lvl.levelName == mapPath or lvl.levelName == mapPath:match("([^/]+)$") then
            return true
        end
    end
    
    return false
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
