-- LAN Multiplayer Vehicle VM Extension
-- Implements KissMP's node-force-based position/rotation correction and direct inputs replication.
-- Author: Antigravity

local M = {}
M.isRemote = false

local nodes = {}
local ref_nodes = {}
local last_node = 1
local nodes_per_frame = 32
local node_pos_thresh = 3
local node_pos_thresh_sqr = node_pos_thresh * node_pos_thresh
local cooldown_timer = 1.5

M.received_transform = {
  position = vec3(0, 0, 0),
  rotation = quat(0, 0, 0, 1),
  velocity = vec3(0, 0, 0),
  angular_velocity = vec3(0, 0, 0),
  acceleration = vec3(0, 0, 0),
  angular_acceleration = vec3(0, 0, 0),
  sent_at = 0,
  time_past = 0
}

M.target_transform = {
  position = vec3(0, 0, 0),
  rotation = quat(0, 0, 0, 1),
  velocity = vec3(0, 0, 0),
  angular_velocity = vec3(0, 0, 0),
  acceleration = vec3(0, 0, 0),
  angular_acceleration = vec3(0, 0, 0),
}

M.force = 3
M.ang_force = 100
M.lerp_factor = 30.0

-- Pre-allocated objects to eliminate heap allocation inside update loops
local object_position = vec3()
local object_velocity = vec3()
local object_rotation = quat()
local predicted_position = vec3()

local velocity_difference = vec3()
local position_delta = vec3()
local linear_force = vec3()
local local_ang_vel = vec3()
local angular_velocity_difference = vec3()
local angle_delta = quat()
local angular_force = vec3()
local scaled_ang_vel = vec3()

local velocity = vec3()
local force_vec = vec3()
local angular_velocity = vec3()
local transform_velocity = vec3()
local transform_angular_velocity = vec3()

-- NOTE: No rotation snap function. Following KissMP's approach:
-- Rotation is ALWAYS handled via force-based torque, never via setPosRot.
-- This prevents the teleporting/snapping that occurs when the car turns.

local function try_rude()
  -- KissMP-style position-only snap when distance is extreme
  local distance = M.target_transform.position:squaredDistance(object_position)
  if distance > 6 * 6 then
    local p = M.target_transform.position
    obj:queueGameEngineLua(string.format(
      "getObjectByID(%d):setPositionNoPhysicsReset(vec3(%f,%f,%f))",
      objectId, p.x, p.y, p.z
    ))
    return true
  end
  return false
end

local function initNodes()
  local force = obj:getPhysicsFPS()
  nodes = {}
  ref_nodes = {}
  last_node = 1

  if not v.data or not v.data.nodes then return end

  local ref = {}
  if v.data.refNodes and v.data.refNodes[0] then
    ref = {
      v.data.refNodes[0].left,
      v.data.refNodes[0].up,
      v.data.refNodes[0].back,
      v.data.refNodes[0].ref,
    }
  end

  local total_mass = 0
  local inverse_rot = quat(obj:getRotation()):inversed()
  for _, node in pairs(v.data.nodes) do
    local node_mass = obj:getNodeMass(node.cid)
    local node_pos = inverse_rot * obj:getNodePosition(node.cid)
    table.insert(
      nodes,
      {
        node.cid,
        node_mass * force,
        true,
        node_pos
      }
    )
    total_mass = total_mass + node_mass
  end

  for _, node in pairs(ref) do
    table.insert(
      ref_nodes,
      {
        node,
        total_mass * force / 4,
        true,
        inverse_rot * obj:getNodePosition(node)
      }
    )
  end
end

local function setRemote(isRemote)
  if M.isRemote == isRemote then return end
  M.isRemote = isRemote
  if isRemote then
    initNodes()
    cooldown_timer = 1.5
    -- Disable FFB for remote vehicles to prevent force-feedback glitches
    if hydros then
      hydros.enableFFB = false
      hydros.onFFBConfigChanged(nil)
    end
  end
end

