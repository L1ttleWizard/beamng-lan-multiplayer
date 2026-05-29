-- Special Vehicle Systems Sync for BeamNG LAN Multiplayer (Trailers/Couplers)
local M = {}

function M.onTrailerAttached(vehId, trailerId)
    if not extensions.lanMultiplayer or extensions.lanMultiplayer.getState() ~= "CONNECTED" then return end
    
    -- Check if we own this vehicle
    local myVeh = be:getPlayerVehicle(0)
    if myVeh and myVeh:getId() == vehId then
        log('I', 'vehicleSync', string.format('Local trailer attached: vehicle %d to trailer %d. Syncing to peer.', vehId, trailerId))
        extensions.lanMultiplayer.sendPacketReliable({
            type = "trailer_attach",
            vehicle_id = vehId,
            trailer_id = trailerId
        })
    end
end

function M.onTrailerDetached(vehId, trailerId)
    if not extensions.lanMultiplayer or extensions.lanMultiplayer.getState() ~= "CONNECTED" then return end
    
    -- Check if we own this vehicle
    local myVeh = be:getPlayerVehicle(0)
    if myVeh and myVeh:getId() == vehId then
        log('I', 'vehicleSync', string.format('Local trailer detached: vehicle %d from trailer %d. Syncing to peer.', vehId, trailerId))
        extensions.lanMultiplayer.sendPacketReliable({
            type = "trailer_detach",
            vehicle_id = vehId,
            trailer_id = trailerId
        })
    end
end

function M.handlePacket(msg)
    if not extensions.lanMultiplayer then return false end
    local peerToLocal = extensions.lanMultiplayer._peerToLocalVehicles or {}
    
    if msg.type == "trailer_attach" then
        local localVehId = peerToLocal[msg.vehicle_id]
        local localTrailerId = peerToLocal[msg.trailer_id]
        
        if localVehId then
            log('I', 'vehicleSync', string.format('Remote trailer attach: peer vehicle %s (local %s) to peer trailer %s (local %s)', 
                tostring(msg.vehicle_id), tostring(localVehId), tostring(msg.trailer_id), tostring(localTrailerId)))
                
            local veh = be:getObjectByID(localVehId)
            if veh then
                veh:queueLuaCommand("if beamstate and beamstate.attachCouplers then beamstate.attachCouplers() end")
            end
        end
        return true
    elseif msg.type == "trailer_detach" then
        local localVehId = peerToLocal[msg.vehicle_id]
        
        if localVehId then
            log('I', 'vehicleSync', string.format('Remote trailer detach: peer vehicle %s (local %s)', 
                tostring(msg.vehicle_id), tostring(localVehId)))
                
            local veh = be:getObjectByID(localVehId)
            if veh then
                veh:queueLuaCommand("if beamstate and beamstate.detachCouplers then beamstate.detachCouplers() end")
            end
        end
        return true
    end
    
    return false
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
