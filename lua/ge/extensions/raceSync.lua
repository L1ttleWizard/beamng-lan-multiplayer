-- Racing & Gameplay Synchronization for BeamNG LAN Multiplayer
local M = {}

local isCountdownActive = false
local countdownTime = 0
local lockThrottle = false
local raceStartTime = 0

local convoyLeaderId = nil
local convoyLeaderPos = nil

local environmentVotes = {
    timeOfDay = {},
    weather = {}
}

local lapLeaderboard = {}

function M.startCountdown(seconds)
    seconds = seconds or 3
    raceStartTime = os.clock() + seconds
    isCountdownActive = true
    lockThrottle = true
    countdownTime = seconds
    
    log('I', 'raceSync', 'Starting race countdown: ' .. tostring(seconds) .. ' seconds')
    
    if extensions.lanMultiplayer then
        extensions.lanMultiplayer.sendPacketReliable({
            type = "race_start",
            seconds = seconds,
            startTime = raceStartTime
        })
    end
    
    if guihooks then
        guihooks.trigger("lanMultiplayerRaceCountdown", { active = true, seconds = seconds })
    end
end

function M.isThrottleLocked()
    return lockThrottle
end

function M.setConvoyLeader(playerId, pos)
    convoyLeaderId = playerId
    convoyLeaderPos = pos
    if extensions.lanMultiplayer then
        extensions.lanMultiplayer.sendPacketReliable({
            type = "convoy_leader",
            leader_id = playerId,
            pos = pos and { x = pos.x, y = pos.y, z = pos.z } or nil
        })
    end
end

function M.submitEnvironmentVote(voteType, value)
    if extensions.lanMultiplayer then
        extensions.lanMultiplayer.sendPacketReliable({
            type = "vote",
            vote_type = voteType,
            value = value
        })
    end
end

function M.handlePacket(msg)
    if msg.type == "race_start" then
        raceStartTime = msg.startTime or (os.clock() + (msg.seconds or 3))
        countdownTime = msg.seconds or 3
        isCountdownActive = true
        lockThrottle = true
        log('I', 'raceSync', 'Received race countdown start from peer: ' .. tostring(countdownTime) .. ' seconds')
        if guihooks then
            guihooks.trigger("lanMultiplayerRaceCountdown", { active = true, seconds = countdownTime })
        end
        return true
        
    elseif msg.type == "race_result" then
        -- Update leaderboard
        local player = msg.sender or "Peer"
        lapLeaderboard[player] = {
            lap = msg.lap,
            time = msg.time,
            checkpoint = msg.checkpoint
        }
        if guihooks then
            guihooks.trigger("lanMultiplayerLeaderboard", lapLeaderboard)
        end
        return true
        
    elseif msg.type == "convoy_leader" then
        convoyLeaderId = msg.leader_id
        if msg.pos then
            convoyLeaderPos = vec3(msg.pos.x, msg.pos.y, msg.pos.z)
        else
            convoyLeaderPos = nil
        end
        log('I', 'raceSync', 'Convoy leader updated: ' .. tostring(convoyLeaderId))
        return true
        
    elseif msg.type == "vote" then
        if msg.vote_type == "time" then
            environmentVotes.timeOfDay[msg.sender or "Peer"] = msg.value
        elseif msg.vote_type == "weather" then
            environmentVotes.weather[msg.sender or "Peer"] = msg.value
        end
        
        -- In LAN 1x1, count votes
        -- If we have agreement (or if host decides), apply it
        local myVoteTime = environmentVotes.timeOfDay["Player"] or environmentVotes.timeOfDay[extensions.lanMultiplayer.getNickname()]
        local peerVoteTime = environmentVotes.timeOfDay[extensions.lanMultiplayer.remoteNickname or "Friend"]
        
        if myVoteTime and peerVoteTime and myVoteTime == peerVoteTime then
            log('I', 'raceSync', 'Majority vote for time of day: ' .. tostring(myVoteTime))
            if core_environment then
                core_environment.setTimeOfDay(tonumber(myVoteTime))
            end
        end
        return true
    end
    
    return false
end

function M.onUpdate(dtReal)
    if isCountdownActive then
        local now = os.clock()
        local remaining = raceStartTime - now
        
        if remaining > 0 then
            countdownTime = math.ceil(remaining)
            lockThrottle = true
            
            -- Lock player throttle inputs locally
            local myVeh = be:getPlayerVehicle(0)
            if myVeh then
                myVeh:queueLuaCommand("if input and input.event then input.event('throttle', 0) end")
                myVeh:queueLuaCommand("if input and input.state and input.state.throttle then input.state.throttle.val = 0 end")
            end
            
            if guihooks then
                guihooks.trigger("lanMultiplayerRaceCountdown", { active = true, seconds = countdownTime })
            end
        else
            -- Go!
            isCountdownActive = false
            lockThrottle = false
            log('I', 'raceSync', 'Countdown finished! GO!')
            if guihooks then
                guihooks.trigger("lanMultiplayerRaceCountdown", { active = true, seconds = 0 })
            end
            
            -- Reset after 2 seconds from UI
            local timer = 0
            M.onUpdate = function(dt)
                timer = timer + dt
                if timer >= 2.0 then
                    if guihooks then
                        guihooks.trigger("lanMultiplayerRaceCountdown", { active = false })
                    end
                    -- Restore normal update function
                    M.onUpdate = M._originalOnUpdate
                end
                
                -- Still run leader drawing if active
                if convoyLeaderPos and debugDrawer then
                    debugDrawer:drawText3D(convoyLeaderPos + vec3(0,0,3.0), "👑 CONVOY LEADER", ColorF(1, 0.84, 0, 1))
                end
            end
        end
    end
    
    -- Draw convoy leader marker if set
    if convoyLeaderPos and debugDrawer then
        debugDrawer:drawTextAdvanced(convoyLeaderPos + vec3(0,0,3.0), "👑 CONVOY LEADER", ColorF(1.0, 0.84, 0.0, 1.0), true, true, ColorI(0, 0, 0, 180))
    end
end

M._originalOnUpdate = M.onUpdate

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
