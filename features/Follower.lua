local mod = ...

local Game = require("src.core.Game")

local CELL = 16
local FOLLOW_SPEED = 105
local TELEPORT_DISTANCE = 96

local followers = {}
local trail = {}
local lastMap = nil
local lastPlayerCell = nil
local servicesReady = false
local BLACK_TEXTURE = nil
local Voxel3D = nil

-- ------------------------------------------------------------
-- Setting: OFF / 1 / 2 / 3 / 4 / 5 / 6
-- ------------------------------------------------------------

local COUNT_KEY = "follower_count"
local COUNT_CHOICES = {0, 1, 2, 3, 4, 5, 6}


local function getCount()
  local value = 1
  local loader = Game and Game.mods
  local stored = loader and loader.modOptions and loader.modOptions[mod.id]

  if stored and stored[COUNT_KEY] ~= nil then
    value = tonumber(stored[COUNT_KEY]) or 1
  else
    local opts = Game and Game.save and Game.save.options
    stored = opts and opts.modOptions and opts.modOptions[mod.id]
    if stored and stored[COUNT_KEY] ~= nil then
      value = tonumber(stored[COUNT_KEY]) or 1
    end
  end

  value = math.floor(value)
  if value < 0 then value = 0 end
  if value > 6 then value = 6 end
  return value
end

local function setCount(game, value)
  value = math.max(0, math.min(6, math.floor(tonumber(value) or 0)))
  local opts = game and game.save and game.save.options
  if opts then
    opts.modOptions = opts.modOptions or {}
    opts.modOptions[mod.id] = opts.modOptions[mod.id] or {}
    opts.modOptions[mod.id][COUNT_KEY] = value
  end
  local loader = game and game.mods
  if loader then
    loader.modOptions = loader.modOptions or {}
    loader.modOptions[mod.id] = loader.modOptions[mod.id] or {}
    loader.modOptions[mod.id][COUNT_KEY] = value
  end
  if game and game.writeOptions then pcall(game.writeOptions, game) end
end

local function optionRow()
  return {
    id = mod.id .. ":" .. COUNT_KEY,
    label = "RUMBLE FOLLOWERS",
    value = function()
      local n = getCount()
      return n == 0 and "OFF" or tostring(n)
    end,
    step = function(game, dir)
      local n = getCount()
      n = n + (dir or 1)
      if n > 6 then n = 0 end
      if n < 0 then n = 6 end
      setCount(game, n)
      return true
    end
  }
end


-- ------------------------------------------------------------
-- APIs
-- ------------------------------------------------------------

local function log(level, fmt, ...)
  if not mod.log then return end
  local fn = mod.log[level]
  if type(fn) == "function" then pcall(fn, mod.log, fmt, ...) end
end

local function findImporter()
  local api = mod.exports and (mod.exports.rumble_main or mod.exports.rumble_importer)
  if api and tonumber(api.api)==1 and type(api.createActor)=="function" then return api end
  if not (mod and type(mod.find)=="function") then return nil end
  local ok,host=pcall(mod.find,"RUMBLE_MAIN")
  if not ok or not host then return nil end
  api=host.exports and (host.exports.rumble_main or host.exports.rumble_importer)
  if not api or tonumber(api.api)~=1 or type(api.createActor)~="function" then return nil end
  return api
end

local function findDramaless()
  local api=mod.exports and mod.exports.voxel_companion
  local importer=mod.exports and (mod.exports.rumble_main or mod.exports.rumble_importer)
  if api and tonumber(api.api)==1 and type(api.register)=="function" then
    if importer and type(importer.Voxel3D)=="function" then
      local okv,v=pcall(importer.Voxel3D)
      if okv and v and type(v.draw)=="function" then Voxel3D=v end
    end
    return api
  end
  if not (mod and type(mod.find)=="function") then return nil end
  local ok,host=pcall(mod.find,"RUMBLE_MAIN")
  if not ok or not host then return nil end
  api=host.exports and host.exports.voxel_companion
  importer=host.exports and (host.exports.rumble_main or host.exports.rumble_importer)
  if not api or tonumber(api.api)~=1 or type(api.register)~="function" then return nil end
  if importer and type(importer.Voxel3D)=="function" then
    local okv,v=pcall(importer.Voxel3D)
    if okv and v and type(v.draw)=="function" then Voxel3D=v end
  end
  return api
