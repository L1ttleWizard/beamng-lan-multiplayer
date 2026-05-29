-- Session & Reconnect Management for BeamNG LAN Multiplayer
local M = {}

M.PROTOCOL_VERSION = 2
M.MOD_VERSION = "5.0.0"
M.GAME_VERSION = "0.36.x"

local state = "IDLE"
local lastPacketTime = 0
local reconnectTimeout = 5.0
local reconnectGrace = 2.0

local playerRoster = {}
local hostPassword = nil

function M.getPassword()
    return hostPassword
end

function M.setPassword(pwd)
    hostPassword = pwd
end

function M.clearPassword()
    hostPassword = nil
end

function M.setLastPacketTime(t)
    lastPacketTime = t
end

function M.verifyHandshake(payload)
    -- Check protocol version
    if not payload.protocol_version or payload.protocol_version ~= M.PROTOCOL_VERSION then
        return {
            ok = false,
            reason = "protocol_mismatch",
            details = string.format("Protocol mismatch: host has v%s, client has v%s", tostring(M.PROTOCOL_VERSION), tostring(payload.protocol_version or "unknown"))
        }
    end

    -- Check mod version
    if not payload.mod_version or payload.mod_version ~= M.MOD_VERSION then
        return {
            ok = false,
            reason = "mod_mismatch",
            details = string.format("Mod version mismatch: host has v%s, client has v%s", tostring(M.MOD_VERSION), tostring(payload.mod_version or "unknown"))
        }
    end

    -- Check game version (warning/mismatch if too different, e.g. major version change)
    if payload.game_version and M.GAME_VERSION then
        local majorHost = M.GAME_VERSION:match("^(%d+%.%d+)")
        local majorClient = payload.game_version:match("^(%d+%.%d+)")
        if majorHost and majorClient and majorHost ~= majorClient then
            return {
                ok = false,
                reason = "game_mismatch",
                details = string.format("Game version mismatch: host has %s, client has %s", M.GAME_VERSION, payload.game_version)
            }
        end
    end

    -- Check password if password is set on host
    if hostPassword and hostPassword ~= "" then
        if not payload.password or payload.password ~= hostPassword then
            return {
                ok = false,
                reason = "wrong_password",
                details = "Incorrect session password"
            }
        end
    end

    return { ok = true }
end

function M.updateRoster(rosterData)
    playerRoster = rosterData or {}
    if guihooks then
        guihooks.trigger("lanMultiplayerRosterUpdate", playerRoster)
    end
end

function M.getRoster()
    return playerRoster
end

-- Reconnect FSM logic
-- Returns new state if transition occurred, otherwise nil
function M.tickReconnectFSM(currentState, currentRole, lastPacketT, dt)
    if currentState == "CONNECTED" then
        local idleTime = os.clock() - lastPacketT
        if idleTime > reconnectGrace then
            log('W', 'sessionSync', 'Packet flow stopped. Transitioning to RECONNECTING state.')
            if guihooks then
                guihooks.trigger("lanMultiplayerAlert", { type = "warning", message = "Connection lost. Reconnecting..." })
            end
            return "RECONNECTING"
        end
    elseif currentState == "RECONNECTING" then
        local idleTime = os.clock() - lastPacketT
        if idleTime <= reconnectGrace then
            log('I', 'sessionSync', 'Packet flow resumed. Connection recovered!')
            if guihooks then
                guihooks.trigger("lanMultiplayerAlert", { type = "success", message = "Connected!" })
            end
            return "CONNECTED"
        elseif idleTime > reconnectTimeout then
            log('E', 'sessionSync', 'Reconnection timeout reached. Disconnecting.')
            return "TIMEOUT"
        end
    end
    return nil
end

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