local function predict(dt)
  local target_velocity = M.target_transform.velocity
  target_velocity:setScaled2(M.received_transform.acceleration, M.received_transform.time_past)
  target_velocity:setAdd(M.received_transform.velocity)

  local distance = M.target_transform.position:squaredDistance(object_position)

  predicted_position:setScaled2(M.target_transform.velocity, M.received_transform.time_past)
  predicted_position:setAdd(M.received_transform.position)
  if distance < 2 * 2 then
    M.target_transform.position:setLerp(M.target_transform.position, predicted_position, clamp(M.lerp_factor * dt, 0.00001, 1))
  else
    M.target_transform.position:set(predicted_position)
  end

  M.target_transform.rotation:set(M.received_transform.rotation)
end


local function apply_linear_velocity(x, y, z)
  velocity:set(x, y, z)
  for k=1, #nodes do
    local node = nodes[k]
    if node[3] then
      local result = velocity * node[2]
      force_vec:set(result.x, result.y, result.z)
      obj:applyForceVector(node[1], force_vec)
    end
  end
end

local function apply_linear_velocity_ang_torque(x, y, z, pitch, roll, yaw)
  velocity:set(x, y, z)
  object_rotation:set(obj:getRotation())
  angular_velocity:set(pitch, roll, yaw)
  angular_velocity:setRotate(object_rotation)

  for k=1, #nodes do
    local node = nodes[k]
    if node[3] then
      local node_position = obj:getNodePosition(node[1])
      force_vec:setCross(node_position, angular_velocity)
      force_vec:setAdd(velocity)
      force_vec:setScaled(node[2])
      obj:applyForceVector(node[1], force_vec)
    end
  end
end