end

local function outlineEnabled()
  local api=findImporter()
  if api and type(api.outlineEnabled)=="function" then
    local ok,v=pcall(api.outlineEnabled)
    if ok then return v~=false end
  end
  return true
end

local function blackTexture()
  if BLACK_TEXTURE then return BLACK_TEXTURE end
  if not (love and love.image and love.graphics
      and love.image.newImageData and love.graphics.newImage) then return nil end
  local ok, data = pcall(love.image.newImageData, 1, 1)
  if not ok or not data then return nil end
  pcall(data.setPixel, data, 0, 0, 0, 0, 0, 1)
  local ok2, img = pcall(love.graphics.newImage, data)
  if ok2 and img then BLACK_TEXTURE = img end
  return BLACK_TEXTURE
end

-- ------------------------------------------------------------
-- Party helpers
-- ------------------------------------------------------------

local function dexOfPartySlot(slot)
  local save = Game and Game.save
  local party = save and save.party
  local mon = type(party) == "table" and party[slot] or nil
  if not mon then return nil end

  local species = mon.species
  if type(species) == "number" then
    local n = math.floor(species)
    if n >= 1 and n <= 151 then return n end
  end

  local data = Game and Game.data
  local pokemon = data and data.pokemon
  local key = species and tostring(species):upper() or nil
  local def = pokemon and key and (pokemon[species] or pokemon[key])
  local dex = def and tonumber(def.dex)
  if dex then
    dex = math.floor(dex)
    if dex >= 1 and dex <= 151 then return dex end
  end
  return nil
end

local function yawForFacing(facing)
  if facing == "right" then return math.pi * 0.5 end
  if facing == "up" then return math.pi end
  if facing == "left" then return -math.pi * 0.5 end
  return 0
end

local function tileCenter(cx, cz, y)
  return {
    x = (tonumber(cx) or 0) * CELL + 8,
    y = tonumber(y) or 0,
    z = (tonumber(cz) or 0) * CELL + 8,
  }
end

local function playerCell(player)
  local cx = tonumber(player.cellX)
  local cz = tonumber(player.cellZ)
  if cx == nil then cx = math.floor(((tonumber(player.x) or 8) - 8) / CELL) end
  if cz == nil then cz = math.floor(((tonumber(player.z) or 8) - 8) / CELL) end
  return cx, cz
end

local function oneBehind(cx, cz, facing, steps)
  steps = steps or 1
  if facing == "down" then cz = cz - steps
  elseif facing == "up" then cz = cz + steps
  elseif facing == "right" then cx = cx - steps
  elseif facing == "left" then cx = cx + steps end
  return cx, cz
end

-- ------------------------------------------------------------
-- Actors
-- ------------------------------------------------------------

local function destroyActor(entry)
  if not entry or not entry.actor then return end
  local ok = pcall(function() entry.actor:destroy() end)
  if not ok then
    local importer = findImporter()
    if importer and type(importer.destroyActor) == "function" then
      pcall(importer.destroyActor, entry.actor)
    end
  end
end

local function clearFollowers()
  for _, entry in ipairs(followers) do destroyActor(entry) end
  followers = {}
end

local function makeActor(slot, dex, pos, facing)
  local importer = findImporter()
  if not importer then return nil end
  local actor, err = importer.createActor(dex, {
    manual = true,
    visible = false,
    x = pos.x, y = pos.y, z = pos.z,
    yaw = yawForFacing(facing),
  })
  if not actor then
    log("warn", "Follower slot %d failed dex=%s: %s", slot, tostring(dex), tostring(err))
    return nil
  end
  actor:setAnimation("idle")
  actor:setPosition(pos.x, pos.y, pos.z)
  actor:setYaw(yawForFacing(facing))
  actor:setVisible(false)
  return {
    slot = slot,
    dex = dex,
    actor = actor,
    current = {x=pos.x, y=pos.y, z=pos.z},
    target = {x=pos.x, y=pos.y, z=pos.z, facing=facing},
    lastAnim = "idle",
  }
end

local function ensureFollowers(player)
  local wanted = getCount()
  if wanted == 0 then
    if #followers > 0 then clearFollowers() end
    return
  end

  local cx, cz = playerCell(player)
  local facing = player.facing or "down"

  for slot = 1, 6 do
    local shouldExist = slot <= wanted
    local dex = shouldExist and dexOfPartySlot(slot) or nil
    local entry = followers[slot]

    if not dex then
      if entry then destroyActor(entry); followers[slot] = nil end
    elseif not entry or entry.dex ~= dex then
      if entry then destroyActor(entry) end
      local sx, sz = oneBehind(cx, cz, facing, slot)
      local pos = tileCenter(sx, sz, player.y)
      followers[slot] = makeActor(slot, dex, pos, facing)
    end
  end

  -- Remove any entries beyond the selected count.
  for slot = wanted + 1, 6 do
    if followers[slot] then
      destroyActor(followers[slot])
      followers[slot] = nil
    end
  end
end

-- ------------------------------------------------------------
-- Trail logic
-- ------------------------------------------------------------

local function resetTrail(player)
  trail = {}
  local cx, cz = playerCell(player)
  local facing = player.facing or "down"
  local y = tonumber(player.y) or 0

  -- Build a starting chain behind the player so followers never spawn stacked.
  for i = 1, 6 do
    local bx, bz = oneBehind(cx, cz, facing, i)
    local p = tileCenter(bx, bz, y)
    trail[i] = {x=p.x, y=p.y, z=p.z, facing=facing}
  end

  lastPlayerCell = {cx=cx, cz=cz, y=y, facing=facing}
end

local function updateTrail(player)
  local cx, cz = playerCell(player)
  local facing = player.facing or "down"
  local y = tonumber(player.y) or 0

  if not lastPlayerCell then
    resetTrail(player)
    return
  end

  if cx ~= lastPlayerCell.cx or cz ~= lastPlayerCell.cz then
    -- The first follower goes to the exact tile the trainer left.
    -- Older trail entries shift backward for followers 2-6.
    local old = tileCenter(lastPlayerCell.cx, lastPlayerCell.cz, lastPlayerCell.y)
    table.insert(trail, 1, {
      x=old.x, y=old.y, z=old.z, facing=facing
    })
    while #trail > 6 do table.remove(trail) end
  end

  lastPlayerCell = {cx=cx, cz=cz, y=y, facing=facing}

  for slot = 1, 6 do
    local e = followers[slot]
    local t = trail[slot]
    if e and t then
      e.target = {x=t.x, y=t.y, z=t.z, facing=t.facing}
    end
  end
end

-- ------------------------------------------------------------
-- Movement
-- ------------------------------------------------------------

local function moveEntry(entry, dt)
  if not (entry and entry.actor and entry.current and entry.target) then return end
  dt = math.max(0, math.min(0.1, tonumber(dt) or (1/60)))

  local c, t = entry.current, entry.target
  local dx, dz = t.x - c.x, t.z - c.z
  local dist = math.sqrt(dx*dx + dz*dz)
  local moving = dist > 0.15

  if dist > TELEPORT_DISTANCE then
    c.x, c.y, c.z = t.x, t.y, t.z
    moving = false
  elseif moving then
    local catchup = 1.0
    if dist > CELL * 2.25 then
      catchup = 2.0
    elseif dist > CELL * 1.75 then
      catchup = 1.75
    elseif dist > CELL * 1.25 then
      catchup = 1.35
    end
    local step = math.min(dist, FOLLOW_SPEED * catchup * dt)
    c.x = c.x + dx / dist * step
    c.z = c.z + dz / dist * step
    c.y = c.y + ((t.y or c.y) - c.y) * math.min(1, dt * 16)
  else
    c.x, c.y, c.z = t.x, t.y, t.z
  end

  local yaw = moving and math.atan2(dx, dz) or yawForFacing(t.facing)
  entry.actor:setPosition(c.x, c.y, c.z)
  entry.actor:setYaw(yaw)
  entry.actor:setVisible(false)

  local anim = moving and "walk" or "idle"
  if entry.lastAnim ~= anim then
    entry.actor:setAnimation(anim)
    entry.lastAnim = anim
  end
  entry.actor:update(dt)