local function update_eligible_nodes()
  local inverse_rot = quat(obj:getRotation()):inversed()
  for k=last_node, math.min(#nodes , last_node + nodes_per_frame) do
    local node = nodes[k]
    local local_node_pos = inverse_rot * obj:getNodePosition(node[1])
    local local_original_pos = node[4]
    node[3] = (local_node_pos - local_original_pos):squaredLength() < node_pos_thresh_sqr
    last_node = k
  end
  if last_node == #nodes then last_node = 1 end
end

local function setTargetTransform(px, py, pz, rx, ry, rz, rw, vx, vy, vz, ax, ay, az, sentAt, timePast)
  if not M.isRemote then return end

  local time_dif = clamp((sentAt - M.received_transform.sent_at), 0.01, 0.1)

  transform_velocity:set(vx, vy, vz)
  transform_angular_velocity:set(ax, ay, az)

  local acceleration = M.received_transform.acceleration
  acceleration:setSub2(transform_velocity, M.received_transform.velocity)
  acceleration:setScaled(1 / time_dif)
  if acceleration:squaredLength() > 5 * 5 then
    acceleration:normalize()
    acceleration:setScaled(5)
  end

  local angular_acceleration = M.received_transform.angular_acceleration
  angular_acceleration:setSub2(transform_angular_velocity, M.received_transform.angular_velocity)
  angular_acceleration:setScaled(1 / time_dif)
  if angular_acceleration:squaredLength() > 5 * 5 then
    angular_acceleration:normalize()
    angular_acceleration:setScaled(5)
  end

  M.received_transform.position:set(px, py, pz)
  M.received_transform.rotation:set(rx, ry, rz, rw)
  M.received_transform.velocity:set(transform_velocity)
  M.received_transform.angular_velocity:set(transform_angular_velocity)
  M.received_transform.sent_at = sentAt
  M.received_transform.time_past = math.max(timePast or 0.001, 0.001)

  -- Keep targets in sync immediately so predict() is not one frame behind
  M.target_transform.position:set(px, py, pz)
  M.target_transform.rotation:set(rx, ry, rz, rw)
  M.target_transform.velocity:set(transform_velocity)
  M.target_transform.angular_velocity:set(transform_angular_velocity)
end

local function applyInputs(t, s, b, c, hb)
  if not M.isRemote then return end
  
  if electrics and electrics.values then
    electrics.values.throttle = t
    electrics.values.throttle_input = t
    electrics.values.steering = s
    electrics.values.steering_input = s
    electrics.values.brake = b
    electrics.values.brake_input = b
    electrics.values.clutch = c
    electrics.values.parkingbrake = hb
  end

  input.event("throttle", t, 1)
  input.event("brake", b, 2)
  input.event("parkingbrake", hb, 2)
  input.event("clutch", c, 1)
  input.event("steering", s, 2, 0, 0)
end

local function applyElectrics(lightsState, leftSignal, rightSignal, warnSignal, fogLights, lightbar, horn, rpm, gearIndex, wheelSpeed, soundSync, wheelSync, lightsSync)
  if not M.isRemote then return end

  if lightsSync ~= 0 and electrics.setLightsState then
    electrics.setLightsState(lightsState)
    electrics.set_left_signal(leftSignal)
    electrics.set_right_signal(rightSignal)
    electrics.set_warn_signal(warnSignal)
    electrics.set_fog_lights(fogLights)
    electrics.set_lightbar_signal(lightbar)
    electrics.horn(horn)
  end

  if soundSync ~= 0 then
    if mainEngine then
      mainEngine.rpm = rpm
      mainEngine.visualRPM = rpm
      mainEngine.inputAV = rpm * 0.104719755
    end
    if gearbox then
      gearbox.gearIndex = gearIndex
    end
    electrics.values.rpm = rpm
    electrics.values.rpmSpin = rpm
    electrics.values.gearIndex = gearIndex
    electrics.values.gear = gearIndex
  end

  if wheelSync ~= 0 then
    electrics.values.wheelspeed = wheelSpeed
    if wheels then
      for _, w in ipairs(wheels.wheels) do
        w.angularVelocity = wheelSpeed
        w.angularVelocityBrakeCouple = wheelSpeed
      end
    end
  end
end

local function applyDeformedNodes(deformed)
  if not M.isRemote then return end
  local inverse_rot = quat(obj:getRotation()):inversed()
  for cidStr, pos in pairs(deformed) do
    local cid = tonumber(cidStr)
    if cid then
      local worldPos = vec3(pos[1], pos[2], pos[3])
      obj:setNodePosition(cid, worldPos)
      -- Update cached position in nodes array to avoid force fighting
      for i = 1, #nodes do
        if nodes[i][1] == cid then
          nodes[i][4] = inverse_rot * worldPos
          nodes[i][3] = true -- keep it eligible
          break
        end
      end
    end
  end
end

local function updateTransform(dt)
  if not M.isRemote then return end

  if #nodes == 0 then
    initNodes()
    if #nodes == 0 then return end
  end

  if cooldown_timer > 0 then
    cooldown_timer = cooldown_timer - clamp(dt, 0, 0.02)
    return
  end
  if dt > 0.1 or M.received_transform.time_past == nil then return end

  object_position:set(obj:getPositionXYZ())
  object_rotation:set(obj:getRotation())
  object_velocity:set(obj:getVelocityXYZ())

  M.received_transform.time_past = clamp(M.received_transform.time_past + dt, 0, 0.5)
  predict(dt)
  -- KissMP-style: only snap position when extremely far, never snap rotation
  if try_rude() then return end

  update_eligible_nodes()

  local force = M.force
  local ang_force = M.ang_force
  local c_ang = -math.sqrt(4 * ang_force)

  velocity_difference:setSub2(M.target_transform.velocity, object_velocity)
  position_delta:setSub2(M.target_transform.position, object_position)

  -- linear_force = (velocity_difference + position_delta * force) * dt * 5
  linear_force:setScaled2(position_delta, force)
  linear_force:setAdd(velocity_difference)
  linear_force:setScaled(dt * 5)
  if linear_force:squaredLength() > 10 * 10 then
    linear_force:normalize()
    linear_force:setScaled(10)
  end

  local_ang_vel:set(
    obj:getYawAngularVelocity(),
    obj:getPitchAngularVelocity(),
    obj:getRollAngularVelocity()
  )

  angular_velocity_difference:setSub2(M.target_transform.angular_velocity, local_ang_vel)
  angle_delta:setMulInv2(M.target_transform.rotation, object_rotation)
  angular_force:set(angle_delta:toEulerYXZ())

  -- angular_force = (angular_velocity_difference + (angular_force * ang_force) + (c_ang * local_ang_vel)) * dt
  angular_force:setScaled(ang_force)
  scaled_ang_vel:setScaled2(local_ang_vel, c_ang)
  angular_force:setAdd(scaled_ang_vel)
  angular_force:setAdd(angular_velocity_difference)
  angular_force:setScaled(dt)

  -- KissMP behavior: if angular force is way too large, bail out entirely
  if angular_force:squaredLength() > 25 * 25 then
    return
  end

  -- KissMP behavior: apply torque whenever angular force is significant
  if angular_force:squaredLength() > 0.1 * 0.1 then
    apply_linear_velocity_ang_torque(
      linear_force.x,
      linear_force.y,
      linear_force.z,
      angular_force.y,
      angular_force.z,
      angular_force.x
    )
  elseif linear_force:squaredLength() > (dt * 15) * (dt * 15) then
    apply_linear_velocity(
      linear_force.x,
      linear_force.y,
      linear_force.z
    )
  end
end

local function onReset()
  cooldown_timer = 0.2
  if M.isRemote then
    initNodes()
  end
end

local function onInit()
  if M.isRemote then
    initNodes()
  else
    if electrics and electrics.horn then
      local original_horn = electrics.horn
      electrics.horn = function(val)
        M.manual_horn = (val and val > 0)
        if electrics.values then
          electrics.values.manual_horn = M.manual_horn and 1 or 0
        end
        original_horn(val)
      end
    end
  end
end

globalSyncVeh = function(t, s, b, c, hb, rpm, gear, ws, lights, flags, soundSync, wheelSync, lightsSync)
  applyInputs(t, s, b, c, hb)
  
  local bit = require('bit')
  local lightsState = bit.band(lights, 1) ~= 0 and 1 or 0
  local leftSignal = bit.band(lights, 2) ~= 0
  local rightSignal = bit.band(lights, 4) ~= 0
  local warnSignal = bit.band(lights, 8) ~= 0
  local fogLights = bit.band(lights, 16) ~= 0
  local lightbar = bit.band(lights, 32) ~= 0 and 1 or 0
  local horn = bit.band(lights, 64) ~= 0
  
  applyElectrics(lightsState, leftSignal, rightSignal, warnSignal, fogLights, lightbar, horn, rpm, gear, ws, soundSync, wheelSync, lightsSync)
end

globalApplyDeformedNodes = function(nodes)
  applyDeformedNodes(nodes)
end

local function applyWheelState(wheelStates)
  if not M.isRemote or not wheels or not wheels.wheels or type(wheelStates) ~= "table" then
    return
  end

  for idx, wd in ipairs(wheels.wheels) do
    local st = wheelStates[wd.name]
    if st then
      if st.brakeSurface then
        wd.brakeSurfaceTemperature = st.brakeSurface
      end
      if st.brakeCore then
        wd.brakeCoreTemperature = st.brakeCore
      end
      if st.thermalEff then
        wd.brakeThermalEfficiency = st.thermalEff
      end

      if electrics and electrics.values and electrics.values.wheelThermals and electrics.values.wheelThermals[wd.name] then
        local wt = electrics.values.wheelThermals[wd.name]
        wt.brakeSurfaceTemperature = wd.brakeSurfaceTemperature or 0
        wt.brakeCoreTemperature = wd.brakeCoreTemperature or 0
        wt.brakeThermalEfficiency = wd.brakeThermalEfficiency or 1
      end

      if st.deflated and st.deflated ~= 0 and not wd.isTireDeflated then
        if beamstate and beamstate.deflateTire then
          local wheelIdx = st.idx
          if wheelIdx == nil then
            wheelIdx = idx - 1
          end
          beamstate.deflateTire(wheelIdx)
        else
          wd.isTireDeflated = true
        end
      end
    end
  end
end

globalApplyWheelState = function(wheelStates)
  applyWheelState(wheelStates)
end

M.setRemote = setRemote
M.setTargetTransform = setTargetTransform
M.applyInputs = applyInputs
M.applyElectrics = applyElectrics
M.applyDeformedNodes = applyDeformedNodes
M.applyWheelState = applyWheelState
M.updateTransform = updateTransform
M.onReset = onReset
M.onInit = onInit

lanMultiplayerVehicle = M
return M