end

-- ------------------------------------------------------------
-- Toon render
-- ------------------------------------------------------------

local function drawActor(entry)
  local actor = entry and entry.actor
  if not (actor and Voxel3D and type(Voxel3D.draw) == "function") then return end

  local matrix = actor:matrix()
  if type(Voxel3D.seams) == "function" then pcall(Voxel3D.seams, false) end
  if type(Voxel3D.glass) == "function" then pcall(Voxel3D.glass, false) end

  local black = blackTexture()
  if outlineEnabled() and black and love and love.graphics and love.graphics.setDepthMode then
    pcall(love.graphics.setDepthMode, "lequal", false)
    for _, part in ipairs(actor.rig.parts or {}) do
      if part.outlineMesh then
        pcall(Voxel3D.draw, part.outlineMesh, black, matrix, 0, matrix)
      end
    end
    pcall(love.graphics.setDepthMode, "lequal", true)
  end

  for _, part in ipairs(actor.rig.parts or {}) do
    if part.mesh and part.texture then
      pcall(Voxel3D.draw, part.mesh, part.texture, matrix, 0, matrix)
    end
  end

  if type(Voxel3D.glass) == "function" then pcall(Voxel3D.glass, true) end
  if type(Voxel3D.seams) == "function" then pcall(Voxel3D.seams, true) end
end

-- ------------------------------------------------------------
-- Companion registration
-- ------------------------------------------------------------

local companion = findDramaless()
if not companion then
  error("RUMBLE_FOLLOWER: RUMBLE_MAIN compatible voxel_companion API unavailable", 0)
end

local spec = {
  api = 1,
  id = "rumble.followers",
  name = "Rumble Pokemon Followers",
  version = "0.3.0",
  priority = 30,
  requires = {"render_phases", "world_snapshot"},
  optional = {},

  attach = function(_services)
    servicesReady = true
  end,

  worldChanged = function(_world)
    clearFollowers()
    trail = {}
    lastPlayerCell = nil
    lastMap = nil
  end,

  render = {
    opaque_after_terrain = function(context)
      local world = context and context.world
      local player = world and world.player
      if not (servicesReady and player and world.id) then return end

      if lastMap ~= world.id then
        clearFollowers()
        resetTrail(player)
        lastMap = world.id
      end

      ensureFollowers(player)
      updateTrail(player)

      local frame = context.frame or {}
      local dt = frame.dt or (1/60)
      for slot = 1, 6 do
        local entry = followers[slot]
        if entry then
          moveEntry(entry, dt)
          drawActor(entry)
        end
      end
    end,
  },

  invalidate = function()
    trail = {}
    lastPlayerCell = nil
  end,

  dispose = function()
    clearFollowers()
    if BLACK_TEXTURE and BLACK_TEXTURE.release then
      pcall(BLACK_TEXTURE.release, BLACK_TEXTURE)
    end
    BLACK_TEXTURE = nil
  end,
}

local handle, err = companion.register(spec)
if not handle then
  error("RUMBLE_FOLLOWER registration failed: "..tostring(err), 0)
end

if mod.events and type(mod.events.on) == "function" then
  mod.events:on("mod.options_changed", function(payload)
    if payload and payload.mod == mod.id then
      -- Rebuild on next render so changing 1 -> 6 or OFF is immediate.
      clearFollowers()
      trail = {}
      lastPlayerCell = nil
    end
  end)
end

mod.exports.rumble_follower = {
  api = 1,
  version = "0.3.0",
  getCount = getCount,
  getFollower = function(slot)
    local e = followers[tonumber(slot) or 1]
    return e and e.actor or nil
  end,
  getLeadDex = function() return dexOfPartySlot(1) end,
}
